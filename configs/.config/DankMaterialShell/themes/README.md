# DankMaterialShell themes (custom only)

Deployed to `~/.config/DankMaterialShell/themes/` by `scripts/20-symlink.sh`.

## What is here, and what is deliberately NOT

Only themes that are **not obtainable from the official DMS registry**
(`github.com/AvengeMedia/dms-plugin-registry`, wired into DMS Settings ->
Plugins). Anything installable with two clicks in the UI is not vendored here,
so this directory does not rot into a stale mirror of upstream.

Dropped after comparing colour-by-colour against the registry:

| dropped | why |
|---|---|
| `everforest/` | byte-identical to registry `everforest` |
| `nord/` | same as registry `nord`, missing 2 newer keys |
| `tokyoNight/` | same as registry `tokyonight`, missing 2 newer keys |
| `tokyoNightNightMoon/` | same as registry `tokyonight-night-moon`, missing 2 keys |
| `gruvboxMaterial/` | registry `gruvbox-material` (1 colour differed) |

Those five were **older copies** of upstream themes, not customisations. Install
them from DMS Settings instead and they stay current.

## Kept

**Directory themes** (`<name>/theme.json`, listed by the DMS theme browser at
`$HOME/.config/DankMaterialShell/themes/<sourceDir>/theme.json`):

- `everforestHard/` and `gruvboxMaterialHard/`: the "hard contrast" variants,
  which the registry does not ship. They also define 17 colour keys against the
  registry's 9-10, so they are substantially richer, not just darker.

**Flat theme files** (`<name>.json`): 21 of them, plus 9 more under `Dank/`.
These are not listed by the theme browser; select one via Settings -> Theme ->
custom theme file, which sets `customThemeFile` to the file's path.

Includes several with no registry equivalent at all (`cosmic_order`, `sonokai`,
`sonokai_dim`, `e-ink`), the `*_dim` low-contrast set, and the `Dank/`
collection (cyberpunk electric, hotline miami, miami vice, Gruvbox-Green).

## Note on the flat format

The `*_dim` files put colour keys at the TOP LEVEL, with no `dark`/`light`
wrapper. That is valid for `customThemeFile` but means they carry a single
palette rather than a light/dark pair.

`e-ink.json` had a stray `git` token pasted into line 18, making it invalid
JSON, so DMS would have silently failed to load it. Fixed here; the copy in
`misc-linux/dotfiles/` is still broken if you use it from there.

## Why symlinks

`20-symlink.sh` links each file back to this repo, so editing a theme in
`~/.config/...` edits the repo copy and `git status` shows the change. Themes
you install from the registry land in the same directory and are simply
untracked.
