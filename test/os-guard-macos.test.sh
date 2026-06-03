#!/usr/bin/env bash
#
# Static guards for the macOS port's two OS gates:
#
#  1. install-macos.sh is the Darwin-native installer. Run on a non-Darwin host
#     it must refuse (its bootstrap uses dscl/sysadminctl/lsof/brew/Remote Login,
#     none of which exist on Linux). It must contain an explicit Darwin check.
#
#  2. install.sh must DISPATCH to install-macos.sh on Darwin instead of dying, so
#     the one-liner (curl ... install.sh | bash) keeps working on a Mac. Before
#     this port install.sh just `die`d on Darwin.
#
# These are source-level assertions (grep the scripts) — the runtime behaviour
# needs a real Mac/Linux host, but the gates themselves are verifiable here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_SH="$SCRIPT_DIR/../install-macos.sh"
LINUX_SH="$SCRIPT_DIR/../install.sh"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# 1. install-macos.sh requires Darwin.
if [ -f "$MACOS_SH" ]; then
  if grep -Eq 'uname[^|]*Darwin|"\$OS"[[:space:]]*!=[[:space:]]*"?Darwin' "$MACOS_SH" \
     || grep -q 'Darwin' "$MACOS_SH"; then
    # tighten: must actually gate on it, not merely mention it.
    if grep -Eq '\[ +"?\$?OS"? *!= *"?Darwin"? +\]|!= *Darwin|uname.*!=.*Darwin' "$MACOS_SH"; then
      ok "install-macos.sh gates on non-Darwin (refuses on Linux)"
    else
      bad "install-macos.sh mentions Darwin but has no '!= Darwin' guard to refuse on Linux"
    fi
  else
    bad "install-macos.sh has no Darwin OS guard"
  fi
else
  bad "install-macos.sh not found at $MACOS_SH"
fi

# 2. install.sh dispatches to install-macos.sh on Darwin (no longer a hard die).
if grep -q 'install-macos.sh' "$LINUX_SH"; then
  ok "install.sh references install-macos.sh (dispatch present)"
else
  bad "install.sh does not dispatch to install-macos.sh on Darwin"
fi

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
