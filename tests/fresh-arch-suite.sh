#!/usr/bin/env bash
#  Fresh-Arch readiness suite for MangoSetup.
#  Runs INSIDE a minimal Arch rootfs (systemd-nspawn) as user `tester`.
#  Exercises the real scripts; no writes outside the container.
set -uo pipefail
REPO="$HOME/repo3"
cd "$REPO" || exit 2
pass=0; fail=0
chk(){ if eval "$2" >/dev/null 2>&1; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }
chkout(){ # name, cmd, expected-substring
  local o; o=$(eval "$2" 2>&1)
  if grep -qF "$3" <<<"$o"; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1 (missing: $3)"; fail=$((fail+1)); fi; }
rc_of(){ eval "$1" >/dev/null 2>&1; echo $?; }

echo "=== 1. Syntax + exec-independence (all scripts run via bash) ==="
for f in scripts/*.sh; do chk "bash -n $(basename "$f")" "bash -n '$f'"; done

echo
echo "=== 2. --help / usage paths never crash ==="
chk "30-system-tweaks --help exits 0"  "[ \$(rc_of 'bash scripts/30-system-tweaks.sh --help') -eq 0 ]"
chk "60-session --help exits 0"        "[ \$(rc_of 'bash scripts/60-session.sh --help') -eq 0 ]"
chk "swap-app --list exits 0"          "[ \$(rc_of 'bash scripts/swap-app.sh --list') -eq 0 ]"

echo
echo "=== 3. Read-only modes exit 0 and change nothing ==="
before=$(find "$HOME/.config" -type l 2>/dev/null | sort | md5sum)
chk "00-preflight exits 0"             "[ \$(rc_of 'bash scripts/00-preflight.sh') -eq 0 ]"
chk "30-system-tweaks --status = 0"    "[ \$(rc_of 'bash scripts/30-system-tweaks.sh --status') -eq 0 ]"
chk "20-symlink --status = 0"          "[ \$(rc_of 'bash scripts/20-symlink.sh --status') -eq 0 ]"
chk "20-symlink --dry-run = 0"         "[ \$(rc_of 'bash scripts/20-symlink.sh --dry-run') -eq 0 ]"
chk "10-packages --dry-run = 0"        "[ \$(rc_of 'bash scripts/10-packages.sh --dry-run') -eq 0 ]"
chk "30-system-tweaks --all --dry-run" "[ \$(rc_of 'bash scripts/30-system-tweaks.sh --all --dry-run </dev/null') -eq 0 ]"
after=$(find "$HOME/.config" -type l 2>/dev/null | sort | md5sum)
chk "read-only modes left symlinks untouched" "[ '$before' = '$after' ]"

echo
echo "=== 4. Idempotency: deploy twice, second run is a no-op ==="
r1=$(rc_of 'bash scripts/20-symlink.sh')
n1=$(find "$HOME/.config" -type l | wc -l)
r2=$(rc_of 'bash scripts/20-symlink.sh')
n2=$(find "$HOME/.config" -type l | wc -l)
chk "first deploy exits 0"  "[ $r1 -eq 0 ]"
chk "second deploy exits 0" "[ $r2 -eq 0 ]"
chk "symlink count stable ($n1 = $n2)" "[ $n1 -eq $n2 ] && [ $n1 -gt 30 ]"
total=$(bash scripts/20-symlink.sh 2>&1 | grep -oP 'already correct : \K[0-9]+' | head -1)
chk "second run reports ALL files already correct ($total)" "[ \"\${total:-0}\" -gt 30 ]"
chk "--status now exits 0 when fully deployed (was the ((0)) bug)" \
    "[ \$(rc_of 'bash scripts/20-symlink.sh --status') -eq 0 ]"

echo
echo "=== 5. Round-trip: unlink then relink leaves no losses ==="
chk "--unlink exits 0" "[ \$(rc_of 'bash scripts/20-symlink.sh --unlink') -eq 0 ]"
chk "files still exist after unlink (real copies)" \
    "[ -f \$HOME/.config/mango/config.conf ]"
chk "relink exits 0"  "[ \$(rc_of 'bash scripts/20-symlink.sh') -eq 0 ]"
n3=$(find "$HOME/.config" -type l | wc -l)
chk "symlink count restored ($n3)" "[ $n3 -eq $n2 ]"

echo
echo "=== 6. Deployed config is valid against the REAL mango parser ==="
chk "validate-config.sh exits 0" \
    "[ \$(rc_of 'bash scripts/validate-config.sh \$HOME/.config/mango /tmp/mangosrc') -eq 0 ]"

echo
echo "=== 7. swap-app.sh behaves on every role + rejects bad input ==="
for r in TERMINAL BROWSER FILEMANAGER EDITOR VISUAL GUI_EDITOR MESSENGER \
         IMAGEVIEWER DOCVIEWER MEDIAPLAYER ARCHIVEMANAGER; do
  chk "--show $r exits 0" "[ \$(rc_of \"bash scripts/swap-app.sh --show $r\") -eq 0 ]"
done
chk "unknown role rejected (exit 1)" "[ \$(rc_of 'bash scripts/swap-app.sh NOTAROLE foo') -eq 1 ]"
chk "missing args rejected (exit 1)" "[ \$(rc_of 'bash scripts/swap-app.sh TERMINAL') -eq 1 ]"

echo
echo "=== 8. 60-session.sh refuses to lock you out ==="
chkout "refuses without mango installed" \
       'bash scripts/60-session.sh --dry-run' "mango compositor is not installed"
chk "  ...and exits 1"  "[ \$(rc_of 'bash scripts/60-session.sh --dry-run') -eq 1 ]"

echo
echo "=== 9. Guard: root invocation is refused with instructions ==="
if [ "$(id -u)" -eq 0 ]; then
  chkout "setup.sh as root refuses"    'bash scripts/setup.sh'      "do not run this wizard as root"
  chkout "10-packages as root refuses" 'bash scripts/10-packages.sh' "do not run as root"
else
  echo "  SKIP  root-guard checks (not root; nspawn mounts nosuid so sudo cannot elevate)"
  echo "        -> verified separately in the root-context run"
fi

echo
echo "=== 10. No host-specific leftovers in the shipped tree ==="
chk "no hydra.lan in scripts"  "! grep -rq 'hydra.lan' scripts/"
chk "no enp92s0 in scripts"    "! grep -rq 'enp92s0' scripts/"
chk "no enp92s0 in system/"    "! grep -rq 'enp92s0' system/"
chk "no em dash anywhere"      "! grep -rq '—' scripts/ system/ packages/ README.md"

echo
echo "=== 11. REGRESSION: bugs found in this audit stay fixed ==="
# (a) flags are independent, not folded into one MODE variable
chk "--all --dry-run does not fall through to the picker" \
    "! bash scripts/30-system-tweaks.sh --all --dry-run </dev/null 2>&1 | grep -q 'could not open a new TTY'"
chkout "--revert --all selects for REVERT (not apply)" \
       'bash scripts/30-system-tweaks.sh --revert --all --dry-run </dev/null' "for REVERT"
chk "unknown option is rejected, not ignored" \
    "[ \$(rc_of 'bash scripts/30-system-tweaks.sh --nonsense') -eq 2 ]"
# (b) no hang without a TTY
chk "picker fails fast with piped stdin (no hang)" \
    "[ \$(rc_of 'printf x | timeout 10 bash scripts/30-system-tweaks.sh') -eq 1 ]"
chk "setup.sh fails fast with piped stdin (no hang)" \
    "[ \$(rc_of 'printf n | timeout 10 bash scripts/setup.sh') -eq 1 ]"
# (c) ((0)) as last statement no longer sets a failing exit code
chk "20-symlink --status exits 0 with zero conflicts" \
    "[ \$(rc_of 'bash scripts/20-symlink.sh --status') -eq 0 ]"
# (d) manifest classification cannot silently claim success
chkout "10-packages names the AUR helper state explicitly" \
       'bash scripts/10-packages.sh --dry-run' "From the AUR"
# (e) Bolt detection must MATCH sysfs reality (nspawn shares the host's /sys,
#     so the receiver may genuinely be present; assert agreement, not absence).
bolt_real=no
for d in /sys/bus/usb/devices/*; do
  [ -r "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor" 2>/dev/null)" = "046d" ] || continue
  [ "$(cat "$d/idProduct" 2>/dev/null)" = "c548" ] || continue
  bolt_real=yes; break
done
bolt_line=$(bash scripts/30-system-tweaks.sh --status 2>&1 | grep -i logitech)
if [ "$bolt_real" = yes ]; then
  chk "Bolt receiver IS present -> tweak offered (not n/a)" \
      "! grep -q 'n/a here' <<<'$bolt_line'"
else
  chk "Bolt receiver absent -> tweak reported n/a" \
      "grep -q 'n/a here' <<<'$bolt_line'"
fi
chk "Bolt detection uses sysfs only (no lsusb in CODE; comments are fine)" \
    "! grep -v '^[[:space:]]*#' scripts/30-system-tweaks.sh | grep -q 'lsusb'"
# (f) prerequisites are real dependencies, declared in the manifest
for p in sudo git python base-devel ethtool; do
  chk "packages.txt declares $p" "grep -qxE '$p' packages/packages.txt"
done

echo
echo "======================================================"
echo "  PASS: $pass    FAIL: $fail"
(( fail == 0 )) && echo "  RESULT: FRESH-ARCH READY" || echo "  RESULT: PROBLEMS REMAIN"
exit $(( fail > 0 ))
