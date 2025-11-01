{
  config,
  inputs,
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

}
