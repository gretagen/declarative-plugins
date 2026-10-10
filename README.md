# declarative-plugins

A second Zeta repository, holding the **declarative helper plugins** for
Haliade OS: extra generators that let you declare things in
`/etc/haliade/definition.lua` beyond what `declaration` alone provides.

Each helper ships a generator (`usr/lib/declaration/generators/<name>.lua`) plus
a plugin config (`etc/haliade/plugin-configs/<name>.lua`) that gives its section
a default and type schema, so `haliade-synchronize` can parse it. Enable a
helper by adding its section name to `/etc/haliade/enabled_modules.lua`.

## Plugins

| Plugin | Section | Backing tool |
|---|---|---|
| [nix-declarative-helper](packages/nix-declarative-helper) | `["nixpkgs"]` | `nix profile` (system profile) |
| [flatpak-declarative-helper](packages/flatpak-declarative-helper) | `["flatpak"]` | `flatpak --system` |

## Using this repository

Zeta 1.0.50+ can consult several repositories at once. Add this one after the
central index in `/etc/zeta/configuration.lua`:

```lua
return {
  repos = {
    "https://github.com/gretagen/zeta-index",
    "https://github.com/gretagen/declarative-plugins",
  },
  ...
}
```

or via the environment: `ZETA_REPOS="https://github.com/gretagen/zeta-index https://github.com/gretagen/declarative-plugins"`.

## Layout

- `packages/` — the repository itself: `index.lua`, per-package `package.lua`
  manifests, and their tarball artifacts.
- `sources/` — the editable sources each tarball is built from.
