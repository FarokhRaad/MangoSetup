#!/usr/bin/env bash
# =============================================================================
#  setup.sh - interactive, gum-based MangoSetup installer wizard
# =============================================================================
#  Walks the full install in order, with an interactive app picker inserted
#  before package installation. Every step below is just this wizard calling
#  the individually-runnable scripts in this directory; nothing here
#  duplicates their logic; skipping this wizard and running them by hand in
#  the same order works identically (see README.md).
#
#  App picker: for each category (terminal, browser, file manager, ...) you
#  can select MULTIPLE apps, not just one. For example selecting Firefox,
#  Edge, and Brave together in the Browser category installs and registers
#  ALL THREE; nothing here forces a single choice. What DOES stay
#  single-valued is which one is the ACTIVE DEFAULT that mango's keybindings
#  and exec-once lines launch (configs/.config/mango/conf/apps.conf's
#  $ROLE variables; see that file and scripts/swap-app.sh). The wizard asks
#  for that default separately, right after the multi-select, only from
#  among what you just chose to install.
#
#  Requires: gum (see packages/packages.txt; installed by 10-packages.sh,
#  but the wizard needs it BEFORE that step runs, so it bootstraps it first
#  if missing).
#
#  Usage:
#    ./setup.sh              run the full interactive wizard
#    ./setup.sh --dry-run    show what each step would do without changing
#                            anything (passed through to the sub-scripts
#                            that support it; the app picker itself always
#                            runs interactively since it has no side effects
#                            until you confirm)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CATALOG="$REPO_DIR/packages/app-catalog.txt"
#  Single definition of apps.conf's path, used by both the catalog sanity
#  gate and the apply-defaults step, so the two can never disagree.
APPS_CONF="$REPO_DIR/configs/.config/mango/conf/apps.conf"
APPS_CONF_CHECK="$APPS_CONF"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mangosetup"
SELECTIONS_FILE="$STATE_DIR/selected-packages.txt"

DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }

mkdir -p "$STATE_DIR"

# -----------------------------------------------------------------------------
#  gum bootstrap: the wizard needs gum before 10-packages.sh has run.
# -----------------------------------------------------------------------------
if ! command -v gum &>/dev/null; then
  printf '%s\n' "gum (the TUI toolkit this wizard uses) is not installed yet."
  read -rp "Install it now from the official repos? [Y/n] " reply
  if [[ -z "$reply" || "$reply" == "y" || "$reply" == "Y" ]]; then
    sudo pacman -S --needed --noconfirm gum || { err "failed to install gum"; exit 1; }
  else
    err "gum is required for this wizard. Run ./10-packages.sh manually instead."
    exit 1
  fi
fi

banner() {
  gum style --border double --border-foreground 212 --padding "1 4" --margin "1 0" \
    --align center "$1"
}
section() {
  gum style --foreground 99 --bold --margin "1 0" "▶ $1"
}

clear
banner "MangoSetup
mango + DankMaterialShell interactive installer"

gum style --faint "This wizard runs the numbered scripts in this directory in
order, with an interactive app picker before package installation.
Nothing is installed or changed until you confirm each step."
echo

if ! gum confirm "Ready to begin?"; then
  info "cancelled, nothing was changed"
  exit 0
fi

# =============================================================================
#  STEP 1: preflight (read-only survey)
# =============================================================================
section "Step 1 / 7 - System survey (read-only, no changes)"
if gum confirm --default "Run 00-preflight.sh now?"; then
  gum spin --spinner dot --title "Surveying system..." -- \
    bash -c "'$SCRIPT_DIR/00-preflight.sh' > '$STATE_DIR/preflight.log' 2>&1" \
    || warn "preflight reported issues, see $STATE_DIR/preflight.log"
  gum pager < "$STATE_DIR/preflight.log" 2>/dev/null || cat "$STATE_DIR/preflight.log"
else
  info "skipped"
fi

# =============================================================================
#  STEP 2: interactive app picker (multi-select per category)
# =============================================================================
section "Step 2 / 7 - Choose applications"
gum style --faint "For each category, pick as many apps as you want installed.
Space to toggle, Enter to confirm. Already-installed apps start checked."

mkdir -p "$STATE_DIR"
: > "$SELECTIONS_FILE"

[[ -f "$CATALOG" ]] || { err "app catalog not found: $CATALOG"; exit 1; }

