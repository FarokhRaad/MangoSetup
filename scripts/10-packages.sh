#!/usr/bin/env bash
# =============================================================================
#  10-packages.sh - install mango + DankMaterialShell, skip what is present
# =============================================================================
#  Reads packages/packages.txt and installs ONLY what is missing, routing each
#  package to pacman (official repos) or yay (AUR) automatically. Anything
#  already installed is left alone, so the script is safe to re-run.
#
#  It is purely additive: it never removes packages. If you are coming from
#  another desktop environment, uninstall it yourself once mango is verified
#  working.
#
#  Usage:
#    ./10-packages.sh [--dry-run] [--with-optional]
#
#  --with-optional installs lines in packages.txt marked "# optional"
#  (currently: xwayland-satellite, ttf-ms-fonts).
#
#  EXTRA_PKG_FILE=<path> (environment variable, not a flag): merge in an
#  additional newline-separated package list on top of packages.txt. Used
#  by scripts/setup.sh to pass along whatever apps were chosen in its
#  interactive category picker, without duplicating this script's
#  install/dedupe/pacman-vs-AUR-routing logic.
# =============================================================================
set -uo pipefail

DRY_RUN=false
WITH_OPTIONAL=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --with-optional) WITH_OPTIONAL=true ;;
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
  esac
done

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }

