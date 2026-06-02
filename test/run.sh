#!/usr/bin/env bash
#
# Run the full bash test suite locally. Mirrors the loop in
# .github/workflows/ci.yml so a green run here means a green CI run.
#
#   test/run.sh            # run every test/*.test.sh
#   test/run.sh ensure     # run only tests whose name matches the glob *ensure*
#
set -uo pipefail

cd "$(dirname "$0")/.."

pattern="${1:-}"
rc=0
ran=0
for t in test/*.test.sh; do
  [ -f "$t" ] || continue
  if [ -n "$pattern" ]; then
    case "$t" in *"$pattern"*) ;; *) continue ;; esac
  fi
  ran=$((ran + 1))
  echo "── $t"
  bash "$t" || rc=1
done

[ "$ran" -gt 0 ] || { echo "no tests matched '${pattern}'"; exit 1; }
echo
[ "$rc" -eq 0 ] && echo "ALL PASS ($ran files)" || echo "SUITE FAILED"
exit "$rc"