# -----------------------------------------------------------------------------
#  Catalog sanity gate.
#  Two failure modes bit this picker before and BOTH were silent, so they are
#  now hard-checked up front instead of producing a broken picker:
#
#  1. A literal COMMA in any label. `gum choose --selected=<list>` is
#     comma-delimited, so one comma inside a label fragments the preselect
#     string into non-matching tokens. Symptom: an already-installed app
#     renders UNCHECKED with no error anywhere. (Real case: a label reading
#     "Foo (bar - special-cased, see apps.conf)" split into 2 bogus tokens.)
#
#  2. A catalog role with NO matching `env=ROLE,` line in apps.conf. The
#     "apply chosen defaults" step below can then never write that role's
#     choice, warning only in passing. Checked here so it fails loudly.
# -----------------------------------------------------------------------------
catalog_issues=0

if bad_labels=$(awk -F'|' '!/^#/ && NF>=5 && $5 ~ /,/ {printf "    line %d: %s\n", NR, $5}' "$CATALOG") \
   && [[ -n "$bad_labels" ]]; then
  err "app-catalog.txt has commas in these labels, which breaks gum's --selected:"
  printf '%s\n' "$bad_labels"
  err "Use ' - ' or '/' instead of a comma."
  catalog_issues=1
fi

if [[ -f "$APPS_CONF_CHECK" ]]; then
  while read -r crole; do
    [[ -n "$crole" ]] || continue
    grep -q "^env=${crole}," "$APPS_CONF_CHECK" || {
      err "catalog role '$crole' has no 'env=${crole},<value>' line in apps.conf"
      catalog_issues=1
    }
  done < <(cut -d'|' -f1 "$CATALOG" | grep -vE '^#|^$' | awk '!seen[$0]++')
fi

if (( catalog_issues )); then
  err "fix packages/app-catalog.txt (and/or apps.conf) before running the picker"
  exit 1
fi
ok "app catalog sane: no comma-in-label, every role maps to an apps.conf entry"

#  Categories in a fixed, sensible order; derived from the roles actually
#  present in the catalog so adding a new role there Just Works here too.
mapfile -t CATEGORIES < <(cut -d'|' -f1 "$CATALOG" | grep -v '^#' | grep -v '^$' | awk '!seen[$0]++')

declare -A CATEGORY_DEFAULT   # role -> chosen default binary, filled in below

