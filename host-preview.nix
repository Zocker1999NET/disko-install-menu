# used by setup itself to retrieve existing description or fall back to generating itself
{ config, ... }@host: config.system.description or import ./support/host-preview.nix host
