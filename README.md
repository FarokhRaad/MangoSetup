# MangoSetup

Configuration and setup scripts for [mango](https://github.com/mangowm/mango)
(a dwl-based Wayland compositor) with [Noctalia](https://github.com/noctalia-dev/noctalia)
v5 as the shell, on Arch Linux.

This repo is designed to be reusable on a **clean/fresh Arch install**, not
just on the machine it was first written for. Anything that only makes sense
once, on one specific machine (like removing a previous desktop environment),
deliberately lives *outside* this repo, in `../one-time-migration/`.

## What's here

```
configs/            Files deployed into $HOME via symlinks (see below)
  .config/mango/    mango compositor config (config.conf + conf/*.conf)
  .config/noctalia/ Noctalia v5 shell config (config.toml)
  .config/qt5ct/    Qt5 theming (base config.conf checked in; colors/
  .config/qt6ct/    Qt6 theming  written by Noctalia's "qt" template, empty
                    until that template first runs)
  .config/gtk-3.0/  GTK3 settings.ini (recovered from a broken live symlink,
  .config/gtk-4.0/  see that file's header)
  .config/nwg-look/ nwg-look export options
  .config/solaar/   Logitech mouse gesture rules (mmsg syntax fixed for 0.15.5)
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
  60-session.sh        switches SDDM -> greetd + Noctalia Greeter (reversible)
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

## Setup order (fresh install or this machine)

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
./scripts/10-packages.sh           # install mango + Noctalia + deps
./scripts/20-symlink.sh            # deploy configs/ as symlinks
./scripts/30-system-tweaks.sh      # fix known issues, skip what's already tuned
sudo ./scripts/40-root-symlink.sh  # make root's GUI apps match your theme
./scripts/validate-config.sh ~/.config/mango   # sanity-check before logging in
```

Then log into a mango session (from your display manager, or `mango` from a
TTY) and verify:

- the Noctalia bar appears on every monitor
- tags/workspaces switch and reflect in the bar
- the launcher opens (`SUPER+A`)
- the lock screen works (`SUPER+ALT,L`)
- screen sharing and a file picker both work (portal check)
- audio, brightness and media keys respond

Only after that is confirmed working should you consider switching your
display manager or removing a previous desktop environment:

```bash
./scripts/60-session.sh            # switch SDDM -> greetd + Noctalia Greeter
                                    # (reversible: ./scripts/60-session.sh --revert)
```

Removing a previous desktop environment is **not** part of this repo; see
`../one-time-migration/70-remove-plasma.sh` and its own header for why.

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
above for how to change one. `configs/.config/noctalia/config.toml` is
separate: Noctalia's TOML has no variable expansion, so its `dock.pinned`
list (if you enable the dock) references app names directly and needs a
manual edit if you swap something referenced there.

## Compositor and shell versions this targets

- **mango** 0.15.5+ (`github.com/mangowm/mango`, AUR package `mangowm`)
- **Noctalia** v5 (native C++ rewrite, AUR package `noctalia`, IPC via
  `noctalia msg <command>`, config at `~/.config/noctalia/config.toml`)

Noctalia v4.x (the earlier Quickshell/QML generation, AUR package
`noctalia-shell`) is a **different, incompatible** IPC surface
(`qs -c noctalia-shell ipc call ...`) and different layer-shell namespaces.
This repo does not support it.