for role in "${CATEGORIES[@]}"; do
  mapfile -t ROWS < <(awk -F'|' -v r="$role" '$1==r {print}' "$CATALOG")
  ((${#ROWS[@]})) || continue

  #  Build display labels "Label (package)" -> keep a lookup back to the
  #  full row (package|binary|source) via label-delimiter.
  declare -A LABEL_TO_ROW=()
  DISPLAY=()
  PRESELECT=()
  for row in "${ROWS[@]}"; do
    IFS='|' read -r _ pkg bin src label <<<"$row"
    disp="$label  [$pkg]"
    DISPLAY+=("$disp")
    LABEL_TO_ROW["$disp"]="$row"
    if command -v "$bin" &>/dev/null || pacman -Qi "$pkg" &>/dev/null; then
      PRESELECT+=("$disp")
    fi
  done

  preselect_arg=""
  if ((${#PRESELECT[@]})); then
    preselect_arg=$(IFS=,; echo "${PRESELECT[*]}")
  fi

  echo
  mapfile -t CHOSEN < <(printf '%s\n' "${DISPLAY[@]}" \
    | gum choose --no-limit --height 12 \
        --header "Category: $role  (space = toggle, enter = confirm)" \
        ${preselect_arg:+--selected="$preselect_arg"})

  if ((${#CHOSEN[@]} == 0)); then
    info "$role: nothing selected, skipping"
    unset LABEL_TO_ROW
    continue
  fi

  #  Record every chosen package for 10-packages.sh, and figure out the
  #  default. If more than one was chosen, ask which is the active default;
  #  apps.conf still only launches ONE app per role at a time.
  CHOSEN_BINS=()
  for disp in "${CHOSEN[@]}"; do
    row="${LABEL_TO_ROW[$disp]}"
    IFS='|' read -r _ pkg bin src label <<<"$row"
    echo "$pkg" >> "$SELECTIONS_FILE"
    CHOSEN_BINS+=("$bin|$label")
  done

  if ((${#CHOSEN_BINS[@]} == 1)); then
    IFS='|' read -r only_bin only_label <<<"${CHOSEN_BINS[0]}"
    CATEGORY_DEFAULT["$role"]="$only_bin"
    ok "$role: installing $only_label (only choice, set as default)"
  else
    LABELS=()
    for cb in "${CHOSEN_BINS[@]}"; do IFS='|' read -r _ l <<<"$cb"; LABELS+=("$l"); done
    default_label=$(printf '%s\n' "${LABELS[@]}" \
      | gum choose --height 8 --header "Which $role should be the DEFAULT (used by mango keybindings)? The others still install and remain launchable.")
    for cb in "${CHOSEN_BINS[@]}"; do
      IFS='|' read -r b l <<<"$cb"
      [[ "$l" == "$default_label" ]] && CATEGORY_DEFAULT["$role"]="$b"
    done
    ok "$role: installing ${#CHOSEN_BINS[@]} apps, default = $default_label"
  fi
  unset LABEL_TO_ROW
done

info "selections written to $SELECTIONS_FILE ($(wc -l < "$SELECTIONS_FILE") package(s))"

# -----------------------------------------------------------------------------
#  Write chosen defaults into apps.conf (only roles the picker touched;
#  anything skipped keeps apps.conf's existing default untouched).
# -----------------------------------------------------------------------------
if ((${#CATEGORY_DEFAULT[@]})) && [[ -f "$APPS_CONF" ]]; then
  section "Applying chosen defaults to apps.conf"
  for role in "${!CATEGORY_DEFAULT[@]}"; do
    bin="${CATEGORY_DEFAULT[$role]}"
    #  apps.conf uses mango's own env=ROLE,value syntax (see that file's
    #  header), NOT ROLE=value; matching that exactly here so this
    #  actually updates the file instead of silently no-op'ing.
    if grep -q "^env=${role}," "$APPS_CONF"; then
      if $DRY_RUN; then
        info "[DRY] would set env=${role},${bin} in apps.conf"
      else
        sed -i "s|^env=${role},.*|env=${role},${bin}|" "$APPS_CONF"
        ok "${role} default -> ${bin}"
      fi
    else
      warn "apps.conf has no 'env=${role},...' line (role name mismatch, or"
      warn "this role has no apps.conf entry yet); default not applied for ${role}."
      warn "Add 'env=${role},${bin}' to apps.conf manually, or use scripts/swap-app.sh."
    fi
  done
fi

# =============================================================================
#  STEP 3: package installation
# =============================================================================
section "Step 3 / 7 - Install packages"
if gum confirm --default "Install mango + DankMaterialShell + your chosen apps now?"; then
  extra_flag=()
  $DRY_RUN && extra_flag+=(--dry-run)
  EXTRA_PKG_FILE="$SELECTIONS_FILE" "$SCRIPT_DIR/10-packages.sh" "${extra_flag[@]}"
else
  info "skipped; run later with: EXTRA_PKG_FILE=$SELECTIONS_FILE ./10-packages.sh"
fi

# =============================================================================
#  STEP 4: symlink configs
# =============================================================================
section "Step 4 / 7 - Deploy configs (symlink into \$HOME)"
if gum confirm --default "Symlink configs/ into your home directory now?"; then
  "$SCRIPT_DIR/20-symlink.sh"
else
  info "skipped; run later with: ./20-symlink.sh"
fi

# =============================================================================
#  STEP 5: system tweaks
# =============================================================================
section "Step 5 / 7 - System tweaks (idle, mkinitcpio dupe fix, etc.)"
if gum confirm --default "Apply/verify system tweaks now?"; then
  "$SCRIPT_DIR/30-system-tweaks.sh"
else
  info "skipped; run later with: ./30-system-tweaks.sh"
fi

# =============================================================================
#  STEP 6: root theming symlinks
# =============================================================================
section "Step 6 / 7 - Root theming symlinks (sudo)"
gum style --faint "This makes root-run GUI apps (pkexec dialogs, sudo dolphin,
polkit prompts) match your GTK/Qt theme, icons, and cursor."
if gum confirm --default "Link theming into /root now? (asks for sudo)"; then
  sudo "$SCRIPT_DIR/40-root-symlink.sh"
else
  info "skipped; run later with: sudo ./40-root-symlink.sh"
fi

# =============================================================================
#  STEP 7: validate
# =============================================================================
section "Step 7 / 7 - Validate the deployed mango config"
if gum confirm --default "Run validate-config.sh against ~/.config/mango now?"; then
  "$SCRIPT_DIR/validate-config.sh" "$HOME/.config/mango" 2>&1 | gum pager 2>/dev/null \
    || "$SCRIPT_DIR/validate-config.sh" "$HOME/.config/mango"
else
  info "skipped; run later with: ./validate-config.sh ~/.config/mango"
fi

echo
banner "Setup pass complete"
gum style --faint "Next: log into a mango session (from your display manager, or
run 'mango' from a TTY) and verify the DankMaterialShell bar, launcher
(SUPER+space) and keybinds work before running ./60-session.sh to switch
the display manager to the DMS greeter."
