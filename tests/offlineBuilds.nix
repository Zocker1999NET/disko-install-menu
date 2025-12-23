# type: flake-parts module
# tests whether certain NixOS configurations can be built fully offline
{
  lib,
  self,
  ...
}@top:
let
  inherit (lib) nixosSystem;
  inherit (lib.attrsets) mapAttrs' nameValuePair;
  inherit (lib.trivial) flip;

  # test configurations
  testCases = {
    minimal = { };
    systemConfigRevision = {
      # reflects a value which differs in online vs offline evaluation
      # (system.configurationRevision -> nixos-version -> environment.systemPackages)
      system.configurationRevision = toString (
        self.shortRev or self.dirtyShortRev or self.lastModified or "unknown"
      );
    };
    systemCheckOnRevision = {
      # change of configurationRevision triggers requirement on all system.checks
      imports = [
        testCases.systemConfigRevision
      ];
      # openssh module adds a (seemingly) non-trivial system.checks
      services.openssh.enable = true;
    };
  };
  toTemplateName = caseName: "test-${caseName}";
in
{
  perSystem =
    { pkgs, system, ... }@systemArg:
    {

      checks = flip mapAttrs' testCases (
        caseName: _:
        let
          name = "offlineBuilds-${caseName}";
          configName = "${toTemplateName caseName}_${system}";
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
                  options = {
                    defaultFlake = "${self}";
                    defaultHost = configName;
                  };
                  listedFlakes.defaultFlake = {
                    offlineHosts.${configName} = true;
                    offlineReference = self;
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
              node.succeed("ip -4 route del default")
              node.succeed("ip -6 route del default")
              node.fail("ping -c 2 9.9.9.9")
              node.fail("ping -c 2 2620:fe::fe")

              # execute build
              node.succeed("disko-install-menu --debug-test-build")
            '';
          }
        )
      );

      nixosTemplates = flip mapAttrs' testCases (
        name: module:
        nameValuePair (toTemplateName name) (nixosSystem {
          modules = [
            self.nixosModules.default # disko & installer
            self.nixosModules.support
            self.nixosModules.test-configDefaults # minimal for successful build
            module
          ];
          inherit system;
        })
      );

    };
}
