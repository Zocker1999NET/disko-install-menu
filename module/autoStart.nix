# type: NixOS module
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.disko-install-menu;

  inherit (builtins) concatStringsSep;
  inherit (lib.lists) singleton;
  inherit (lib.meta) getExe;
  inherit (lib.modules) mkIf;
  inherit (lib.options) mkEnableOption;
in
{

  options.programs.disko-install-menu = {

    autoStart = mkEnableOption ''
      automatically starting disko-install-menu on tty1.

      WARNING: This means that users gain effectivelly full root access
      without supplying any credential
    ''; # mkEnableOption -> dot at end is added

    debugMode = mkEnableOption ''
      debug mode for disko-install-menu.

      It will make it easier to view error messages
      logged by disko-install-menu
      by launching it inside a tmux session.

      This option is applicable when combined with
      {option}`programs.disko-install-menu.autoStart`
    ''; # mkEnableOption -> dot at end is added

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
        RestartSec = "5s";
        StandardInput = "tty";
        StandardOutput = "tty";
        StartLimitIntervalSec = "0"; # allow unlimited amount of restarts
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        TTYVDisallocate = true;
      };
      script = ''
        ${pkgs.util-linux}/bin/dmesg -D || true  # disable kernel log on tty
        ${
          if cfg.debugMode then
            "${getExe pkgs.tmux} "
            + concatStringsSep " \\; " [
              "start-server"
              "new-session -d ${getExe cfg.package}"
              "set-option -s remain-on-exit"
              "attach-session"
            ]
          else
            "${getExe cfg.package} --no-global-exit"
        }
      '';
    };

  };

}
