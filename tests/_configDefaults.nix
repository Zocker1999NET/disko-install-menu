# type: flake-parts module
# defaults applicable to all nixosConfigurations used in nixosTests
{ inputs, lib, ... }@top:
let
  inherit (lib.versions) majorMinor;
in
{
  flake.nixosModules.test-configDefaults =
    { config, ... }:
    {
      imports = [
        # self.nixosModules.support needs to be imported per config
        # (as some tests are testing with this being absent)
        # system config
        inputs.disko.nixosModules.default
        "${inputs.disko}/example/simple-efi.nix"
      ];
      config = {
        boot.loader = {
          efi.canTouchEfiVariables = true; # test that installer can properly disable this option
          grub.enable = false;
          systemd-boot.enable = true;
        };
        system = {
          description = "config intended to be only used by nixosTests testing disko-install-menu";
          stateVersion = majorMinor config.system.nixos.version;
        };
      };
    };
}
