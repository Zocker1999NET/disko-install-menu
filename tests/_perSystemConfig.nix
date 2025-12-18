# type: flake-parts module
{
  flake-parts-lib,
  lib,
  self,
  ...
}@top:
let
  inherit (builtins) listToAttrs;
  inherit (lib) types;
  inherit (lib.attrsets) mapAttrsToList nameValuePair;
  inherit (lib.lists) flatten singleton;
  inherit (lib.options) mkOption;
  inherit (lib.trivial) flip pipe;
  inherit (flake-parts-lib) mkTransposedPerSystemModule;
in
{

  imports = singleton (mkTransposedPerSystemModule {
    file = ./_perSystemConfig.nix;
    name = "nixosTemplates";
    option = mkOption {
      description = ''
        An attrset of NixOS configurations
        which are defined independent of their system
        (i.e. similar for different architectures).

        So those are exported like `packages`,
        i.e. `nixosTemplates.<system>.<name>`.
        For convienence, those are also exported
        as `nixosConfigurations.<name>_<system>`.
      '';
      type = with types; attrsOf (raw // { description = "NixOS configuration"; });
      default = { };
    };
  });

  config.flake.nixosConfigurations = pipe self.nixosTemplates [
    (mapAttrsToList (system: cfgs: { inherit system cfgs; }))
    (map (
      { system, cfgs }: flip mapAttrsToList cfgs (name: cfg: nameValuePair "${name}_${system}" cfg)
    ))
    flatten
    listToAttrs
  ];

}
