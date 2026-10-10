-- nixpkgs plugin config — shipped by the nix-declarative-helper package.
--
-- Auto-loaded by declaration's config.lua on every sync, giving the
-- ["nixpkgs"] section its default value and type schema. You normally never
-- need to touch this file: it just lets haliade-synchronize parse the section.
-- Enable the generator itself in /etc/haliade/enabled_modules.lua.

defaults["nixpkgs"] = {}
schema["nixpkgs"] = "table"