#!/usr/bin/env bash
#
# Unit test for install-macos.sh's sshd_listening — verifies the host's SSH
# endpoint (:22) is up so the dashboard's container->host SSH over
# host.docker.internal succeeds. Linux probes with `ss`/`netstat -ltn` (GNU
# syntax). macOS has neither in that form; the mac variant uses `lsof` to test
# for a LISTEN on TCP:22. Contract: return 0 iff something is listening on :22.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install-macos.sh"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$INSTALL_SH" ] || { bad "install-macos.sh not found at $INSTALL_SH"; echo "FAILED: $fails"; exit 1; }

eval "$(sed -n '/^sshd_listening()/,/^}/p' "$INSTALL_SH")"
command -v sshd_listening >/dev/null 2>&1 || { bad "sshd_listening not defined in install-macos.sh"; echo "FAILED: $fails"; exit 1; }

# Stub lsof: LSOF_RC controls whether a listener is reported (0 = listening).
LSOF_RC=0
lsof() { return "$LSOF_RC"; }

# Arm 1: lsof finds a listener → sshd_listening succeeds.
LSOF_RC=0
set +e; sshd_listening; rc=$?; set -e
[ "$rc" -eq 0 ] && ok "listening: returns 0" || bad "listening: returns 0 (got rc=$rc)"

# Arm 2: lsof finds nothing → sshd_listening fails (non-zero).
LSOF_RC=1
set +e; sshd_listening; rc=$?; set -e
[ "$rc" -ne 0 ] && ok "not listening: returns non-zero" || bad "not listening: returns non-zero (got rc=$rc)"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
