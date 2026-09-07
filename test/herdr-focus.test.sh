#!/usr/bin/env bash
# Contract test for the command a clicked Herdr notification runs.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOCUS="$REPO/bin/herdr-focus"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

pass=0
fail=0
check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc"
    fail=$((fail + 1))
  fi
}

cat > "$WORK/bin/herdr" <<'STUB'
#!/bin/sh
printf 'socket=%s\nenv=%s\nargs=%s\n' "$HERDR_SOCKET_PATH" "$HERDR_ENV" "$*" > "$HOME/herdr-call"
exit "${HERDR_TEST_RC:-0}"
STUB
cat > "$WORK/bin/open" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$HOME/open-call"
STUB
chmod +x "$WORK/bin/herdr" "$WORK/bin/open"

env HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" \
  HERDR_BIN_PATH="$WORK/bin/herdr" \
  "$FOCUS" w8:p1 "$WORK/herdr.sock" Ghostty

check "the original Herdr socket is restored" \
  grep -qxF "socket=$WORK/herdr.sock" "$WORK/herdr-call"
check "the exact pane is focused through the agent API" \
  grep -qxF 'args=agent focus w8:p1' "$WORK/herdr-call"
check "the helper identifies itself as Herdr-managed" \
  grep -qxF 'env=1' "$WORK/herdr-call"
check "Ghostty is raised after a successful focus" \
  grep -qxF -- '-a Ghostty' "$WORK/open-call"

rm -f "$WORK/open-call"
env HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" \
  HERDR_BIN_PATH="$WORK/bin/herdr" HERDR_TEST_RC=1 \
  "$FOCUS" w8:p1 "$WORK/herdr.sock" Ghostty
check "a stale or failed target does not raise an unrelated terminal view" \
  test ! -e "$WORK/open-call"

echo
echo "herdr-focus: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