#  Yes/no prompt that behaves sanely without a terminal.
#  $1 = question, $2 = default ("y" or "n").
#  With --yes, always yes. Without a TTY, we cannot ask: rather than silently
#  taking the default (which previously meant "no" and looked like a mysterious
#  no-op), fail loudly and name the flag that makes it explicit.
ask() {
  local q="$1" def="${2:-n}" reply
  $ASSUME_YES && return 0
  if [[ ! -t 0 ]]; then
    err "need to ask: $q"
    err "but stdin is not a terminal. Re-run in a terminal, or pass --yes"
    err "to accept the default answers non-interactively."
    exit 1
  fi
  local hint="[y/N]"; [[ "$def" == y ]] && hint="[Y/n]"
  read -rp "$(printf '%s%s%s %s ' "$BOLD" "$q" "$NC" "$hint")" reply
  reply="${reply:-$def}"
  [[ "$reply" == y || "$reply" == Y ]]
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_FILE="$SCRIPT_DIR/../packages/packages.txt"
[[ -f "$PKG_FILE" ]] || { err "packages.txt not found at $PKG_FILE"; exit 1; }

#  Does a package exist in the AUR? Used only when no AUR helper is installed,
#  so the summary can still tell "exists in the AUR but will be skipped" apart
#  from "this name is wrong". Needs curl+python3; if either is unavailable it
#  returns false, which is the conservative answer (reported as UNKNOWN).
aur_exists() {
  command -v curl >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  curl -fsS --max-time 15 "https://aur.archlinux.org/rpc/v5/info?arg[]=$1" 2>/dev/null \
    | python3 -c 'import sys,json
try: sys.exit(0 if json.load(sys.stdin).get("resultcount",0) else 1)
except Exception: sys.exit(1)' 2>/dev/null
}

[[ $EUID -eq 0 ]] && {
  err "do not run as root; it uses sudo where needed."
  err "On a fresh Arch install you are usually root with no user yet. Create one first:"
  err "  useradd -m -G wheel yourname && passwd yourname"
  err "  pacman -S --needed sudo && EDITOR=nano visudo   # uncomment: %wheel ALL=(ALL:ALL) ALL"
  err "  su - yourname"
  exit 1
}

# -----------------------------------------------------------------------------
#  PREREQUISITES. A fresh Arch install ("base" only) has NONE of sudo, git,
#  python, or an AUR helper. Every one of them is load-bearing here, and the
#  failure modes are silent, so they are hard-checked up front instead of
#  producing a half-installed system.
# -----------------------------------------------------------------------------
step "Prerequisites"

missing_core=()
for c in sudo git; do
  command -v "$c" >/dev/null 2>&1 || missing_core+=("$c")
done
#  python is needed by validate-config.sh, and makepkg needs base-devel.
command -v python3 >/dev/null 2>&1 || missing_core+=("python")
if ((${#missing_core[@]})); then
  err "missing prerequisite command(s): ${missing_core[*]}"
  err "These are NOT part of Arch's 'base' metapackage. Install them first:"
  err "  sudo pacman -S --needed ${missing_core[*]} base-devel"
  err "(if sudo itself is missing, run that as root without 'sudo')"
  exit 1
fi
ok "sudo, git and python present"

#  CRITICAL: an unsynced pacman database makes `pacman -Si` fail for EVERY
#  package, which would classify the entire manifest as "not found" and then
#  report "nothing to install" while installing nothing at all. Refuse to run
#  in that state rather than silently no-op.
if ! pacman -Si bash &>/dev/null; then
  err "pacman's sync database is empty or unusable (pacman -Si bash failed)."
  err "Without it EVERY package would be misclassified as 'not found'."
  err "Sync it first:  sudo pacman -Sy"
  exit 1
fi
ok "pacman sync database is usable"

#  AUR helper. Six manifest packages come from the AUR (the compositor and the
#  shell among them), so without a helper the install would silently skip the
#  most important packages.
AUR_HELPER=""
for h in yay paru; do
  command -v "$h" >/dev/null 2>&1 && { AUR_HELPER="$h"; break; }
done
if [[ -n "$AUR_HELPER" ]]; then
  ok "AUR helper: $AUR_HELPER"
else
  warn "no AUR helper (yay/paru) found."
  warn "AUR packages include the COMPOSITOR (mangowm) and SHELL (dms-shell-git),"
  warn "so skipping them leaves an unusable system."
  if $DRY_RUN; then
    info "[DRY] would offer to bootstrap yay from the AUR"
  else
    if ask "Bootstrap yay now (needs git + base-devel)?" y; then
      if ! pacman -Qi base-devel &>/dev/null && ! pacman -Qg base-devel &>/dev/null; then
        info "installing base-devel (required to build AUR packages)"
        sudo pacman -S --needed --noconfirm base-devel || { err "failed to install base-devel"; exit 1; }
      fi
      tmpd=$(mktemp -d)
      #  Build in a temp dir; makepkg refuses to run as root, which is why
      #  this script requires a normal user.
      if git clone --depth 1 https://aur.archlinux.org/yay.git "$tmpd/yay" \
         && (cd "$tmpd/yay" && makepkg -si --noconfirm); then
        rm -rf "$tmpd"
        AUR_HELPER=yay
        ok "yay installed"
      else
        rm -rf "$tmpd"
        err "yay bootstrap failed. Install an AUR helper manually, then re-run."
        exit 1
      fi
    else
      warn "continuing WITHOUT an AUR helper; AUR packages will be listed and skipped."
    fi
  fi
fi

# -----------------------------------------------------------------------------
#  Parse packages.txt (+ optional EXTRA_PKG_FILE): strip comments, optionally
#  skip "# optional" lines, dedupe.
# -----------------------------------------------------------------------------
step "Reading package manifest"
mapfile -t BASE_PKGS < <(
  grep -Ev '^\s*(#|$)' "$PKG_FILE" \
    | awk -v opt="$WITH_OPTIONAL" '
        /# *optional/ && opt != "true" { next }
        { sub(/\s+#.*$/, ""); print $1 }' \
    | grep -v '^$'
)
info "packages.txt lists ${#BASE_PKGS[@]} package(s)"
$WITH_OPTIONAL && info "including optional packages" || info "excluding optional packages (use --with-optional to include)"

EXTRA_PKGS=()
if [[ -n "${EXTRA_PKG_FILE:-}" ]]; then
  if [[ -f "$EXTRA_PKG_FILE" ]]; then
    mapfile -t EXTRA_PKGS < <(grep -Ev '^\s*(#|$)' "$EXTRA_PKG_FILE" | grep -v '^$')
    info "EXTRA_PKG_FILE adds ${#EXTRA_PKGS[@]} package(s) from $EXTRA_PKG_FILE"
  else
    warn "EXTRA_PKG_FILE was set but not found: $EXTRA_PKG_FILE (ignoring)"
  fi
fi

#  Dedupe the combined list, preserving first-seen order.
mapfile -t ALL_PKGS < <(printf '%s\n' "${BASE_PKGS[@]}" "${EXTRA_PKGS[@]}" | awk '!seen[$0]++')
info "combined manifest: ${#ALL_PKGS[@]} unique package(s)"

# -----------------------------------------------------------------------------
#  Partition into: already installed / needs pacman / needs AUR
# -----------------------------------------------------------------------------
#  Is a package already satisfied on this system?
#
#  NOTE: reinstalls are ALREADY prevented by `--needed` on every install call
#  (pacman and the AUR helper alike). Verified: `pacman -S --needed --noconfirm
#  ttf-font` resolves the provides to noto-fonts, skips, and exits 0 with no
#  prompt. This function is about REPORTING accurately - the "will install N
#  packages" summary is computed before pacman runs - and about not invoking
#  the slow AUR helper for packages that are already present.
#
#  `pacman -Qi <name>` only matches the EXACT installed package name, so it
#  misses two cases and would overstate the work:
#    1. PROVIDES  - e.g. dgop-bin provides dgop; ttf-font is provided by many
#                   fonts. -Qi says "not installed", -T says satisfied.
#    2. GROUPS    - group members are installed but the group name is not a
#                   package, so -Qi fails.
#  `pacman -T` (deptest) is the provides-aware test: it prints nothing and
#  exits 0 when the dependency is satisfied.
pkg_satisfied() {
  local p="$1"
  pacman -Qi "$p" &>/dev/null && return 0
  pacman -Qg "$p" &>/dev/null && return 0
  pacman -T  "$p" &>/dev/null && return 0
  return 1
}

step "Checking installed state"
ALREADY=(); NEED_PACMAN=(); NEED_AUR=(); UNKNOWN=()
for pkg in "${ALL_PKGS[@]}"; do
  pkg="${pkg%%#*}"; pkg="${pkg// /}"
  [[ -z "$pkg" ]] && continue
  if pkg_satisfied "$pkg"; then
    ALREADY+=("$pkg")
  elif pacman -Si "$pkg" &>/dev/null || pacman -Sg "$pkg" &>/dev/null; then
    NEED_PACMAN+=("$pkg")
  elif [[ -n "$AUR_HELPER" ]] && "$AUR_HELPER" -Si "$pkg" &>/dev/null; then
    NEED_AUR+=("$pkg")
  elif [[ -z "$AUR_HELPER" ]] && aur_exists "$pkg"; then
    #  No helper installed, but the package DOES exist in the AUR. Count it as
    #  AUR so the summary is honest; the install step will report it as skipped
    #  rather than pretending it was handled.
    NEED_AUR+=("$pkg")
  else
    UNKNOWN+=("$pkg")
  fi
done

info "already installed : ${#ALREADY[@]}"
info "need pacman (repo): ${#NEED_PACMAN[@]}"
info "need AUR          : ${#NEED_AUR[@]}"
if ((${#UNKNOWN[@]})); then
  err "NOT FOUND in the repos or the AUR (likely renamed upstream):"
  printf '    %s\n' "${UNKNOWN[@]}"
  err "A wrong package name here means that component never gets installed."
  err "Verify each with:  pacman -Si <pkg>   /   curl -s 'https://aur.archlinux.org/rpc/v5/info?arg\\[\\]=<pkg>'"
  #  This is a manifest defect, not a transient condition: fail loudly instead
  #  of installing 90% of a desktop and reporting success.
  if ! $DRY_RUN; then
    ask "Continue anyway, skipping those packages?" n || { err "aborted"; exit 1; }
  fi
fi

if ((${#NEED_PACMAN[@]})); then
  printf '\n%sFrom official repos:%s\n' "$BOLD" "$NC"
  printf '  %s\n' "${NEED_PACMAN[@]}"
fi
if ((${#NEED_AUR[@]})); then
  printf '\n%sFrom the AUR (via %s):%s\n' "$BOLD" "${AUR_HELPER:-NO HELPER - WILL BE SKIPPED}" "$NC"
  printf '  %s\n' "${NEED_AUR[@]}"
fi

if ((${#NEED_PACMAN[@]} == 0 && ${#NEED_AUR[@]} == 0)); then
  #  Only a legitimate "nothing to do" if the manifest actually resolved.
  #  Reaching here with everything UNKNOWN means classification failed, which
  #  used to be reported as success while installing nothing.
  if ((${#UNKNOWN[@]} == ${#ALL_PKGS[@]})); then
    err "NOTHING could be classified: all ${#UNKNOWN[@]} package(s) were unresolvable."
    err "This is a broken environment, not a completed install. Check network/mirrors and:"
    err "  sudo pacman -Sy"
    exit 1
  fi
  ok "nothing to install; everything in the manifest is already present"
  exit 0
fi

if $DRY_RUN; then
  info "[DRY RUN] would install ${#NEED_PACMAN[@]} repo + ${#NEED_AUR[@]} AUR package(s)"
  exit 0
fi

ask "Proceed with installation?" n || { info "aborted"; exit 0; }

# -----------------------------------------------------------------------------
#  Install
# -----------------------------------------------------------------------------
RC=0

step "Installing repo packages"
if ((${#NEED_PACMAN[@]})); then
  #  Install as one transaction; if it fails, retry per-package so ONE bad
  #  package cannot block the other 70 (a hard failure mode on a fresh install
  #  where a single rename aborts everything).
  if sudo pacman -S --needed --noconfirm "${NEED_PACMAN[@]}"; then
    ok "repo packages installed"
  else
    warn "batch install failed; retrying package by package to isolate the cause"
    PAC_FAILED=()
    for pkg in "${NEED_PACMAN[@]}"; do
      sudo pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1 || PAC_FAILED+=("$pkg")
    done
    if ((${#PAC_FAILED[@]})); then
      err "repo packages that FAILED to install: ${PAC_FAILED[*]}"
      err "retry individually to see why:  sudo pacman -S <pkg>"
      RC=1
    else
      ok "all repo packages installed on the per-package retry"
    fi
  fi
else
  info "none needed"
fi

step "Installing AUR packages"
if ((${#NEED_AUR[@]})); then
  if [[ -z "$AUR_HELPER" ]]; then
    err "no AUR helper, so these were NOT installed: ${NEED_AUR[*]}"
    err "That includes the compositor and/or shell, so the desktop will not start."
    err "Install a helper and re-run this script:"
    err "  sudo pacman -S --needed git base-devel"
    err "  git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
    RC=1
  else
    FAILED=()
    for pkg in "${NEED_AUR[@]}"; do
      info "building $pkg..."
      if ! "$AUR_HELPER" -S --needed --noconfirm "$pkg"; then
        err "failed: $pkg"
        FAILED+=("$pkg")
      fi
    done
    if ((${#FAILED[@]})); then
      err "AUR packages that FAILED to build: ${FAILED[*]}"
      err "retry individually with: $AUR_HELPER -S <pkg>"
      RC=1
    else
      ok "all AUR packages installed"
    fi
  fi
else
  info "none needed"
fi

# -----------------------------------------------------------------------------
#  Post-install verification. The whole point of this script is that mango and
#  DMS end up installed; verify that explicitly rather than trusting the
#  package manager's exit codes.
# -----------------------------------------------------------------------------
step "Verifying the critical components"
CRITICAL_MISSING=()
for pair in "mango:the compositor" "dms:the shell CLI"; do
  bin="${pair%%:*}"; what="${pair#*:}"
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin present ($what)"
  else
    err "$bin NOT installed ($what)"
    CRITICAL_MISSING+=("$bin")
  fi
done
if ((${#CRITICAL_MISSING[@]})); then
  err "The desktop CANNOT start without: ${CRITICAL_MISSING[*]}"
  RC=1
fi

step "Summary"
if (( RC == 0 )); then
  ok "package installation pass complete; all critical components present"
else
  err "package installation pass completed WITH ERRORS (see above)"
  err "Do NOT log into mango yet: fix the failures first, then re-run this script."
fi
info "Next: deploy configs (20-symlink.sh), optionally pick system tweaks"
info "(30-system-tweaks.sh), then log into mango for the first time."
exit $RC
