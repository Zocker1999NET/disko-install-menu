# type: flake-parts module
# test whether system.description can be rendered even when support module is not loaded by selected config
{
  config,
  lib,
  self,
  ...
}@top:
let
  inherit (lib) nixosSystem;
  inherit (lib.attrsets) genAttrs';
in
{

  flake.nixosConfigurations = genAttrs' config.systems (system: {
    name = "test-${system}";
    value = nixosSystem {
      modules = [
        self.nixosModules.test-configDefaults
        # installer prefix
        self.nixosModules.support
        {
          # also heavily speeds up rendering description of configuration
          system.description = "config intended to be only used by nixosTests testing disko-install-menu";
        }
      ];
      inherit system;
    };
  });

  perSystem =
    { pkgs, system, ... }@systemArg:
    {
      checks.installDefault = pkgs.testers.nixosTest {
        name = "installDefault";

        nodes.node.imports = [
          # configure installer
          self.nixosModules.default
          {
            programs.disko-install-menu = {
              enable = true;
              autoStart = true;
              offlineCapable = true;
              options = {
                defaultFlake = "${self}";
                defaultHost = "test-${system}";
              };
              listedFlakes.defaultFlake = {
                offlineHosts."test-${system}" = true;
                offlineReference = self;
              };
            };
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
      };
    };

}
