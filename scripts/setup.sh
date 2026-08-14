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
BLUE=$'\033[0;34m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }

mkdir -p "$STATE_DIR"

# -----------------------------------------------------------------------------
#  Sub-script runner.
#
#  Always invokes via `bash <script>` rather than executing the file directly:
#  a clone onto a noexec mount (or one where the exec bit was lost) would
#  otherwise fail with "Permission denied" for no obvious reason.
#
#  Also RECORDS FAILURES. Previously every step's exit status was discarded, so
#  the wizard printed "Setup pass complete" even when package installation had
#  failed and nothing was actually installed.
# -----------------------------------------------------------------------------
FAILED_STEPS=()
#  Set when a step lands something that only takes effect after a reboot
#  (kernel modules, initramfs). Surfaced in the final summary.
NEEDS_REBOOT=false
step_run() {
  local label="$1"; shift
  local script="$1"; shift
  if [[ ! -f "$script" ]]; then
    err "$label: script not found: $script"
    FAILED_STEPS+=("$label (missing script)")
    return 1
  fi
  local rc=0
  bash "$script" "$@" || rc=$?
  if (( rc != 0 )); then
    err "$label: FAILED (exit $rc)"
    FAILED_STEPS+=("$label")
  fi
  return "$rc"
}

#  Verify the whole script set is present before asking any questions, so a bad
#  or partial clone is caught up front instead of three steps in.
missing_scripts=()
for s in 00-preflight.sh 10-packages.sh 20-symlink.sh 30-system-tweaks.sh \
         40-root-symlink.sh validate-config.sh nvidia-setup.sh; do
  [[ -f "$SCRIPT_DIR/$s" ]] || missing_scripts+=("$s")
