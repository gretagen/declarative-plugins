#!/bin/sh
# nix-declarative-helper — enable declarative nixpkgs declarations in Haliade OS.
#
# The helper ships the "nixpkgs" generator (usr/lib/declaration/generators/
# nixpkgs.lua) and its plugin config (etc/haliade/plugin-configs/nixpkgs.lua,
# which gives the section its default + schema so config.lua parses it without
# anyone editing declaration itself). This script walks you through the two
# remaining manual steps and the sanity checks around them.

set -u

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
nix-declarative-helper — declare nixpkgs packages in Haliade OS

Setup (two steps):

  1. nix must be installed — check with:
         nix-declarative-helper --verifynix
     (install it with: zeta -Provide nix)

  2. Enable the generator: edit /etc/haliade/enabled_modules.lua and add
     "nixpkgs" to the list inside the file:

         local enabled_generators = {
           ...
           "nixpkgs",
         }

     The plugin config needed to parse the ["nixpkgs"] section ships with
     this package (/etc/haliade/plugin-configs/nixpkgs.lua) and is loaded
     automatically on every sync — no declaration files need editing.

Then declare packages in /etc/haliade/definition.lua:

         ["nixpkgs"] = {
           "nixpkgs#fastfetch",
           "nixpkgs#ripgrep",
           "github:guibou/nixGL",
         },

Declared packages install into the system profile
(/nix/var/nix/profiles/default), visible to all users.

and run:  haliade-synchronize

Commands:
  --help        show this message
  --verifynix   report whether nix is installed (exit 0 = yes, 1 = no)
EOF
}

verifynix() {
  if command -v nix >/dev/null 2>&1; then
    echo "nix is installed: $(nix --version 2>/dev/null | head -n1)"
    if [ -d /nix/store ]; then
      echo "nix store: /nix/store present"
    else
      echo "warning: nix is installed but /nix/store does not exist" >&2
    fi
    echo "note: nix-daemon is not auto-configured for your init — set it up manually"
    return 0
  fi
  echo "nix is NOT installed."
  echo "install it with: zeta -Provide nix"
  return 1
}

case "${1:-}" in
  --help|-h)
    usage
    ;;
  --verifynix)
    verifynix
    ;;
  "")
    usage >&2
    exit 1
    ;;
  *)
    echo "unknown option: $1" >&2
    echo "run 'nix-declarative-helper --help' for usage." >&2
    exit 1
    ;;
esac