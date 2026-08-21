#!/usr/bin/env bash
# Protocol test for `claude-notify --event`, the canonical envelope the pi
# extension produces. It stubs the notifier binary with a recorder so the test
# asserts exactly which arguments the backend would hand macOS, without drawing a
# real banner or touching Slack.
#
# Run: test/notifier-protocol.test.sh

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="$REPO/bin/claude-notify"

pass=0
fail=0

setup() {
  WORK="$(mktemp -d)"
  export APP_NAME="PiTest"
  local app="$WORK/Applications/$APP_NAME Notify.app/Contents/MacOS"
  mkdir -p "$app" "$WORK/.claude/manager"
  CAPTURE="$WORK/capture"
  # Stub notifier: record every argument, one per line, then exit 0.
  cat > "$app/claude-notifier" <<STUB
#!/usr/bin/env bash
: > "$CAPTURE"
for a in "\$@"; do printf '%s\n' "\$a" >> "$CAPTURE"; done
STUB
  chmod +x "$app/claude-notifier"
}

teardown() { rm -rf "$WORK"; }

# Run one envelope through the backend in the foreground with a clean HOME.
run_event() {
  local json="$1"
  printf '%s' "$json" | \
    env HOME="$WORK" \
        CLAUDE_NOTIFY_FOREGROUND=1 \
        CLAUDE_NOTIFY_APP_NAME="$APP_NAME" \
        CLAUDE_NOTIFY_SLACK=false \
        TMUX= TMUX_PANE= \
        "$NOTIFY" --event >/dev/null 2>&1
}

# Assert the recorded argv contains a "--flag value" pair.
assert_pair() {
  local flag="$1" value="$2" desc="$3"
  local n line
  n=$(grep -nxF -- "$flag" "$CAPTURE" 2>/dev/null | head -1 | cut -d: -f1)
  if [[ -z "$n" ]]; then
    echo "FAIL: $desc (no $flag in argv)"; fail=$((fail + 1)); return
  fi
  line=$(sed -n "$((n + 1))p" "$CAPTURE")
  if [[ "$line" == "$value" ]]; then
    echo "PASS: $desc"; pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected '$value', got '$line')"; fail=$((fail + 1))
  fi
}

assert_prefix() {
  local flag="$1" prefix="$2" desc="$3"
  local n line
  n=$(grep -nxF -- "$flag" "$CAPTURE" 2>/dev/null | head -1 | cut -d: -f1)
  line=$(sed -n "$((n + 1))p" "$CAPTURE")
  if [[ "$line" == "$prefix"* ]]; then
    echo "PASS: $desc"; pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected prefix '$prefix', got '$line')"; fail=$((fail + 1))
  fi
}

# --- case 1: named session ------------------------------------------------
setup
run_event '{"version":1,"agent":"pi","event":"settled","session_name":"hd-recovery","cwd":"/x/proj","message":"All tests pass."}'
assert_pair    -title   "hd-recovery"     "session_name becomes the banner title"
assert_pair    -message "All tests pass." "message becomes the banner body"
assert_prefix  -group   "pi-"             "group is pi-scoped (never clobbers claude-*)"
teardown

# --- case 2: no name falls back to cwd basename --------------------------
setup
run_event '{"version":1,"agent":"pi","event":"settled","cwd":"/home/eric/Code/widgets","message":"Done."}'
assert_pair -title "widgets" "label falls back to cwd basename when unnamed"
teardown

# --- case 3: empty message gets a sensible default -----------------------
setup
run_event '{"version":1,"agent":"pi","event":"settled","session_name":"s","message":""}'
assert_pair -message "Ready for further instruction." "empty message gets default body"
teardown

# --- case 4: host prefix ------------------------------------------------
setup
printf '%s' '{"version":1,"agent":"pi","event":"settled","session_name":"api","message":"hi"}' | \
  env HOME="$WORK" CLAUDE_NOTIFY_FOREGROUND=1 CLAUDE_NOTIFY_APP_NAME="$APP_NAME" \
      CLAUDE_NOTIFY_SLACK=false CLAUDE_NOTIFY_HOST=gfe TMUX= TMUX_PANE= \
      "$NOTIFY" --event >/dev/null 2>&1
assert_pair -title "gfe:api" "CLAUDE_NOTIFY_HOST prefixes the label"
teardown

# --- case 5: the banner takes message, never the longer slack_body -------
setup
run_event '{"version":1,"agent":"pi","event":"settled","session_name":"s","message":"pong","slack_body":"pong\n\nNext steps:\n1. a\n2. b"}'
assert_pair -message "pong" "banner uses message, not slack_body"
teardown

# --- case 6: the agent's mark rides along as the thumbnail ----------------
# A Claude banner keeps the terminal's icon on the left and puts Claude's mark on
# the right; a pi banner should do the same with pi's. The bundle ships the
# rendered mark, so the backend has to find it there and pass it on.
setup
mark="$WORK/Applications/$APP_NAME Notify.app/Contents/Resources/pi.png"
mkdir -p "$(dirname "$mark")" && : > "$mark"
run_event '{"version":1,"agent":"pi","event":"settled","session_name":"s","message":"hi"}'
assert_pair -contentImage "$mark" "settled banner carries the pi mark"
teardown

# --- case 7: an explicit image still wins ---------------------------------
setup
mark="$WORK/Applications/$APP_NAME Notify.app/Contents/Resources/pi.png"
mkdir -p "$(dirname "$mark")" && : > "$mark"
pinned="$WORK/pinned.png"; : > "$pinned"
printf '%s' '{"version":1,"agent":"pi","event":"settled","session_name":"s","message":"hi"}' | \
  env HOME="$WORK" CLAUDE_NOTIFY_FOREGROUND=1 CLAUDE_NOTIFY_APP_NAME="$APP_NAME" \
      CLAUDE_NOTIFY_SLACK=false CLAUDE_NOTIFY_IMAGE="$pinned" TMUX= TMUX_PANE= \
      "$NOTIFY" --event >/dev/null 2>&1
assert_pair -contentImage "$pinned" "an explicit CLAUDE_NOTIFY_IMAGE beats the mark"
teardown

echo
echo "protocol: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
