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
  inherit (lib.modules) mkForce;
in
{

  _class = "flake";

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
              listedFlakes.default = {
                reference = "${./..}";
                isDefaultFlake = true;
                defaultHost = "test-descriptionFallback";
              };
            };
          }
          {
            system.extraDependencies = (map (i: "${i}") (attrValues inputs)); # flake inputs
          }
          # let the service fail instead of restarting on failure to be able to observe failure early
          {
            systemd.services.disko-install-menu.serviceConfig.Restart = mkForce "no";
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
            return node.wait_until_tty_matches("1", regexp, timeout=timeout)

          @polling_condition
          def menu_running():
            "check that the disko-install-menu service is still running"
            try:
              node.require_unit_state("disko-install-menu.service")
            except AssertionError:
              # log the current tty content to aid debugging (error message on screen instead of journal output)
              node.dump_tty_contents("1")
              raise

          node.start()
          node.wait_for_unit("default.target")
          menu_running.wait()
          time.sleep(1)
          # ensure offline
          node.block()
          node.succeed("ip -4 route del default")
          node.succeed("ip -6 route del default")
          node.fail("ping -c 2 9.9.9.9")
          node.fail("ping -c 2 2620:fe::fe")
          # main screen
          with menu_running:
            wait_for_text("install .*NixOS", timeout=2*60)
            send_chars("instnixos\n")  # test fuzzy selection
            # select flake / default
            wait_for_text("default target", timeout=8*60)
            # TODO verify description was rendered successful
        '';
      };
    };

}
