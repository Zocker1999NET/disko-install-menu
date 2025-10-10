{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.disko-install-menu;

  inherit (lib) types;
  inherit (lib.lists) singleton;
  inherit (lib.meta) getExe;
  inherit (lib.modules) mkIf;
  inherit (lib.options) mkEnableOption mkOption mkPackageOption;

  #new_formats = (import ./env_format.nix) { inherit lib pkgs; };
  #envFmt = new_formats.env { prefix = "opt_"; };
  cfgFormat = pkgs.formats.json { };

  # submodule type
  menuOptions = types.submodule {
    freeformType = cfgFormat.type;
    options = {

      debugMode = mkEnableOption "debug (i.e. dry-run) mode, where no changes will be applied by the install menu";

      defaultFlake = mkOption {
        description = ''
          The flake suggested by default in the menu.

          If declared, it only serves as the default for speeding up selection of a configuration.
          Users may still choose to install from other flakes by inserting these flake references manually on runtime.

          Do not declare a specific configuration here (i.e. do not add `#host` to the end of the reference).
          To declare a default configuration, use the specific option for that.

          In general, for this menu to recognize a flake’s configurations,
          it must declare them in its nixosConfigurations output.
          The same as e.g. nixos-rebuild requires that output to be set.
        '';
        type = types.str;
        example = "github:Zocker1999NET/server";
      };

      defaultHost = mkOption {
        description = ''
          The name of the default host configuration provided in the menu.

          If declared, it only serves as the default for speeding up selection of a configuration.
          Users may still choose to install a different configuration at all.

          This configuration is expected to be exported by the default flake.

          In general, for a NixOS configuration to be installable by this setup,
          it must also define a disko configuration
          (optionally excluding the names of the target disks,
          as those are provided by the user).
        '';
        type = types.str;
        example = "empty";
      };

      diskoInstallFlags = mkOption {
        description = "Command line arguments which are forwarded to disko-install.";
        type = with types; listOf str;
        default = [ ];
      };

      writeEfiBootEntries = mkOption {
        description = ''
          Whether to enable writing EFI boot entries on installation.

          This is a tri-state variable,
          where the default value `null` means:
          Depend on the option {option}`boot.loader.efi.canTouchEfiVariables`
          of the selected configuration to be installed.
          This is because the setup is expected to be executed on the actual target machines.

          This `null` value allows you e.g.
          to disable this for configurations intended for systems
          where writing EFI variables might error out.

          Disable this if you want to execute the setup on non-target machines,
          e.g. when installing on external drives to deploy them later in their actual targets.

          Enable this only if you want to write EFI boot entries for every configuration.
        '';
        type = types.enum [
          false
          null
          true
        ];
        default = null;
      };

    };
  };
in
{

  options.programs.disko-install-menu = {

    enable = mkEnableOption ''
      disko-install-menu, allowing users to install a specific flake configuration while selecting the disks for their disko config.

      This does add its command to the system path & installs the required configuration file.
      This does not enable any kind of autostart mechanic,
      see {config}`programs.disko-install-menu.autoStart` for that
    ''; # mkEnableOption -> dot at end is added

    autoStart = mkEnableOption ''
      automatically starting disko-install-menu on tty1.

      WARNING: This means that users gain effectivelly full root access
      without supplying any credential
    ''; # mkEnableOption -> dot at end is added

    options = mkOption {
      description = ''
        Passthrough options for disko-install-menu.
      '';
      type = menuOptions;
      default = { };
    };

    package = mkPackageOption pkgs "disko-install-menu" { };

  };

  config = mkIf (cfg.enable) {

    systemd.services.disko-install-menu = mkIf (cfg.autoStart) {
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        ConditionPathExists = singleton "/dev/tty1";
        After = [ "getty.target" ];
        Conflicts = [ "getty@tty1.service" ];
      };
      serviceConfig = {
        Restart = "always";
        RestartSec = 0;
        StandardInput = "tty";
        StandardOutput = "tty";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        TTYVDisallocate = true;
      };
      script = ''
        ${pkgs.util-linux}/bin/dmesg -D || true  # disable kernel log on tty
        ${getExe cfg.package} --no-global-exit
      '';
    };

    environment.etc."disko-install-menu/config".source =
      cfgFormat.generate "disko-install-menu-config" cfg.options;

    environment.systemPackages = [ cfg.package ];

  };

}
