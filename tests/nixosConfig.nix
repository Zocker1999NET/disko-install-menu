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
        # installer prefix
        self.nixosModules.support
        # system config
        inputs.disko.nixosModules.default
        "${inputs.disko}/example/simple-efi.nix"
        (
          { config, ... }:
          {
            boot.loader = {
              efi.canTouchEfiVariables = true; # test that installer can properly disable this option
              grub.enable = false;
              systemd-boot.enable = true;
            };
            system = {
              description = "config intended to be only used by nixosTests testing disko-install-menu";
              stateVersion = lib.versions.majorMinor config.system.nixos.version;
            };
          }

        )
      ];
      inherit system;
    };
  });

}