done
if ((${#missing_scripts[@]})); then
  err "this repo checkout is incomplete; missing scripts: ${missing_scripts[*]}"
  err "re-clone the repository and try again"
  exit 1
fi

# -----------------------------------------------------------------------------
#  Environment sanity, BEFORE anything interactive.
#
#  A fresh Arch install ("base" only) provides none of sudo, git, python or an
#  AUR helper, and may have an unsynced pacman database. Catch all of that here
#  with actionable instructions rather than failing three steps in.
# -----------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  err "do not run this wizard as root."
  err "Package builds (makepkg) refuse to run as root, and configs would be"
  err "deployed into /root instead of your user's home."
  err "On a fresh install, create a user first:"
  err "  useradd -m -G wheel yourname && passwd yourname"
  err "  pacman -S --needed sudo && EDITOR=nano visudo   # uncomment %wheel line"
  err "  su - yourname   then re-run this script"
  exit 1
fi

if ! command -v pacman &>/dev/null; then
  err "pacman not found: this script only supports Arch Linux and derivatives."
  exit 1
fi

#  gum (and `read -rp`) need a real terminal. Piped/redirected stdin makes gum
#  either error out or block forever, so refuse up front with a pointer to the
#  manual path instead of hanging.
if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
  err "this wizard is interactive and needs a terminal (stdin/stdout is not a TTY)."
  err "Run it directly in a terminal, or use the individual scripts instead:"
  err "  bash ./10-packages.sh && bash ./20-symlink.sh"
  exit 1
fi

missing_prereq=()
command -v sudo    &>/dev/null || missing_prereq+=(sudo)
command -v git     &>/dev/null || missing_prereq+=(git)
command -v python3 &>/dev/null || missing_prereq+=(python)
if ((${#missing_prereq[@]})); then
  err "missing prerequisites: ${missing_prereq[*]}"
  err "These are NOT included in Arch's 'base' metapackage. As root, run:"
  err "  pacman -Syu --needed ${missing_prereq[*]} base-devel"
  err "then re-run this script as your normal user."
  exit 1
fi

#  An empty sync DB makes every `pacman -Si` fail, which would misclassify the
#  entire manifest. 10-packages.sh also guards this, but catching it here avoids
#  walking the user through the whole app picker first.
if ! pacman -Si bash &>/dev/null; then
  err "pacman's sync database is empty or unusable."
  err "Sync it first:  sudo pacman -Sy"
  exit 1
fi

# -----------------------------------------------------------------------------
#  gum bootstrap: the wizard needs gum before 10-packages.sh has run.
# -----------------------------------------------------------------------------
if ! command -v gum &>/dev/null; then
  printf '%s\n' "gum (the TUI toolkit this wizard uses) is not installed yet."
  read -rp "Install it now from the official repos? [Y/n] " reply
  if [[ -z "$reply" || "$reply" == "y" || "$reply" == "Y" ]]; then
    sudo pacman -S --needed --noconfirm gum || { err "failed to install gum"; exit 1; }
    command -v gum &>/dev/null || { err "gum still not on PATH after install"; exit 1; }
  else
    err "gum is required for this wizard."
    err "Run the steps manually instead (see README.md), starting with:"
    err "  bash ./10-packages.sh"
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
  #  Invoked as `bash <script>` (not directly) so a noexec mount or a lost exec
  #  bit cannot break it. Quoting via an argv array avoids re-quoting problems
  #  when SCRIPT_DIR or STATE_DIR contain spaces.
  gum spin --spinner dot --title "Surveying system..." -- \
    bash -c 'bash "$1" > "$2" 2>&1' _ "$SCRIPT_DIR/00-preflight.sh" "$STATE_DIR/preflight.log" \
    || warn "preflight reported issues, see $STATE_DIR/preflight.log"
  if [[ -s "$STATE_DIR/preflight.log" ]]; then
    gum pager < "$STATE_DIR/preflight.log" 2>/dev/null || cat "$STATE_DIR/preflight.log"
  else
    warn "preflight produced no output"
  fi
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
SKIPPED_INSTALLED=()          # apps left ticked that are already satisfied

for role in "${CATEGORIES[@]}"; do
  mapfile -t ROWS < <(awk -F'|' -v r="$role" '$1==r {print}' "$CATALOG")
  ((${#ROWS[@]})) || continue

  #  Build display labels "Label (package)" -> keep a lookup back to the
  #  full row (package|binary|source) via label-delimiter.
  declare -A LABEL_TO_ROW=()
  DISPLAY=()
  PRESELECT=()
  for row in "${ROWS[@]}"; do
    #  6th field = optional space-separated companion packages, installed only
    #  when this row is selected. Must be read explicitly: `read` assigns the
    #  remainder of the line to the last variable, so omitting `companions`
    #  would silently append "|zsh-autosuggestions ..." to `label`.
    IFS='|' read -r _ pkg bin _ label companions <<<"$row"
    #  Provides-aware: `pacman -Qi` only matches an exact package name, so it
    #  misses packages satisfied via provides (dgop-bin provides dgop) and
    #  group names. `pacman -T` is the provides-aware test.
    if command -v "$bin" &>/dev/null \
       || pacman -Qi "$pkg" &>/dev/null \
       || pacman -Qg "$pkg" &>/dev/null \
       || pacman -T  "$pkg" &>/dev/null; then
      #  Mark it, so you can see at a glance what is already there and would
      #  NOT be reinstalled if left ticked.
      disp="$label  [$pkg] (installed)"
      DISPLAY+=("$disp")
      LABEL_TO_ROW["$disp"]="$row"
      PRESELECT+=("$disp")
    else
      disp="$label  [$pkg]"
      DISPLAY+=("$disp")
      LABEL_TO_ROW["$disp"]="$row"
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
    #  gum choose's stdout can carry a trailing blank line (terminal/build
    #  dependent), and `mapfile` turns that into an empty "" element in
    #  CHOSEN. Looking that up in an associative array under `set -u` is a
    #  hard error two ways in a row: `bad array subscript` for the empty
    #  key, then `unbound variable` for the resulting non-lookup. Skip it
    #  rather than let the whole picker crash over whitespace gum emitted.
    [[ -n "$disp" ]] || continue
    if [[ -z "${LABEL_TO_ROW[$disp]+set}" ]]; then
      warn "picker returned an unrecognised entry, skipping: [$disp]"
      continue
    fi
    row="${LABEL_TO_ROW[$disp]}"
    #  6th field = optional space-separated companion packages, installed only
    #  when this row is selected. Must be read explicitly: `read` assigns the
    #  remainder of the line to the last variable, so omitting `companions`
    #  would silently append "|zsh-autosuggestions ..." to `label`.
    IFS='|' read -r _ pkg bin _ label companions <<<"$row"
    #  Only queue packages that are NOT already satisfied.
    #
    #  This is NOT what prevents reinstalls: every install call already passes
    #  `--needed`, and that was verified to handle provides correctly and
    #  without prompting (`pacman -S --needed --noconfirm ttf-font` skips via
    #  noto-fonts and exits 0). The filter exists so the SUMMARY is honest -
    #  counts and lists are computed before pacman runs, so without it the
    #  wizard would claim to install things it then skips - and so an
    #  already-satisfied AUR package never invokes the (much slower) helper.
    if command -v "$bin" &>/dev/null \
       || pacman -Qi "$pkg" &>/dev/null \
       || pacman -Qg "$pkg" &>/dev/null \
       || pacman -T  "$pkg" &>/dev/null; then
      SKIPPED_INSTALLED+=("$label")
    else
      echo "$pkg" >> "$SELECTIONS_FILE"
    fi
    #  Companion packages ride along with the row that declares them, and are
    #  queued independently of the main package: zsh can already be installed
    #  while its plugins are not.
    for comp in $companions; do
      pacman -Qi "$comp" &>/dev/null || pacman -T "$comp" &>/dev/null \
        || echo "$comp" >> "$SELECTIONS_FILE"
    done
    #  Still a valid default candidate either way: being already installed does
    #  not disqualify an app from being the active default.
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

queued=$(wc -l < "$SELECTIONS_FILE")
if ((${#SKIPPED_INSTALLED[@]})); then
  ok "already installed, not reinstalled: ${#SKIPPED_INSTALLED[@]} app(s)"
  printf '      %s\n' "${SKIPPED_INSTALLED[@]}"
fi
info "queued for installation: $queued package(s) -> $SELECTIONS_FILE"

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
#  STEP 2b: NVIDIA driver completion
#
#  The driver is normally installed by archinstall, because it must be present
#  before the first boot into a graphical session. This catches the case where
#  that did not happen and offers to complete it, rather than letting you
#  discover it as a black screen after ./60-session.sh.
#
#  Runs BEFORE the main package install so a reboot-requiring fix surfaces
#  early rather than at the very end of the wizard.
# =============================================================================
if [[ -f "$SCRIPT_DIR/nvidia-setup.sh" ]]; then
  if bash "$SCRIPT_DIR/nvidia-setup.sh" check >"$STATE_DIR/nvidia.log" 2>&1; then
    :   # complete, or no NVIDIA GPU: stay quiet
  else
    section "NVIDIA driver"
    gum pager <"$STATE_DIR/nvidia.log" 2>/dev/null || cat "$STATE_DIR/nvidia.log"
    warn "the NVIDIA driver stack is incomplete (details above)"
    if $DRY_RUN; then
      info "[DRY] would offer to run: nvidia-setup.sh install"
    elif gum confirm --default "Install the missing NVIDIA pieces now?"; then
      step_run "nvidia driver" "$SCRIPT_DIR/nvidia-setup.sh" install || true
      NEEDS_REBOOT=true
    else
      warn "skipped. The desktop may not start until you run:"
      warn "  ./nvidia-setup.sh install"
    fi
  fi
fi

# =============================================================================
#  STEP 3: package installation
# =============================================================================
section "Step 3 / 7 - Install packages"
if gum confirm --default "Install mango + DankMaterialShell + your chosen apps now?"; then
  extra_flag=()
  $DRY_RUN && extra_flag+=(--dry-run)
  EXTRA_PKG_FILE="$SELECTIONS_FILE" step_run "packages" "$SCRIPT_DIR/10-packages.sh" "${extra_flag[@]}"

  # ---------------------------------------------------------------------------
  #  Login shell. Deliberately AFTER the install: chsh refuses a shell that is
  #  not yet on disk and listed in /etc/shells, so this cannot run earlier.
  #
  #  Exporting SHELL from apps.conf does NOT change the login shell; that lives
  #  in /etc/passwd. Offered rather than forced, because chsh needs the user's
  #  password and changing someone's login shell without asking is rude.
  # ---------------------------------------------------------------------------
  want_shell="${CATEGORY_DEFAULT[SHELL]:-}"
  if [[ -n "$want_shell" ]]; then
    shell_path="$(command -v "$want_shell" 2>/dev/null || true)"
    current_shell="$(getent passwd "$USER" | cut -d: -f7)"
    if [[ -z "$shell_path" ]]; then
      warn "$want_shell is not on PATH yet; skipping the login-shell change"
      warn "run it yourself once installed:  chsh -s \$(command -v $want_shell)"
    elif [[ "$current_shell" == "$shell_path" ]]; then
      ok "login shell is already $shell_path"
    elif ! grep -qxF "$shell_path" /etc/shells; then
      #  chsh rejects anything absent from /etc/shells for a non-root user.
      warn "$shell_path is not listed in /etc/shells; not changing the login shell"
      warn "add it as root, then:  chsh -s $shell_path"
    elif $DRY_RUN; then
      info "[DRY] would offer: chsh -s $shell_path"
    elif gum confirm --default "Make $want_shell your login shell? (asks for your password)"; then
      if chsh -s "$shell_path"; then
        ok "login shell set to $shell_path (takes effect at your NEXT login)"
      else
        warn "chsh failed; your login shell is unchanged ($current_shell)"
        warn "retry manually:  chsh -s $shell_path"
      fi
    else
      info "login shell left as $current_shell"
    fi
  fi
else
  info "skipped; run later with: EXTRA_PKG_FILE=$SELECTIONS_FILE ./10-packages.sh"
fi

# =============================================================================
#  STEP 4: symlink configs
# =============================================================================
section "Step 4 / 7 - Deploy configs (symlink into \$HOME)"
if gum confirm --default "Symlink configs/ into your home directory now?"; then
  symlink_flag=()
  $DRY_RUN && symlink_flag+=(--dry-run)
  step_run "config deploy" "$SCRIPT_DIR/20-symlink.sh" "${symlink_flag[@]}"
else
  info "skipped; run later with: ./20-symlink.sh"
fi

# =============================================================================
#  STEP 5: system tweaks
# =============================================================================
section "Step 5 / 7 - System tweaks (optional, pick what you want)"
gum style --faint "Each tweak is opt-in and independent: a multi-select picker
shows what's applicable to THIS hardware, what's already applied, and what
doesn't apply. Nothing is applied unless you tick it. Reversible with
./30-system-tweaks.sh --revert"
if gum confirm --default "Open the system tweaks picker now?"; then
  tweak_flag=()
  $DRY_RUN && tweak_flag+=(--dry-run)
  step_run "system tweaks" "$SCRIPT_DIR/30-system-tweaks.sh" "${tweak_flag[@]}"
else
  info "skipped; run later with: ./30-system-tweaks.sh"
fi

# =============================================================================
#  STEP 6: root theming symlinks
# =============================================================================
section "Step 6 / 7 - Root theming symlinks (sudo)"
gum style --faint "This makes root-run GUI apps (pkexec dialogs, polkit prompts,
a file manager launched with sudo) match your GTK/Qt theme, icons, and cursor."
if gum confirm --default "Link theming into /root now? (asks for sudo)"; then
  if $DRY_RUN; then
    step_run "root theming" "$SCRIPT_DIR/40-root-symlink.sh" --dry-run || true
  elif [[ $EUID -eq 0 ]]; then
    step_run "root theming" "$SCRIPT_DIR/40-root-symlink.sh" || true
  elif command -v sudo >/dev/null 2>&1; then
    #  Run through sudo, still via bash so a noexec/mode issue cannot bite.
    #  SUDO_USER is what the script uses to find whose configs to link, and
    #  sudo sets it automatically.
    rc=0
    sudo bash "$SCRIPT_DIR/40-root-symlink.sh" || rc=$?
    if (( rc != 0 )); then
      err "root theming: FAILED (exit $rc)"
      FAILED_STEPS+=("root theming")
    fi
  else
    warn "sudo is not installed; skipping. Run as root later:"
    warn "  bash ./40-root-symlink.sh"
  fi
else
  info "skipped; run later with: sudo ./40-root-symlink.sh"
fi

# =============================================================================
#  STEP 7: validate
# =============================================================================
section "Step 7 / 7 - Validate the deployed mango config"
if [[ ! -d "$HOME/.config/mango" ]]; then
  warn "\$HOME/.config/mango does not exist yet (step 4 skipped?); nothing to validate"
elif ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  warn "validate-config.sh needs python3 and git; skipping the check"
  warn "install them and run: ./validate-config.sh ~/.config/mango"
elif gum confirm --default "Run validate-config.sh against ~/.config/mango now?"; then
  #  Capture once, then page. Piping straight into gum pager discarded the exit
  #  status and re-ran the whole validation on pager failure.
  vlog="$STATE_DIR/validate.log"
  vrc=0
  bash "$SCRIPT_DIR/validate-config.sh" "$HOME/.config/mango" >"$vlog" 2>&1 || vrc=$?
  gum pager <"$vlog" 2>/dev/null || cat "$vlog"
  if (( vrc != 0 )); then
    err "config validation reported problems (exit $vrc); see $vlog"
    FAILED_STEPS+=("config validation")
  fi
else
  info "skipped; run later with: ./validate-config.sh ~/.config/mango"
fi

echo
if ((${#FAILED_STEPS[@]})); then
  banner "Setup finished WITH ERRORS"
  err "these steps failed: ${FAILED_STEPS[*]}"
  gum style --faint "Fix the errors above and re-run ./setup.sh (every step is
idempotent, so re-running is safe). Do NOT switch your display manager with
./60-session.sh until a mango session is confirmed working."
  exit 1
fi

banner "Setup pass complete"
if $NEEDS_REBOOT; then
  warn "REBOOT REQUIRED before starting a graphical session:"
  warn "kernel modules and/or the initramfs were changed this run."
fi
gum style --faint "Next: log into a mango session (from your display manager, or
run 'mango' from a TTY) and verify the DankMaterialShell bar, launcher
(SUPER+space) and keybinds work before running ./60-session.sh to switch
the display manager to the DMS greeter."
exit 0
