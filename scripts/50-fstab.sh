#!/usr/bin/env bash
# =============================================================================
#  50-fstab.sh - add data-disk and network-share mounts to /etc/fstab
# =============================================================================
#  Nothing here is hardcoded to one machine. Local disks are DISCOVERED at run
#  time and picked interactively; network shares are entered by you and stored
#  in a config file so a re-run reproduces them without retyping.
#
#  Usage:
#    ./50-fstab.sh                 interactive: pick a disk, add shares
#    ./50-fstab.sh --status        show what is configured vs mounted
#    ./50-fstab.sh --dry-run       print the exact fstab lines, change nothing
#    ./50-fstab.sh --disk-only     skip the network-share section
#    ./50-fstab.sh --shares-only   skip the local-disk section
#    ./50-fstab.sh --revert        remove ONLY the lines this script added
#
#  SAFETY
#   - /etc/fstab is backed up (timestamped) before any change.
#   - Every generated line is validated with `findmnt --verify` BEFORE it is
#     kept; a bad fstab makes a machine unbootable, so this is not optional.
#   - Lines are fenced between marker comments so --revert removes exactly what
#     was added and nothing else. Your hand-written entries are never touched.
#   - An entry whose mount point is already in fstab is skipped, not duplicated.
#
#  CIFS PASSWORDS ARE NEVER WRITTEN INTO fstab. /etc/fstab is world-readable
#  (0644) by design, so an inline `password=` is visible to every local user.
#  Credentials go to /etc/samba/credentials.d/<host> at 0600 root:root, and
#  fstab references them with `credentials=`. This is cifs's own supported
#  mechanism, not a workaround.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FSTAB=/etc/fstab
CRED_DIR=/etc/samba/credentials.d
SHARES_CONF="$REPO_DIR/system/fstab/shares.conf"
BEGIN_MARK="# >>> MangoSetup managed entries >>>"
END_MARK="# <<< MangoSetup managed entries <<<"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$NC"; }

MODE=pick; DRY=false; DO_DISK=true; DO_SHARES=true
for arg in "$@"; do
  case "$arg" in
    --status)      MODE=status ;;
    --revert)      MODE=revert ;;
    --dry-run)     DRY=true ;;
    --disk-only)   DO_SHARES=false ;;
    --shares-only) DO_DISK=false ;;
    -h|--help)     sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) err "unknown option '$arg' (try --help)"; exit 2 ;;
  esac
done

[[ -f "$FSTAB" ]] || { err "$FSTAB not found"; exit 1; }
if [[ $EUID -eq 0 ]]; then sudo() { "$@"; }; fi

run() { if $DRY; then printf '%s[DRY]%s %s\n' "$YELLOW" "$NC" "$*"; else "$@"; fi; }

