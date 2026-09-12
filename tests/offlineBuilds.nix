# tests whether certain NixOS configurations can be built fully offline
{
  config,
  inputs,
  lib,
  self,
  ...
}@top:
let
  inherit (lib.attrsets) mapAttrs' nameValuePair;
  inherit (lib.trivial) flip;

  # see its README for why configs are provided by a separate flake
  target = inputs.disko-install-menu-target;
in
{
  _class = "flake";

  perSystem =
    { pkgs, system, ... }@systemArg:
    let
      testCases = target.nixosTemplates.${system};
    in
    {
      checks = flip mapAttrs' testCases (
        caseName: _:
        let
          name = "offlineBuilds-${caseName}";
          configName = "${caseName}_${system}";
        in
        nameValuePair name (
          pkgs.testers.nixosTest {
            inherit name;
            nodes.node.imports = [
              self.nixosModules.default
              {
                programs.disko-install-menu = {
                  enable = true;
                  offlineCapable = true;
                  listedFlakes."default flake" = {
                    offlineReference = target;
                    isDefaultFlake = true;
                    defaultHost = configName;
                    offlineHosts.${configName} = true;
                  };
                };
                virtualisation = {
                  memorySize = 4 * 1024;
                  useNixStoreImage = true; # verify that installer can run with all detected dependencies (see https://github.com/NixOS/nix/issues/14207)
                  writableStore = true;
                };
              }
              # make offlineCapable tests fail more likely when installer config is designed more minimalistically
              {
                xdg.mime.enable = false;
              }
            ];
            testScript = ''
              node.start()
              node.wait_for_unit("default.target")

              # ensure offline
              node.block()
              # (removing routes may fail if no such routes exist)
              node.execute("ip -4 route del default")
              node.execute("ip -6 route del default")
              node.fail("ping -c 2 9.9.9.9")
              node.fail("ping -c 2 2620:fe::fe")

              # execute build
              node.succeed("disko-install-menu --debug-test-build")
            '';
          }
        )
      );
    };
}
