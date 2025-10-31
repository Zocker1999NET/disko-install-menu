{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) types;
  inherit (lib.modules) mkIf mkMerge;
  inherit (lib.options) mkOption;
  cfg = config.boot.loader;
in
{

  options.boot.loader.buildDependencies = mkOption {
    description = ''
      Derivations required for building a configuration
      when changes to the boot loader configuration are applied.

      This is intented to be used by installation ISOs
      to prepare for an offline installation or repair
      of a similar configuration (i.e. using the same bootloader).
    '';
    type = with types; listOf package;
    default = [ ];
  };

  config.boot.loader.buildDependencies = mkMerge [
    (mkIf (cfg.systemd-boot.enable) (
      with pkgs;
      [
        buildPackages.mypy
      ]
    ))
  ];

}
