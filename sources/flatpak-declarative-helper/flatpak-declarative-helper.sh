#!/bin/sh
# flatpak-declarative-helper — enable declarative flatpak apps in Haliade OS.
#
# The helper ships the "flatpak" generator (usr/lib/declaration/generators/
# flatpak.lua) and its plugin config (etc/nacelle/plugin-configs/flatpak.lua,
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
flatpak-declarative-helper — declare flatpak apps in Haliade OS

Setup (two steps):

  1. flatpak must be installed — check with:
         flatpak-declarative-helper --verifyflatpak
     (install it with: zeta -Provide flatpak)

  2. Enable the generator: edit /etc/nacelle/enabled_modules.lua and add
     "flatpak" to the list inside the file:

         local enabled_generators = {
           ...
           "flatpak",
         }

     The plugin config needed to parse the ["flatpak"] section ships with
     this package (/etc/nacelle/plugin-configs/flatpak.lua) and is loaded
     automatically on every sync — no declaration files need editing.

Then declare apps in /etc/nacelle/definition.lua:

         ["flatpak"] = {
           "flathub:org.mozilla.firefox",
           "org.videolan.VLC",
         },

Each entry is either "remote:appid" or a bare "appid" (looked up on flathub).
Apps install system-wide (/var/lib/flatpak), visible to all users. If the
flathub remote is not configured yet it is added automatically; any other
missing remote is reported and skipped.

and run:  nacelle definition

Commands:
  --help            show this message
  --verifyflatpak   report whether flatpak is installed (exit 0 = yes, 1 = no)
EOF
}

verifyflatpak() {
  if command -v flatpak >/dev/null 2>&1; then
    echo "flatpak is installed: $(flatpak --version 2>/dev/null | head -n1)"
    if [ -d /var/lib/flatpak ]; then
      echo "system installation: /var/lib/flatpak present"
    else
      echo "note: no system installation yet (created on the first system-wide install)"
    fi
    echo "note: flatpak needs a working session bus for GUI apps — start it via your init"
    return 0
  fi
  echo "flatpak is NOT installed."
  echo "install it with: zeta -Provide flatpak"
  return 1
}

case "${1:-}" in
  --help|-h)
    usage
    ;;
  --verifyflatpak)
    verifyflatpak
    ;;
  "")
    usage >&2
    exit 1
    ;;
  *)
    echo "unknown option: $1" >&2
    echo "run 'flatpak-declarative-helper --help' for usage." >&2
    exit 1
    ;;
esac
