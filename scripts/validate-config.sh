#!/usr/bin/env bash
# =============================================================================
#  validate-config.sh - static checker for a mango configuration
# =============================================================================
#  Validates a mango config tree WITHOUT starting the compositor, by checking
#  it against the key/dispatcher inventory of a given mango source tree.
#
#  Catches the failure modes that mango itself reports weakly or not at all:
#    1. unknown config keys (typos, and keys removed/renamed upstream)
#    2. unknown dispatchers in bind/mousebind/axisbind/gesturebind/switchbind
#    3. DUPLICATE modifier+key bindings
#       -> since 0.15.5 only the FIRST is applied, silently breaking the rest
#    4. old positional monitorrule= syntax (pre-0.15.0)
#    5. unknown windowrule / tagrule / layerrule options
#    6. invalid layout names
#    7. source= targets that do not exist
#    8. leftover DankMaterialShell (dms) references
#
#  Usage:
#    ./validate-config.sh [CONFIG_DIR] [MANGO_SRC]
#
#  CONFIG_DIR defaults to ~/.config/mango
#  MANGO_SRC  defaults to /tmp/mango-src (cloned automatically if absent)
#
#  Exit codes: 0 = clean, 1 = errors found, 2 = could not run
# =============================================================================
set -uo pipefail

CONFIG_DIR="${1:-$HOME/.config/mango}"
MANGO_SRC="${2:-/tmp/mango-src}"
MANGO_REPO="https://github.com/mangowm/mango"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'

err()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }

[[ -d "$CONFIG_DIR" ]] || { err "config dir not found: $CONFIG_DIR"; exit 2; }

# --- Obtain a mango source tree to validate against -------------------------
if [[ ! -d "$MANGO_SRC/src/config" ]]; then
  info "fetching mango source for validation -> $MANGO_SRC"
  rm -rf "$MANGO_SRC"
  git clone --depth 1 "$MANGO_REPO" "$MANGO_SRC" >/dev/null 2>&1 \
    || { err "could not clone $MANGO_REPO"; exit 2; }
fi

PARSER="$MANGO_SRC/src/config/parse_config.h"
LAYOUTS="$MANGO_SRC/src/layout/layout.h"
[[ -f "$PARSER" ]] || { err "parser not found: $PARSER"; exit 2; }

MANGO_VER=$(git -C "$MANGO_SRC" describe --tags 2>/dev/null || echo unknown)
printf '%s\n' "${BOLD}mango config validation${NC}"
printf '  config : %s\n'  "$CONFIG_DIR"
printf '  source : %s (%s)\n\n' "$MANGO_SRC" "$MANGO_VER"

python3 - "$CONFIG_DIR" "$PARSER" "$LAYOUTS" <<'PYEOF'
import re, sys, os, glob, collections

cfg_dir, parser_path, layouts_path = sys.argv[1], sys.argv[2], sys.argv[3]
G="\033[0;32m"; R="\033[0;31m"; Y="\033[1;33m"; B="\033[0;34m"; N="\033[0m"

src = open(parser_path, encoding='utf-8', errors='replace').read()

# ---- authoritative inventories, scraped from the parser --------------------
all_keys = set(re.findall(r'strcmp\(\s*key\s*,\s*"([^"]+)"\s*\)', src))
dispatchers = set(re.findall(r'strcmp\(\s*func_name\s*,\s*"([^"]+)"\s*\)', src))

def rule_opts(rule):
    i = src.find(f'strcmp(key, "{rule}")')
    if i < 0: return set()
    return set(re.findall(r'strcmp\(\s*key\s*,\s*"([^"]+)"\s*\)', src[i:i+9000]))

wr = rule_opts("windowrule") | {"appid","title","class"}
tr = rule_opts("tagrule")
lr = rule_opts("layerrule")
mr = {"name","make","model","serial","width","height","refresh","x","y",
      "scale","rr","vrr","hdr","custom","disable"}

layouts = set()
if os.path.exists(layouts_path):
    lt = open(layouts_path, encoding='utf-8', errors='replace').read()
    layouts = set(re.findall(r'\{"[A-Z]+",\s*\w+,\s*"([a-z_]+)"', lt))

DIRECTIVES = {"bind","mousebind","axisbind","gesturebind","switchbind",
              "exec","exec-once","env","source","monitorrule","tagrule",
              "layerrule","windowrule"}
BIND_KINDS = {"bind","mousebind","axisbind","gesturebind","switchbind"}

errors = []; warnings = []
seen_binds = collections.defaultdict(list)

files = sorted(glob.glob(os.path.join(cfg_dir, "**", "*.conf"), recursive=True))
if not files:
    print(f"{R}[FAIL]{N} no .conf files under {cfg_dir}"); sys.exit(1)

