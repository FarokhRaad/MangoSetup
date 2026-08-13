#!/usr/bin/env bash
# =============================================================================
#  20-symlink.sh - deploy configs/ via symlinks, repo stays the source of truth
# =============================================================================
#  WHY: without this, every tweak you make while actually using mango lives
#  only in ~/.config and has to be manually diffed back into this repo before
#  a git push, which is exactly the "go over all the changes again" problem.
#
#  This script instead symlinks each file under configs/ into its real
#  location in $HOME (e.g. configs/.config/mango/conf/monitors.conf ->
#  ~/.config/mango/conf/monitors.conf). Editing the file at either path
#  edits the same inode, so:
#    - live tweaks made while using the desktop are ALREADY inside the repo
#    - `git status` in the repo shows exactly what changed, any time
#    - `git add -p && git commit && git push` ships them, no copying step
#
#  This mirrors the standard dotfiles-symlink pattern (GNU Stow does the
#  same thing as a generic tool; this script is a purpose-built version of
#  it so it can validate the mango config and warn about conflicts).
#
#  Usage:
#    ./20-symlink.sh                 symlink everything under configs/
#    ./20-symlink.sh --status        show what is / isn't symlinked, no changes
#    ./20-symlink.sh --dry-run       show what would happen, no changes
#    ./20-symlink.sh --unlink        replace symlinks with real file copies
#                                    (reverts to a normal, non-synced setup)
#
#  Conflict handling: if a real (non-symlink) file already exists at the
#  target path, it is backed up to <path>.pre-mangosetup-<timestamp> and
#  never deleted.
# =============================================================================
set -uo pipefail

MODE="link"
for arg in "$@"; do
  case "$arg" in
    --status)  MODE="status" ;;
    --dry-run) MODE="dry-run" ;;
    --unlink)  MODE="unlink" ;;
  esac
done

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ROOT="$REPO_ROOT/configs"
STAMP=$(date +%Y%m%d-%H%M%S)

[[ -d "$SRC_ROOT" ]] || { err "configs/ not found at $SRC_ROOT"; exit 1; }

step "Discovering files under configs/"
mapfile -t FILES < <(find "$SRC_ROOT" -type f | sort)
info "found ${#FILES[@]} file(s) to manage"

LINKED=0; ALREADY=0; CONFLICTS=0; MISSING_TARGET_DIR=0

for src in "${FILES[@]}"; do
  rel="${src#"$SRC_ROOT"/}"
  dst="$HOME/$rel"

  case "$MODE" in
    status)
      if [[ -L "$dst" ]]; then
        target=$(readlink -f "$dst")
        if [[ "$target" == "$src" ]]; then
          ok "$rel -> linked correctly"
          ((LINKED++))
        else
          warn "$rel -> symlink points elsewhere: $target"
          ((CONFLICTS++))
        fi
      elif [[ -e "$dst" ]]; then
        warn "$rel -> real file exists, NOT a symlink (edits here will not reach the repo)"
        ((CONFLICTS++))
      else
        info "$rel -> not deployed yet"
        ((MISSING_TARGET_DIR++))
      fi
      continue
      ;;

    unlink)
      if [[ -L "$dst" ]]; then
        target=$(readlink -f "$dst")
        if [[ "$target" == "$src" ]]; then
          rm "$dst"
          cp "$src" "$dst"
          ok "$rel -> unlinked, replaced with a plain copy"
        fi
      fi
      continue
      ;;
  esac

  #  link / dry-run mode
  mkdir_needed=$(dirname "$dst")
  if [[ ! -d "$mkdir_needed" ]]; then
    if [[ "$MODE" == "dry-run" ]]; then
      info "[DRY] would create directory: $mkdir_needed"
    else
      mkdir -p "$mkdir_needed"
    fi
    ((MISSING_TARGET_DIR++))
  fi

  if [[ -L "$dst" ]]; then
    target=$(readlink -f "$dst")
    if [[ "$target" == "$src" ]]; then
      ((ALREADY++))
      continue
    else
      warn "$rel: symlink exists but points to $target, not this repo"
      if [[ "$MODE" == "dry-run" ]]; then
        info "[DRY] would relink to $src"
      else
        ln -sf "$src" "$dst"
        ok "relinked: $rel"
      fi
      ((LINKED++))
      continue
    fi
  fi

  if [[ -e "$dst" ]]; then
    #  Real file (or directory) sitting where a symlink should go. Never
    #  delete it silently; back it up with a clear, unique name.
    backup="${dst}.pre-mangosetup-${STAMP}"
    ((CONFLICTS++))
    if [[ "$MODE" == "dry-run" ]]; then
      info "[DRY] would back up $dst -> $backup, then symlink"
    else
      mv "$dst" "$backup"
      ln -s "$src" "$dst"
      warn "backed up existing file: $backup"
      ok "linked: $rel"
      ((LINKED++))
    fi
    continue
  fi

  #  Nothing at the destination yet: plain new symlink.
  if [[ "$MODE" == "dry-run" ]]; then
    info "[DRY] would link: $rel"
  else
    ln -s "$src" "$dst"
    ok "linked: $rel"
  fi
  ((LINKED++))
done

step "Summary"
case "$MODE" in
  status)
    ok "linked correctly : $LINKED"
    ((CONFLICTS)) && warn "not linked / mismatched : $CONFLICTS"
    ((MISSING_TARGET_DIR)) && info "not deployed yet : $MISSING_TARGET_DIR"
    ;;
  dry-run)
    info "would link/relink : $LINKED"
    info "already correct   : $ALREADY"
    info "backups needed    : $CONFLICTS"
    info "new directories   : $MISSING_TARGET_DIR"
    ;;
  unlink)
    ok "symlinks replaced with plain file copies"
    info "MangoSetup is no longer synced; re-run without --unlink to relink"
    ;;
  link)
    ok "linked/relinked : $LINKED"
    ok "already correct : $ALREADY"
    ((CONFLICTS)) && warn "existing files backed up: $CONFLICTS (see *.pre-mangosetup-* alongside each)"
    info "From now on, editing a file at either its ~/.config path or its"
    info "configs/ path in this repo edits the SAME file. Use 'git status'"
    info "in the repo any time to see what changed while you were using mango."
    ;;
esac