need_root() {
  $DRY && return 0
  [[ $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || { err "need root but sudo is not installed"; exit 1; }
  #  Prime the sudo timestamp so a password prompt cannot appear halfway
  #  through writing fstab. `sudo -v` is best-effort: some sudo replacements
  #  and wrappers do not implement -v, and failing it is not a reason to
  #  abort when the privileged commands themselves may still succeed.
  if ! sudo -n true 2>/dev/null; then
    info "root access needed to edit $FSTAB"
    if ! sudo -v 2>/dev/null; then
      warn "could not pre-authorise sudo; you may be prompted mid-operation"
    fi
  fi
  return 0
}

#  Everything this script has added, as a block. Used by --status and --revert.
managed_block() { sed -n "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/p" "$FSTAB"; }
has_managed()   { grep -qxF "$BEGIN_MARK" "$FSTAB"; }

#  Is this mount point already spoken for anywhere in fstab (ours or yours)?
mp_in_fstab() {
  awk -v mp="$1" '!/^[[:space:]]*#/ && NF>=2 && $2==mp {found=1} END{exit !found}' "$FSTAB"
}

# =============================================================================
#  status
# =============================================================================
if [[ "$MODE" == status ]]; then
  step "Managed fstab entries"
  if has_managed; then
    managed_block | grep -vE "^#|^\s*$" | sed 's/^/  /' || true
  else
    info "none (this script has not added anything yet)"
  fi

  step "Mount state"
  printf '  %-16s %-10s %s\n' "MOUNT POINT" "TYPE" "STATE"
  while read -r _src mp fstype _rest; do
    [[ -z "${mp:-}" ]] && continue
    if findmnt -rno TARGET "$mp" >/dev/null 2>&1; then st="${GREEN}mounted${NC}"
    elif [[ -d "$mp" ]];                          then st="${YELLOW}not mounted${NC}"
    else                                                st="${RED}no mount point${NC}"; fi
    printf '  %-16s %-10s %b\n' "$mp" "$fstype" "$st"
  done < <(awk '!/^[[:space:]]*#/ && NF>=3 {print $1, $2, $3}' "$FSTAB")

  step "Credentials"
  if [[ -d "$CRED_DIR" ]]; then
    while IFS= read -r cf; do
      m=$(sudo stat -c '%a %U:%G' "$cf" 2>/dev/null || echo "?")
      if [[ "${m%% *}" == 600 ]]; then ok "$cf ($m)"; else err "$cf has mode $m, expected 600 root:root"; fi
    done < <(sudo find "$CRED_DIR" -maxdepth 1 -type f 2>/dev/null)
  else
    info "no credentials directory yet"
  fi

  #  The problem this script exists to avoid.
  if grep -qE '^[^#]*password=' "$FSTAB"; then
    echo
    err "$FSTAB contains inline password= entries and is world-readable"
    err "($(stat -c '%a' "$FSTAB")). Any local user can read them."
    err "Re-add those shares with this script to move them into $CRED_DIR."
  fi
  exit 0
fi

# =============================================================================
#  revert
# =============================================================================
if [[ "$MODE" == revert ]]; then
  step "Revert"
  has_managed || { info "no managed entries to remove"; exit 0; }
  need_root
  managed_block | grep -vE "^#|^\s*$" | sed 's/^/  removing: /'
  if $DRY; then info "[DRY] would remove the managed block and its backups stay"; exit 0; fi
  backup="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
  sudo cp "$FSTAB" "$backup"; info "backed up -> $backup"
  sudo sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FSTAB"
  #  Same policy as the write path: only a PARSE error means we broke the file.
  rev_out=$(findmnt --verify --tab-file "$FSTAB" 2>&1)
  rev_parse=$(grep -oE '^[0-9]+ parse errors' <<<"$rev_out" | grep -oE '^[0-9]+' || echo 0)
  if (( rev_parse == 0 )); then
    ok "managed entries removed; fstab still parses cleanly"
  else
    err "fstab has parse errors after removal; restoring the backup"
    sed 's/^/    /' <<<"$rev_out"
    sudo cp "$backup" "$FSTAB"
    exit 1
  fi
  info "credentials in $CRED_DIR were left in place (delete them yourself if"
  info "you no longer need them)"
  sudo systemctl daemon-reload 2>/dev/null || true
  exit 0
fi

# =============================================================================
#  Collect entries to add
# =============================================================================
NEW_LINES=()
UID_VAL=$(id -u); GID_VAL=$(id -g)

# ---------------------------------------------------------------------------
#  Local data disk: DISCOVERED, never hardcoded.
#
#  Candidates are partitions that are not the running system's and carry a
#  filesystem you would plausibly want mounted at boot. The UUID is read at run
#  time; the LABEL is recorded as a comment so the entry is self-documenting.
# ---------------------------------------------------------------------------
if $DO_DISK; then
  step "Local data disk"
  mapfile -t CANDS < <(
    lsblk -rno NAME,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINT -e7 2>/dev/null |
    awk '$2=="ntfs" || $2=="exfat" || $2=="ext4" || $2=="xfs" || $2=="btrfs"'
  )
  #  Exclude anything already carrying a root/boot/home mount, and anything
  #  without a UUID (unformatted or unreadable).
  MENU=(); MENU_DATA=()
  for c in "${CANDS[@]}"; do
    read -r name fstype label uuid size mp <<<"$c"
    [[ -z "${uuid:-}" ]] && continue
    case "${mp:-}" in /|/boot|/home|/var/*|"[SWAP]") continue ;; esac
    #  Skip the partition hosting the running root filesystem.
    root_uuid=$(findmnt -no UUID / 2>/dev/null)
    [[ -n "$root_uuid" && "$uuid" == "$root_uuid" ]] && continue
    MENU+=("$(printf '%-12s %-7s %-8s %-10s %s' "/dev/$name" "$size" "$fstype" "${label:-<no label>}" "${mp:-unmounted}")")
    MENU_DATA+=("$uuid|$fstype|${label:-}|$name")
  done

  if ((${#MENU[@]} == 0)); then
    info "no candidate data partitions found; skipping"
  else
    printf '  %s\n' "found ${#MENU[@]} candidate partition(s):"
    for i in "${!MENU[@]}"; do printf '   %2d) %s\n' "$((i+1))" "${MENU[$i]}"; done
    printf '   %2d) skip\n' "$(( ${#MENU[@]} + 1 ))"

    sel=""
    if [[ -t 0 ]]; then
      read -rp "  choose a partition to mount at boot [1-$(( ${#MENU[@]} + 1 ))]: " sel
    else
      info "non-interactive: skipping disk selection (run in a terminal to choose)"
      sel=$(( ${#MENU[@]} + 1 ))
    fi
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#MENU[@]} )); then
      IFS='|' read -r d_uuid d_fstype d_label d_name <<<"${MENU_DATA[$((sel-1))]}"
      def_mp="/mnt/${d_label:-data}"
      mp=""
      [[ -t 0 ]] && read -rp "  mount point [$def_mp]: " mp
      mp="${mp:-$def_mp}"

      if mp_in_fstab "$mp"; then
        warn "$mp is already in fstab; skipping"
      else
        case "$d_fstype" in
          ntfs)
            #  'ntfs' resolves to ntfs-3g (FUSE) via /usr/bin/mount.ntfs.
            #  uid/gid are required for a FUSE mount to be writable by you;
            #  they are meaningless on a native Linux filesystem.
            #  NOTE: 'users' implies noexec,nosuid,nodev - you cannot execute
            #  binaries from this mount. Use 'user' instead of 'users' if you
            #  need exec, and add 'exec' explicitly.
            d_opts="nofail,users,uid=${UID_VAL},gid=${GID_VAL}" ;;
          exfat)
            d_opts="nofail,users,uid=${UID_VAL},gid=${GID_VAL}" ;;
          *)
            #  Native Linux filesystems carry their own ownership; forcing
            #  uid/gid is wrong and often rejected.
            d_opts="nofail,defaults" ;;
        esac
        NEW_LINES+=("# ${d_label:-data} disk (/dev/${d_name}, LABEL=${d_label:-none}) - UUID discovered by 50-fstab.sh")
        NEW_LINES+=("UUID=${d_uuid}  ${mp}  ${d_fstype}  ${d_opts}  0 0")
        ok "queued: $mp  <-  UUID=$d_uuid  (LABEL=${d_label:-none})"
      fi
    else
      info "no disk selected"
    fi
  fi
fi

# ---------------------------------------------------------------------------
#  Network shares
#
#  Read from configs/fstab-shares.conf when present so a reinstall reproduces
#  them without retyping. Format (one per line):
#      //server/share  /mount/point
#  Credentials are asked for once per server and stored at 0600.
# ---------------------------------------------------------------------------
if $DO_SHARES; then
  step "Network shares (CIFS/SMB)"
  SHARES=()
  if [[ -f "$SHARES_CONF" ]]; then
    while read -r src mp _; do
      [[ -z "${src:-}" || "$src" == \#* ]] && continue
      SHARES+=("$src|$mp")
    done < "$SHARES_CONF"
    info "loaded ${#SHARES[@]} share(s) from ${SHARES_CONF#"$REPO_DIR"/}"
  fi

  if ((${#SHARES[@]} == 0)) && [[ -t 0 ]]; then
    info "no share list found. Enter shares one per line, blank line to finish."
    info "example:  //192.168.1.10/Movies /mnt/Movies"
    while true; do
      read -rp "  share: " line || break
      [[ -z "${line// /}" ]] && break
      read -r s_src s_mp _ <<<"$line"
      if [[ -z "${s_mp:-}" || "$s_src" != //* ]]; then
        warn "expected: //server/share /mount/point"
        continue
      fi
      SHARES+=("$s_src|$s_mp")
    done
  fi

  if ((${#SHARES[@]} == 0)); then
    info "no shares configured; skipping"
  else
    declare -A SERVER_CRED=()
    for entry in "${SHARES[@]}"; do
      IFS='|' read -r s_src s_mp <<<"$entry"
      server="${s_src#//}"; server="${server%%/*}"

      if mp_in_fstab "$s_mp"; then
        warn "$s_mp already in fstab; skipping"
        continue
      fi

      #  One credentials file per server, asked once.
      cred="$CRED_DIR/$server"
      if [[ -z "${SERVER_CRED[$server]:-}" ]]; then
        if sudo test -f "$cred" 2>/dev/null; then
          ok "reusing existing credentials: $cred"
        elif $DRY; then
          info "[DRY] would prompt for credentials for $server -> $cred"
        elif [[ -t 0 ]]; then
          printf '  credentials for %s\n' "$server"
          read -rp "    username: " c_user
          read -rsp "    password: " c_pass; echo
          #  Written via install(1) with the mode set up front, so the secret
          #  is never briefly world-readable between creation and chmod.
          need_root
          sudo install -d -m 700 -o root -g root "$CRED_DIR"
          printf 'username=%s\npassword=%s\n' "$c_user" "$c_pass" |
            sudo install -m 600 -o root -g root /dev/stdin "$cred"
          unset c_pass
          ok "wrote $cred (mode 600, root only)"
        else
          warn "no credentials for $server and not interactive; skipping $s_mp"
          continue
        fi
        SERVER_CRED[$server]=1
      fi

      opts="credentials=${cred},uid=${UID_VAL},gid=${GID_VAL},file_mode=0644,dir_mode=0755"
      opts+=",nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=60"
      opts+=",x-systemd.requires=network-online.target,x-systemd.after=network-online.target"
      NEW_LINES+=("${s_src}  ${s_mp}  cifs  ${opts}  0 0")
      ok "queued: $s_mp  <-  $s_src"
    done
  fi
fi

# =============================================================================
#  Apply
# =============================================================================
if ((${#NEW_LINES[@]} == 0)); then
  step "Summary"
  info "nothing to add; fstab unchanged"
  exit 0
fi

step "Proposed fstab entries"
printf '  %s\n' "${NEW_LINES[@]}"

if $DRY; then
  echo
  info "[DRY] nothing was written"
  exit 0
fi

if [[ -t 0 ]]; then
  read -rp "$(printf '%sAdd these to %s?%s [y/N] ' "$BOLD" "$FSTAB" "$NC")" reply
  [[ "$reply" == y || "$reply" == Y ]] || { info "aborted; fstab unchanged"; exit 0; }
fi

need_root
backup="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
sudo cp "$FSTAB" "$backup"
info "backed up $FSTAB -> $backup"

#  Create mount points first: a missing directory makes `mount -a` fail, and
#  findmnt --verify flags it as an unreachable target.
for l in "${NEW_LINES[@]}"; do
  [[ "$l" == \#* ]] && continue
  mp=$(awk '{print $2}' <<<"$l")
  if [[ ! -d "$mp" ]]; then
    if sudo mkdir -p "$mp" 2>/dev/null; then
      info "created $mp"
    else
      warn "could not create $mp; the entry is still valid but will not mount"
      warn "until the directory exists:  sudo mkdir -p $mp"
    fi
  fi
done

#  Build the new fstab in a temp file and VALIDATE before installing it. A
#  malformed fstab can stop the machine booting, so it is never edited in place.
tmp=$(mktemp)
cp "$FSTAB" "$tmp"
if ! grep -qxF "$BEGIN_MARK" "$tmp"; then
  { printf '\n%s\n' "$BEGIN_MARK"
    printf '# Added by MangoSetup scripts/50-fstab.sh. Remove with --revert;\n'
    printf '# hand edits inside this block will be lost on the next --revert.\n'
    printf '%s\n' "$END_MARK"; } >> "$tmp"
fi
#  Insert before the end marker so repeated runs accumulate correctly.
for l in "${NEW_LINES[@]}"; do
  awk -v line="$l" -v endm="$END_MARK" '
    $0 == endm { print line } { print }' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
done

#  Validation policy: PARSE ERRORS are fatal, reachability problems are not.
#
#  `findmnt --verify` checks the file against the LIVE system, so it reports
#  errors for things that are perfectly legitimate in an fstab: a network share
#  whose server is currently down, a mount point that does not exist yet, a
#  device that is not plugged in. Those are exactly why `nofail` exists, and
#  they must not block writing the file.
#
#  A PARSE error, by contrast, means the file is syntactically broken, which is
#  what can actually stop a boot. That is the hard gate.
verify_out=$(findmnt --verify --tab-file "$tmp" 2>&1)
parse_errors=$(grep -oE '^[0-9]+ parse errors' <<<"$verify_out" | grep -oE '^[0-9]+' || echo 0)
if (( parse_errors > 0 )); then
  err "the generated fstab has $parse_errors PARSE ERROR(S); refusing to install it"
  sed 's/^/    /' <<<"$verify_out"
  rm -f "$tmp"
  exit 1
fi
ok "generated fstab parses cleanly"
#  Surface the non-fatal findings so nothing is hidden.
if grep -qE '\[E\]|\[W\]' <<<"$verify_out"; then
  info "findmnt also reported (not fatal, usually 'not mounted yet'):"
  grep -E '\[E\]|\[W\]|^/' <<<"$verify_out" | sed 's/^/    /'
fi

#  Preserve fstab's existing mode/owner rather than forcing 644: a hardened
#  system may have tightened it, and this script has no business loosening it.
fstab_mode=$(stat -c '%a' "$FSTAB" 2>/dev/null || echo 644)
if ! sudo install -m "$fstab_mode" -o root -g root "$tmp" "$FSTAB"; then
  err "failed to write $FSTAB; your original is untouched"
  err "restore from the backup if anything looks wrong:  sudo cp $backup $FSTAB"
  rm -f "$tmp"
  exit 1
fi
rm -f "$tmp"
ok "$FSTAB updated (mode $fstab_mode preserved)"

sudo systemctl daemon-reload 2>/dev/null || true

step "Mounting"
if sudo mount -a 2>/tmp/mount-a.err; then
  ok "mount -a succeeded"
else
  warn "mount -a reported problems:"
  sed 's/^/    /' /tmp/mount-a.err
  warn "the fstab entries are valid but something did not mount (server down,"
  warn "wrong credentials, cable out). Fix and retry:  sudo mount -a"
fi
rm -f /tmp/mount-a.err

step "Summary"
ok "added ${#NEW_LINES[@]} line(s); backup at $backup"
info "check with: ./50-fstab.sh --status"
info "undo with:  ./50-fstab.sh --revert"