for path in files:
    rel = os.path.relpath(path, cfg_dir)
    for lineno, raw in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, val = line.split('=', 1)
        key = key.strip(); val = val.strip()
        loc = f"{rel}:{lineno}"

        # 8. leftover references to a previous shell generation
        if re.search(r'\bdms\b|dankbar|DankMaterialShell', line, re.I):
            warnings.append((loc, "leftover DankMaterialShell reference", line))
        # 8b. Noctalia v4 (Quickshell/QML) syntax; v5 uses `noctalia msg ...`
        if 'qs -c noctalia' in line or re.search(r'ipc\s+call\s', line):
            warnings.append((loc,
                "Noctalia v4 IPC syntax ('qs -c noctalia-shell ipc call'); "
                "v5 uses 'noctalia msg <command>'", line))
        # 8c. v4 layer namespaces are suffixed per-screen; v5 mostly is not
        if re.search(r'layer_name:\s*(dms|quickshell)', line):
            warnings.append((loc,
                "layer namespace belongs to a previous shell and matches "
                "nothing under Noctalia v5", line))

        # 1. unknown scalar keys
        if key not in DIRECTIVES and key not in all_keys:
            errors.append((loc, f"unknown config key '{key}'", line))
            continue

        # 7. source= target must exist
        #    Resolve against the tree being validated as well as the real
        #    path, so a repo checkout can be linted before it is installed.
        if key == "source":
            tgt = os.path.expanduser(val.replace("$HOME", os.path.expanduser("~")))
            candidates = [tgt]
            m = re.search(r'\.config/mango/(.*)$', val)
            if m:
                candidates.append(os.path.join(cfg_dir, m.group(1)))
            if not any(os.path.exists(c) for c in candidates):
                errors.append((loc, f"source target missing: {val}", line))
            continue

        # 4. monitorrule must use key:value syntax
        if key == "monitorrule":
            if ':' not in val.split(',')[0]:
                errors.append((loc,
                    "OLD POSITIONAL monitorrule syntax (removed in 0.15.0); "
                    "use name:...,width:...,height:...", line))
            else:
                for tok in val.split(','):
                    if ':' not in tok: continue
                    o = tok.split(':', 1)[0].strip()
                    if o not in mr:
                        errors.append((loc, f"unknown monitorrule option '{o}'", line))
            continue

        # 5. rule option validation
        if key in ("windowrule", "tagrule", "layerrule"):
            valid = {"windowrule": wr, "tagrule": tr, "layerrule": lr}[key]
            for tok in val.split(','):
                if ':' not in tok: continue
                o = tok.split(':', 1)[0].strip()
                if o not in valid:
                    errors.append((loc, f"unknown {key} option '{o}'", line))
            # 6. layout names
            for m in re.finditer(r'layout_name:\s*([a-z_]+)', val):
                if layouts and m.group(1) not in layouts:
                    errors.append((loc, f"invalid layout '{m.group(1)}'", line))
            continue

        # 2 + 3. bindings
        if key in BIND_KINDS:
            parts = [p.strip() for p in val.split(',')]
            if key in ("bind", "mousebind", "axisbind"):
                if len(parts) < 3:
                    errors.append((loc, "malformed binding (need MODS,KEY,ACTION)", line))
                    continue
                mods_s, keyname, action = parts[0], parts[1], parts[2]
                mods = frozenset(m.strip().upper() for m in mods_s.split('+')
                                 if m.strip().upper() not in ("", "NONE"))
                ident = (key, mods, keyname.upper())
                seen_binds[ident].append((loc, line))
            elif key == "gesturebind":
                if len(parts) < 4:
                    errors.append((loc, "malformed gesturebind", line)); continue
                action = parts[3]
            else:  # switchbind
                if len(parts) < 2:
                    errors.append((loc, "malformed switchbind", line)); continue
                action = parts[1]

            if action not in dispatchers:
                hint = ""
                if ' ' in action:
                    hint = " (looks like a missing comma between the key and the action)"
                errors.append((loc, f"unknown dispatcher '{action}'{hint}", line))
            continue

# 3. duplicate bindings
for (kind, mods, keyname), locs in seen_binds.items():
    if len(locs) > 1:
        combo = ('+'.join(sorted(mods)) + '+' if mods else '') + keyname
        errors.append((locs[1][0],
            f"DUPLICATE {kind} '{combo}' (first defined at {locs[0][0]}; "
            "since 0.15.5 only the FIRST applies)", locs[1][1]))

# ---- report ---------------------------------------------------------------
print(f"{B}[INFO]{N} checked {len(files)} file(s), "
      f"{sum(len(v) for v in seen_binds.values())} binding(s)")
print(f"{B}[INFO]{N} inventory: {len(all_keys)} keys, "
      f"{len(dispatchers)} dispatchers, {len(layouts)} layouts")

if warnings:
    print()
    for loc, why, line in warnings:
        print(f"{Y}[WARN]{N} {loc}: {why}")
        print(f"        {line}")

if errors:
    print()
    for loc, why, line in errors:
        print(f"{R}[FAIL]{N} {loc}: {why}")
        print(f"        {line}")
    print(f"\n{R}{len(errors)} error(s) found{N}")
    sys.exit(1)

print(f"\n{G}Configuration is valid.{N}")
sys.exit(0)
PYEOF
rc=$?

echo
if [[ $rc -eq 0 ]]; then
  ok "validation passed"
else
  err "validation failed"
fi
exit $rc
