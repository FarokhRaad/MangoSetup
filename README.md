# MangoSetup

Configuration and setup scripts for [mango](https://github.com/mangowm/mango)
(a dwl-based Wayland compositor) with
[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
([docs](https://danklinux.com/docs/)) as the shell, on Arch Linux.

This repo is designed to be reusable on a **clean/fresh Arch install**, not
just on the machine it was first written for. A one-time, host-specific
action — such as uninstalling whatever desktop environment happened to be on
the machine beforehand — deliberately lives *outside* this repo, in
`../one-time-migration/`, so nothing here assumes anything about what was
installed before.

## What's here

```
configs/            Files deployed into $HOME via symlinks (see below)
  .config/mango/    mango compositor config (config.conf + conf/*.conf).
                    config.conf also source-optional='s six DMS-generated
                    fragments from .config/mango/dms/ (colors, layout,
                    cursor, outputs, windowrules, binds) - those are
                    OUTPUT of `dms setup`, so they are gitignored, not
                    checked in. See config.conf's header for the ordering
                    rules that make that safe.
  .config/systemd/user/mango-session.target
                    session target DMS's dms.service binds to, so the shell
                    starts with mango and only with mango (see that unit's
                    header for why a bare `exec-once=dms run` is wrong)
  .config/qt5ct/    Qt5 theming (base qt5ct.conf checked in; colors/ holds
  .config/qt6ct/    Qt6 theming  only a .gitkeep - DMS runs matugen on every
                    theme change and writes the generated palette itself)
  .config/gtk-3.0/  GTK3 settings.ini (recovered from a broken live symlink,
  .config/gtk-4.0/  see that file's header)
  .config/nwg-look/ nwg-look export options
  .config/solaar/   Logitech mouse gesture rules (mmsg syntax fixed for 0.15.5)
  .config/fontconfig/  conf.d/76-noto-color-emoji.conf (emoji fallback)
  .config/bashrc/   modular bash config, sourced by .bashrc
  .config/zshrc/    modular zsh config, sourced by .zshrc (current, live setup)
  .config/starship.toml, fastfetch/, mimeapps.list
  .bashrc, .zshrc
packages/
  packages.txt        the base package manifest, one name per line
  app-catalog.txt      candidate apps per role for scripts/setup.sh's picker
scripts/
  setup.sh            interactive gum wizard; runs everything below in order
  00-preflight.sh      read-only system survey; run this first
  10-packages.sh       installs only what's missing (repo + AUR)
  20-symlink.sh        deploys configs/ into $HOME as symlinks
  30-system-tweaks.sh  fixes known issues, otherwise a no-op if already tuned
  40-root-symlink.sh   (sudo) links theming dirs into /root for root GUI apps
  60-session.sh        switches SDDM -> greetd + the DMS greeter (reversible)
  swap-app.sh          change a default app (terminal/browser/...) in one line
  validate-config.sh   lints the mango config against a real mango source tree
```

## Design principles

**1. Fresh-install safe.** Every script checks state before acting and skips
anything already correct. Running the whole sequence on a brand new Arch
install and on a machine that already has half of it configured produces the
same end result, with no duplicate work and nothing clobbered.

**2. The repo is the source of truth, not a one-time template.** `20-symlink.sh`
symlinks every file under `configs/` into its real location in `$HOME`
(e.g. `configs/.config/mango/conf/monitors.conf` -> `~/.config/mango/conf/monitors.conf`).
Editing the file at *either* path edits the same inode. That means:

- tweaks made while actually using mango day to day are **already** inside
  the repo, nothing to copy back
- `git status` in the repo shows exactly what changed, whenever you check
- `git add -p && git commit && git push` ships them directly

Run `./scripts/20-symlink.sh --status` any time to see what is and isn't
linked. `--unlink` reverts every file to a plain, unsynced copy if you ever
want to stop tracking live changes.

**3. Default apps are swappable, not hardcoded.** Nothing in `configs/`
references `konsole`, `dolphin`, or `microsoft-edge-stable` directly. Every
keybinding and autostart line spawns a role variable (`$TERMINAL`,
`$FILEMANAGER`, `$BROWSER`, ...) defined once in
`configs/.config/mango/conf/apps.conf`. mango's `spawn`/`spawn_shell`/
`exec-once` all expand `$VAR` against the environment mango itself sets via
`env=`, so changing a role and reloading (`SUPER+SHIFT+R`) is enough for
most apps: no config surgery required. See `apps.conf`'s header for exactly
how this works and the one thing it can't cover (window rules matching a
literal appid, e.g. pinning a messenger app to a tag).

To swap an app:

```bash
./scripts/swap-app.sh TERMINAL kitty
./scripts/swap-app.sh FILEMANAGER thunar
./scripts/swap-app.sh --list          # show current roles
```

The script validates the target binary exists (offering to install it if
not), edits `apps.conf`, and reminds you if a window rule needs a matching
update.

## Setup order

**Interactive (recommended):**

```bash
git clone <this-repo> MangoSetup && cd MangoSetup
./scripts/setup.sh
```

This walks all the steps below in order, with an interactive app picker
(see "Choosing apps interactively") inserted before package installation.
Each step asks for confirmation before doing anything; `Ctrl+C` at any point
leaves already-completed steps in place and you can rerun `setup.sh` or the
individual script safely (everything here is idempotent). `--dry-run` shows
what each step would do without installing/symlinking/tweaking anything.

**Manual (equivalent, step by step):**

```bash
./scripts/00-preflight.sh          # survey the system, no changes made
./scripts/10-packages.sh           # install mango + DankMaterialShell + deps
./scripts/20-symlink.sh            # deploy configs/ as symlinks
./scripts/30-system-tweaks.sh      # fix known issues, skip what's already tuned
sudo ./scripts/40-root-symlink.sh  # make root's GUI apps match your theme
./scripts/validate-config.sh ~/.config/mango   # sanity-check before logging in
```

Then log into a mango session (from your display manager, or `mango` from a
TTY) and verify:

- the DMS bar appears on every monitor
- tags/workspaces switch and reflect in the bar
- the launcher opens (`SUPER+A`)
- the lock screen works (`SUPER+ALT,L`)
- screen sharing and a file picker both work (portal check)
- audio, brightness and media keys respond
- `dms doctor` reports no missing dependency
- `SUPER+SHIFT+slash` brings up DMS's live keybind cheat sheet

Only after that is confirmed working should you consider switching your
display manager or removing a previous desktop environment:

```bash
./scripts/60-session.sh            # switch SDDM -> greetd + the DMS greeter
                                    # (reversible: ./scripts/60-session.sh --revert)
```

Uninstalling a previously installed desktop environment is **not** part of
this repo: it is a one-time action tied to one host's history, not something
a reusable setup should do. That kind of step lives in
`../one-time-migration/` (e.g. `70-remove-plasma.sh`); see its own header for
the reasoning.

## Choosing apps interactively

`scripts/setup.sh` reads `packages/app-catalog.txt`, a curated list of
verified apps per role (terminal, browser, file manager, editor, image
viewer, document viewer, media player, messenger). For each category it
shows a **multi-select** list (`gum choose --no-limit`): space to toggle any
number of entries, enter to confirm. Already-installed apps start
pre-checked.

Multiple apps per category is the normal case, not an edge case: selecting
Firefox, Edge, and Brave together in the Browser category installs and
registers all three side by side. Nothing forces a single choice.

What *does* stay single-valued is which one is the **active default** (the
one mango's keybindings and autostart lines actually launch), controlled by
`configs/.config/mango/conf/apps.conf`'s role variables (see that file and
`swap-app.sh` above). If you picked only one app in a category, it becomes
the default automatically. If you picked more than one, the wizard asks a
follow-up question (which one should be the default) and writes that
choice into `apps.conf` (matching its real `env=ROLE,value` syntax); the
others still install and stay fully launchable, just not bound to a
keypress until you `swap-app.sh` to them later.

`app-catalog.txt` is plain data (`role|package|binary|source|label` per
line); add a row to add a new candidate app to any category, or a new role
if `apps.conf` doesn't have one yet.

## Validating changes

`scripts/validate-config.sh` clones (or reuses) a real mango source tree and
checks the deployed config against mango's actual parser: every key, every
dispatcher, every windowrule/tagrule/layerrule option, duplicate keybindings
(mango 0.15.5+ silently applies only the first of a conflicting pair), and
old positional `monitorrule=` syntax. Run it after any edit:

```bash
./scripts/validate-config.sh ~/.config/mango
```

## Default apps

Nothing in `configs/` hardcodes a terminal, browser, file manager, or editor
name; see `configs/.config/mango/conf/apps.conf` and `scripts/swap-app.sh`
above for how to change one. The one place the `$ROLE` variables do **not**
reach is anything outside mango's own config, since only mango expands them:

- **DMS's generated keybinds** (`~/.config/mango/dms/binds.conf`) resolve
  their terminal at `dms setup binds` time and end up with a literal command,
  so `SUPER+Return` and `SUPER+t` launch that fixed terminal. `SUPER+I` in
  `conf/keybindings.conf` is the role-aware equivalent and does honour
  `$TERMINAL`.
- **DMS's own settings** live in `~/.config/DankMaterialShell/settings.json`.
  That file is per-machine runtime state written by the shell, so it is
  gitignored and is **not** edited in this repo — change it through the
  Settings UI instead:

  ```bash
  dms ipc call settings focusOrToggle
  ```

  DMS also has its own default-app notion (`dms ipc call defaultApp browser`,
  `... fileManager`, ...) which is independent of `apps.conf`.

## Compositor and shell versions this targets

- **mango** 0.16.0+ (`github.com/mangowm/mango`, AUR package `mangowm`,
  binary `mango`)
- **DankMaterialShell** (`github.com/AvengeMedia/DankMaterialShell`, docs at
  <https://danklinux.com/docs/>) — a Quickshell (QML) + Go shell. This repo
  installs `dms-shell-git` from the AUR; `dms-shell` in the official
  `[extra]` repo is the stable equivalent and is a drop-in swap in
  `packages/packages.txt`.

Hard dependencies worth knowing about:

- `quickshell` — in `[extra]`, DMS's only hard UI dependency.
- `dgop` — DMS's system-metrics backend, a hard dependency. It is now in the
  official `[extra]` repo, so no AUR package is needed. (Historically the AUR
  `dgop-git` failed to build: its PKGBUILD built `./cmd/cli`, a path upstream
  renamed to `cmd/dgop`.)
- `accountsservice` — hard dependency of `dms-shell`.

Why DMS specifically: it has genuine first-class mango support, not a generic
fallback. It ships a `MangoService` that speaks mango's native
JSON-over-Unix-socket IPC, and `dms setup <fragment>` generates real mango
config fragments into `~/.config/mango/dms/`:

```bash
dms setup colors | layout | cursor | outputs | windowrules | binds
```

`configs/.config/mango/config.conf` picks all six up with `source-optional=`
lines placed **last**, which matters in two directions: last for scalar keys
so DMS's live matugen palette overrides `appearance.conf`'s static fallback,
and last for binds because mango 0.15.5 applies only the **first** bind for a
given modifier+key and silently drops later duplicates. Since DMS ships its
own binds fragment, every colliding binding was removed from
`conf/keybindings.conf` (39 collisions, plus 43 old-shell bindings) rather
than left to fight over order. See both files' headers for the full split of
who owns which key.

CLI surface (all of it is `dms`, there is no separate helper binary):

```bash
dms ipc call <target> <function> [args]   # BOTH target and function required
dms doctor                                # diagnose the install
dms screenshot [full|window]
dms setup <fragment>
dms restart
```

Useful IPC targets: `spotlight` / `spotlight-bar` (launcher), `clipboard`,
`notifications`, `settings`, `lock`, `control-center`, `bar`, `audio`,
`brightness`, `color-picker`, `processlist`, `powermenu`, `keybinds`,
`notepad`, `dash`, `inhibit`. `dms ipc --help` lists every target with its
valid functions.

DMS runs as a **systemd user service** (`dms.service`), bound to
`mango-session.target` (unit shipped at
`configs/.config/systemd/user/mango-session.target`) and started by
`conf/autostart.conf`:

```
exec-once=systemctl --user start mango-session.target
```

This is deliberately *not* a bare `exec-once=dms run`, which would lose
`Restart=on-failure` and, if enabled globally instead, would start the shell
in every user session including a plain TTY login.

Theming is driven by matugen: DMS regenerates the palette on every theme or
wallpaper change and writes
`~/.local/share/color-schemes/DankMatugen{,Light,Dark}.colors` plus
`~/.config/qt{5,6}ct/colors/matugen.conf`. The checked-in `qt5ct.conf` /
`qt6ct.conf` point `color_scheme_path` at `DankMatugen.colors` so a fresh
deploy and a running shell agree instead of rewriting each other.

The login screen uses the matching greeter: AUR `greetd-dms-greeter-bin`,
binary `/usr/bin/dms-greeter`. `scripts/60-session.sh` switches the display
manager over to greetd + that greeter and reverts with `--revert`. Note that
`--command COMPOSITOR` is **mandatory** for `dms-greeter` (it exits with an
error otherwise, which greetd surfaces only as "no login screen"), so the
generated greetd config passes `--command mango`; `mango` is a supported
value, and the package's own post-install example showing `--command niri`
would launch the wrong compositor.
