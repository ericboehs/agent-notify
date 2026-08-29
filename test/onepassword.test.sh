#!/usr/bin/env bash
# Protocol test for `agent-1p-notify`, the script that labels 1Password's unlock
# dialog for both agents. It stubs the agent-notify backend with a recorder, so
# the test asserts exactly which payload and environment the backend would be
# handed, without drawing a banner or touching Slack.
#
# Run: test/onepassword.test.sh

set -u

# Anything the script reads that is still set out here would leak into the
# assertions — a real TMUX_PANE puts this pane's coordinates in the audit log.
unset TMUX TMUX_PANE
unset "${!AGENT_NOTIFY_@}"
unset "${!AGENT_1P_@}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/bin/agent-1p-notify"

pass=0
fail=0

setup() {
  WORK="$(mktemp -d)"
  STUB="$WORK/agent-notify"
  PAYLOAD="$WORK/payload"
  ARGS="$WORK/args"
  ENVFILE="$WORK/env"
  LOG="$WORK/1p-requests.log"
  cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
cat > "$PAYLOAD"
printf '%s\n' "\$@" > "$ARGS"
printf 'slack=%s\naway=%s\nimage=%s\napp=%s\n' "\${AGENT_NOTIFY_SLACK-unset}" \
  "\${AGENT_NOTIFY_SLACK_AWAY_ONLY-unset}" \
  "\${AGENT_NOTIFY_IMAGE-unset}" "\${AGENT_NOTIFY_APP_NAME-unset}" > "$ENVFILE"
STUBEOF
  chmod +x "$STUB"
}

teardown() { rm -rf "$WORK"; }

# Run one payload through the script with the recorder in place of the backend.
# TMUX_PANE is set per-case: the label the script composes depends on whether it
# can name a pane, and a suite that inherited the real one would assert against
# whichever pane happened to run it.
run_1p() {
  printf '%s' "$1" | env AGENT_NOTIFY_BIN="$STUB" AGENT_NOTIFY_1P_LOG="$LOG" \
    HOME="$WORK" TMUX= TMUX_PANE= "$SCRIPT" >/dev/null 2>&1
}

# As above, but with a stub tmux answering for a pane, so the label can be
# asserted without the suite depending on where it runs. It goes in $HOME/bin,
# because the script puts that first on PATH itself — a stub anywhere else loses
# to the real tmux, and the case passes or fails by which pane ran it.
run_1p_in_pane() {
  local pane="$2"
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/tmux" <<TMUXEOF
#!/usr/bin/env bash
printf '%s\n' "$pane"
TMUXEOF
  chmod +x "$WORK/bin/tmux"
  printf '%s' "$1" | env AGENT_NOTIFY_BIN="$STUB" AGENT_NOTIFY_1P_LOG="$LOG" \
    HOME="$WORK" TMUX_PANE="%9" "$SCRIPT" >/dev/null 2>&1
}

ok() { pass=$((pass + 1)); echo "  ✅ $1"; }
no() { fail=$((fail + 1)); echo "  ❌ $1"; }

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  if [[ "$actual" == "$expected" ]]; then ok "$desc"
  else no "$desc: expected [$expected], got [$actual]"; fi
}

assert_field() {
  local field="$1" expected="$2" desc="$3"
  assert_eq "$(jq -r "$field" "$PAYLOAD" 2>/dev/null)" "$expected" "$desc"
}

assert_silent() {
  local desc="$1"
  if [[ -f "$PAYLOAD" ]]; then no "$desc: backend was called"
  else ok "$desc"; fi
}

echo "agent-1p-notify"

echo "pi envelope"
setup
run_1p '{"agent":"pi","command":"op read op://Personal/EG4/api-key","session_name":"solar","cwd":"/tmp/proj"}'
assert_eq "$(cat "$ARGS")" "--event" "posts the canonical envelope"
assert_field '.agent' "pi" "names the agent"
assert_field '.event' "attention" "is an attention event, not a settled one"
assert_field '.session_name' "solar" "carries the session name"
assert_field '.cwd' "/tmp/proj" "carries the cwd"
assert_field '.subtitle' "1Password unlock requested" "says what is waiting"
assert_field '.message' "1Password: Personal/EG4/api-key" "names the secret, without the scheme"
assert_eq "$(grep -c 'Personal/EG4/api-key' "$LOG")" "1" "writes one audit line"
teardown

