# type: NixOS module
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.disko-install-menu;

  inherit (lib.modules) mkIf;
  inherit (lib.options) mkEnableOption mkPackageOption;
in
{

  imports = [
    ./autoStart.nix
    ./menuConfig.nix
  ];

  options.programs.disko-install-menu = {

    enable = mkEnableOption ''
      disko-install-menu, allowing users to install a specific flake configuration while selecting the disks for their disko config.

      This does add its command to the system path & installs the required configuration file.
      This does not enable any kind of autostart mechanic,
      see {config}`programs.disko-install-menu.autoStart` for that
    ''; # mkEnableOption -> dot at end is added

    package = mkPackageOption pkgs "disko-install-menu" { };

  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };

}
