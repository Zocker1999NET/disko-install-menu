{ config, lib, ... }@host:
let
  inherit (lib) types;
  inherit (lib.modules) mkAfter mkIf;
  inherit (lib.options) literalMD mkEnableOption mkOption;
  inherit (lib.trivial) pipe;
  mkDisableOption =
    desc:
    (mkEnableOption desc)
    // {
      default = true;
      example = false;
    };
in
{

  imports = [
    ./bootloader-dependencies.nix
  ];

  options.system = {

    description = mkOption {
      description = ''
        Text for describing this configuration,
        preferably in Markdown format.

        Can be used to describe the purpose of a machine
        or to describe the goals of a given configuration.

        Intended to be used by e.g. installers
        presenting users a selection of configurations.

        Multiple values are joined in separate paragraphs.
      '';
      type = with types; nullOr (separatedString "\n\n");
      default = null;
      defaultText = literalMD "see {option}`system.disko-install-menu.generatePreview`";
      example = ''
        This configuration provides the default KDE desktop experience
        similar to the one provided by the NixOS live ISO.
      '';
    };

    disko-install-menu = {
      generatePreview = mkDisableOption ''
        Generates a preview of important configuration values
        and provides them as {option}`system.description`.

        This includes e.g.:
        - networking hostname & domain
        - architecture & OS version
        - list of configured (non-system) users
        - list of configured disko disks

        This generated preview is appended with mkAfter order.
      '';
    };

  };

  config = {
    system.description = pipe host [
      (import ./host-preview.nix)
      mkAfter
      (mkIf config.system.disko-install-menu.generatePreview)
    ];
  };

}