echo "Claude hook payload"
setup
run_1p '{"tool_name":"Bash","tool_input":{"command":"op item get \"EG4 Portal\""},"cwd":"/tmp/proj"}'
assert_eq "$(cat "$ARGS")" "" "posts a titled payload, not an envelope"
assert_field '.title' "1Password unlock requested" "titles the banner"
assert_field '.message' "1Password: EG4 Portal" "names the item"
teardown

echo "environment handed to the backend"
setup
run_1p '{"agent":"pi","command":"op read op://Personal/EG4/api-key","cwd":"/tmp"}'
assert_eq "$(grep '^slack=' "$ENVFILE")" "slack=true" "lets Slack have it"
assert_eq "$(grep '^away=' "$ENVFILE")" "away=true" "but only while away: asleep, or someone on VNC"
assert_eq "$(grep '^image=' "$ENVFILE")" \
  "image=/Applications/1Password.app/Contents/Resources/icon.icns" "pins 1Password's icon"
teardown
setup
printf '%s' '{"agent":"pi","command":"op read op://P/a/b","cwd":"/tmp"}' |
  env AGENT_NOTIFY_BIN="$STUB" AGENT_NOTIFY_1P_LOG="$LOG" HOME="$WORK" \
      TMUX= TMUX_PANE= AGENT_NOTIFY_SLACK=false "$SCRIPT" >/dev/null 2>&1
assert_eq "$(grep '^slack=' "$ENVFILE")" "slack=false" "and yields to an explicit AGENT_NOTIFY_SLACK"
teardown

echo "which window is asking"
setup
run_1p_in_pane '{"agent":"pi","command":"op read op://P/a/b","session_name":"solar","cwd":"/tmp/proj"}' "code:6.0"
assert_field '.session_name' "solar" "leaves the session name to the producer"
assert_field '.label_suffix' "code:6.0" "and passes the pane for agent-notify to append"
teardown
setup
run_1p_in_pane '{"tool_name":"Bash","tool_input":{"command":"op read op://P/a/b"},"cwd":"/tmp"}' "code:6.0"
assert_field '.label_suffix' "code:6.0" "Claude gets the pane too, on the payload it already sends"
teardown
setup
run_1p '{"agent":"pi","command":"op read op://P/a/b","session_name":"solar","cwd":"/tmp/proj"}'
assert_field '.label_suffix' "" "outside tmux there is no pane to name"
teardown

echo "what it names"
setup
run_1p '{"agent":"pi","command":"op signin --account my && op read op://P/a/b && op read op://P/c/d","cwd":"/tmp"}'
assert_field '.message' "1Password: P/a/b + P/c/d" "lists every item in a chain"
teardown
setup
run_1p '{"agent":"pi","command":"op read op://P/a/1 && op read op://P/b/2 && op read op://P/c/3 && op read op://P/d/4","cwd":"/tmp"}'
assert_field '.message' "1Password: P/a/1 + P/b/2 + P/c/3 +1 more" "summarises past three"
teardown
setup
run_1p '{"agent":"pi","command":"op vault list","cwd":"/tmp"}'
assert_field '.message' "1Password: op vault list" "falls back to the invocation itself"
teardown

echo "what stays quiet"
setup
run_1p '{"agent":"pi","command":"echo \"run op read to get it\"","cwd":"/tmp"}'
assert_silent "the word op inside an argument"
teardown
setup
run_1p '{"agent":"pi","command":"op --version","cwd":"/tmp"}'
assert_silent "a subcommand that unlocks nothing"
teardown
setup
run_1p '{"tool_name":"Read","tool_input":{"command":"op read op://P/a/b"},"cwd":"/tmp"}'
assert_silent "a Claude tool that is not Bash"
teardown
setup
run_1p '{"agent":"pi","command":"ls -la","cwd":"/tmp"}'
assert_silent "a command with no op in it"
teardown

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
