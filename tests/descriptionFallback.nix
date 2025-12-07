# type: flake-parts module
# test whether system.description can be rendered even when support module is not loaded by selected config
{
  lib,
  inputs,
  self,
  ...
}@top:
let
  inherit (builtins) attrValues;
  inherit (lib) nixosSystem;
in
{

  flake.nixosConfigurations.test-descriptionFallback = nixosSystem {
    modules = [
      self.nixosModules.test-configDefaults
      # explictly NOT self.nixosModules.support
    ];
    system = "x86_64-linux"; # irrelevant for this test
  };

  perSystem =
    { pkgs, ... }@systemArg:
    {
      checks.descriptionFallback = pkgs.testers.nixosTest {
        name = "descriptionFallback";

        nodes.node.imports = [
          # configure installer
          self.nixosModules.default
          {
            programs.disko-install-menu = {
              enable = true;
              autoStart = true;
              options = {
                defaultFlake = "${./..}";
                defaultHost = "test-descriptionFallback";
              };
            };
          }
          # prepare offine evaluation (TODO move to actual module)
          {
            system.extraDependencies = (map (i: "${i}") (attrValues inputs)); # flake inputs
          }
          # for test environment only
          {
            virtualisation = {
              writableStore = true; # store must be writable for running evaluation
              # provide more storage for store for evaluation
              diskSize = 4096;
              writableStoreUseTmpfs = false;
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
          wait_for_text("install .*NixOS", timeout=2*60)
          send_chars("instnixos\n")  # test fuzzy selection
          # select flake / default
          wait_for_text("default target", timeout=8*60)
          # TODO verify description was rendered successful
        '';
      };
    };

}
