{ config, lib, ... }@host:
let
  # lib
  inherit (builtins)
    attrValues
    concatStringsSep
    filter
    isNull
    ;
  inherit (lib.lists) optionals;
  # custom lib
  prefix = pref: val: if isNull val then null else "${pref}${val}";
  parseAttr =
    mapFun: filterFun: attr:
    map mapFun (filter filterFun (attrValues attr));
  formatList = title: list: if list == [ ] then null else "${title}" + (concatStringsSep ", " list);
  compileList = list: concatStringsSep "\n" (filter (x: !isNull x) list);
  # vars
  cfg = config;
  sys = cfg.system;
  version = sys.nixos.version;
  label = sys.nixos.label;
  variantStr = if isNull sys.nixos.variant_id then "" else " ${sys.nixos.variant_id}";
in
compileList (
  [
    "hostname:  ${cfg.networking.hostName}"
    (prefix "domain  :  " cfg.networking.domain)
    "system  :  NixOS${variantStr} ${sys.nixos.release} (${sys.nixos.codeName})"
    "arch    :  ${cfg.nixpkgs.system}"
    "version :  ${version}"
    (if label == version then null else "label   :  ${label}")
    (prefix "revision:  " sys.configurationRevision)
    ""
    (formatList "users:  " (parseAttr (x: x.name) (x: x.isNormalUser) cfg.users.users))
  ]
  ++ optionals (cfg ? disko) [
    ""
    (formatList "disko disks:  " (parseAttr (x: x.name) (x: true) cfg.disko.devices.disk))
  ]
)
