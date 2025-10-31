{
  self,
  inputs,
  lib,
  ...
}@top:
{ pkgs, system, ... }@systemArg:
let
  inherit (builtins) attrValues;
in
{
  name = "installDefault";

  nodes.node.imports = [
    # debugging fzf
    (
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.fzf ];
        nixpkgs.overlays = [
          (final: prev: {
            fzf = prev.fzf.overrideAttrs (old: {
              version = "v0.66.0-beta";
              src = pkgs.fetchFromGitHub {
                owner = "junegunn";
                repo = "fzf";
                rev = "ab407c4645952d09c4bb9b481b178717f0a0578f";
                hash = "sha256-bkBOo/KJ0WQrAWhHFHnvdqGoWvCL0vYj/H6eepraf3w=";
              };
              vendorHash = "sha256-uFXHoseFOxGIGPiWxWfDl339vUv855VHYgSs9rnDyuI=";
            });
          })
        ];
      }
    )
    # configure installer
    self.nixosModules.default
    {
      programs.disko-install-menu = {
        enable = true;
        autoStart = true;
        options = {
          # TODO choose ones accessible to the host
          defaultFlake = "${./..}";
          defaultHost = "test-${system}";
        };
      };
    }
    # prepare offline installation (TODO move to actual module)
    {
      system.extraDependencies =
        (with self.nixosConfigurations."test-${system}".config.system.build; [
          toplevel
          # disko script (esp. its dependencies)
          diskoScript
          formatScript
          mountScript
        ])
        # no idea why those are actually required (has probably something to do with disko)
        ++ (with pkgs; [
          makeBinaryWrapper
          jq.dev
        ])
        # pkgs.closureInfo (see <nixpkgs/pkgs/build-support/closure-info.nix>)
        ++ (with pkgs; [
          coreutils
          jq
          stdenvNoCC
        ])
        # bootloader packages
        ++ (self.nixosConfigurations."test-${system}".config.boot.loader.buildDependencies or [ ])
        # flake inputs
        ++ (map (i: "${i}") (attrValues inputs));
    }
    # for test environment only
    {
      virtualisation = {
        emptyDiskImages = [ (4 * 1024) ];
        memorySize = 4 * 1024;
        useNixStoreImage = true; # verify that installer can run with all detected dependencies (see https://github.com/NixOS/nix/issues/14207)
        writableStore = true;
      };
    }
  ];
  interactive.nodes.node.programs.disko-install-menu.debugMode = true;

  testScript = ''
    import time
    def send_chars(*args):
      node.send_chars(*args)
      time.sleep(1)
    def wait_for_text(regexp, timeout):
      return node.wait_until_tty_matches(1, regexp, timeout=timeout)

    node.start()
    node.wait_for_unit("default.target")
    node.wait_for_unit("disko-install-menu.service")
    time.sleep(1)
    # ensure offline
    node.block()
    node.succeed("ip -4 route del default")
    node.succeed("ip -6 route del default")
    node.fail("ping -c 2 9.9.9.9")
    node.fail("ping -c 2 2620:fe::fe")
    # main screen
    wait_for_text("install .*Nix[0O]S", timeout=2*60)  # OCR sometimes not exact
    send_chars("instnixos\n")  # test fuzzy selection
    # select flake / default
    wait_for_text("default target", timeout=8*60)
    send_chars("default target")
    wait_for_text("config intended to be only used by nixosTests", timeout=60)  # verify test config is selected & test description rendering
    send_chars("\n")
    # select action
    wait_for_text("FORMAT disks according", timeout=2*60)  # verify 'install' is pre-selected
    send_chars("\n")
    # select disk "main"
    wait_for_text(r'select.*disk.*: main', timeout=2*60)
    send_chars("vdc\n")
    # select after success action
    send_chars("return back to menu")
    wait_for_text("(?s)return.*menu.*after.*success", timeout=60)  # verify that this option exists
    send_chars("\n")
    # last screen
    wait_for_text("confirm installation", timeout=2*60)
    wait_for_text("INSTALL NOW", timeout=60)
    wait_for_text("WIPE.*disks", timeout=60)
    send_chars("writeEfiBootEntries\n")
    wait_for_text("writeEfiBootEntries = False", timeout=2*60)
    wait_for_text("INSTALL NOW", timeout=60)
    send_chars("install\n")
    # wait for successful installation
    wait_for_text("(?i)disko-install-menu.*Installation.*Successful", timeout=3*60)
  '';
}
