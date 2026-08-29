#!/usr/bin/env bash
# Protocol test for `agent-notify --event`, the canonical envelope the pi
# extension produces. It stubs the notifier binary with a recorder so the test
# asserts exactly which arguments the backend would hand macOS, without drawing a
# real banner or touching Slack.
#
# Run: test/notifier-protocol.test.sh

set -u

# Every case passes the environment it cares about explicitly, so anything the
# backend reads that is still set out here is a leak: run the suite inside a
# tmux pane and LC_AGENT_NOTIFY_PANE=%42 silently wins the precedence cases.
unset LC_AGENT_NOTIFY_PANE LC_CLAUDE_PANE TMUX TMUX_PANE TMUX_FOCUS
unset "${!AGENT_NOTIFY_@}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="$REPO/bin/agent-notify"

pass=0
fail=0

setup() {
  WORK="$(mktemp -d)"
  export APP_NAME="PiTest"
  local app="$WORK/Applications/$APP_NAME Notify.app/Contents/MacOS"
  mkdir -p "$app" "$WORK/.claude/manager"
  CAPTURE="$WORK/capture"
  # Stub notifier: record every argument, one per line, then exit 0.
  # A second copy separates arguments with a record separator instead of a
  # newline, because a banner body legitimately contains newlines and the
  # line-per-argument file cannot tell those apart from the next argument.
  CAPTURE_RS="$WORK/capture.rs"
  cat > "$app/agent-notifier" <<STUB
#!/usr/bin/env bash
: > "$CAPTURE"
: > "$CAPTURE_RS"
for a in "\$@"; do printf '%s\n' "\$a" >> "$CAPTURE"; printf '%s\036' "\$a" >> "$CAPTURE_RS"; done
STUB
  chmod +x "$app/agent-notifier"
}

teardown() { rm -rf "$WORK"; }

# Run one envelope through the backend in the foreground with a clean HOME.
run_event() {
  local json="$1"
  printf '%s' "$json" | \
    env HOME="$WORK" \
        AGENT_NOTIFY_FOREGROUND=1 \
        AGENT_NOTIFY_APP_NAME="$APP_NAME" \
        AGENT_NOTIFY_SLACK=false \
        TMUX= TMUX_PANE= \
        "$NOTIFY" --event >/dev/null 2>&1
}

# As run_event, but through the Claude hook path: no --event, and the payload is
# the {title,message} shape a wrapper like agent-1p-notify sends.
run_hook() {
  local json="$1"
  printf '%s' "$json" | \
    env HOME="$WORK" \
        AGENT_NOTIFY_FOREGROUND=1 \
        AGENT_NOTIFY_APP_NAME="$APP_NAME" \
        AGENT_NOTIFY_SLACK=false \
        TMUX= TMUX_PANE= \
        "$NOTIFY" >/dev/null 2>&1
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

# Assert a "--flag value" pair whose value may itself contain newlines. Reads the
# record-separated capture, so a multi-line body compares as the single argument
# it actually was.
assert_pair_exact() {
  local flag="$1" value="$2" desc="$3"
  local data i
  data=$(cat "$CAPTURE_RS" 2>/dev/null)
  # Split on the record separator the stub writes between arguments. IFS is a
  # prefix to read, so it is scoped to this one command and there is no global
  # to save, restore, or protect from globbing with set -f. -d '' reads past the
  # newlines a banner body legitimately contains, and returns 1 at EOF for the
  # same reason.
  local args=()
  IFS=$'\036' read -r -d '' -a args < <(printf '%s' "$data") || true
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "$flag" ]]; then
      if [[ "${args[$((i + 1))]}" == "$value" ]]; then
        echo "PASS: $desc"; pass=$((pass + 1))
      else
        echo "FAIL: $desc (expected '$value', got '${args[$((i + 1))]}')"; fail=$((fail + 1))
      fi
      return
    fi
  done
  echo "FAIL: $desc (no $flag in argv)"; fail=$((fail + 1))
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

assert_json_field() {
  local file="$1" filter="$2" expected="$3" desc="$4"
  local actual
  actual=$(jq -r "$filter" "$file" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"; pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected '$expected', got '$actual')"; fail=$((fail + 1))
  fi
}

# --- stubs for the Slack path ---------------------------------------------
# The watched check reads three things the test machine would otherwise answer
# for itself: which clients tmux has, where their ttys were logged in from, and
# whether this display is awake. All three are on PATH, and the backend puts
# $HOME/bin first, so a stub in the sandbox wins.

# tmux with a single client: $1 its flags, $2 its tty.
stub_tmux_client() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
  list-clients)
    case "\$*" in
      *client_flags*) printf '%s|%s\n' '$1' '$2' ;;
      *)              printf '1|%s\n' '$2' ;;
    esac
    ;;
  display-message)
    case "\$*" in
      *'#{session_name}'*) printf 'code\n' ;;
      *'#{pane_active} #{window_active} #{session_attached}'*) printf '1 1 1\n' ;;
      *) printf 'code:1.0\n' ;;
    esac
    ;;
esac
STUB
  chmod +x "$WORK/bin/tmux"
}

# who(1): $1 the tty, $2 the origin host in parentheses, or empty for a terminal
# on this machine's own display.
stub_who() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/who" <<STUB
#!/usr/bin/env bash
printf 'ericboehs        %s      Aug 29 18:20 %s\n' '${1##*/}' '${2:-}'
STUB
  chmod +x "$WORK/bin/who"
}

# Away or not: is_display_asleep asks CoreGraphics through python3 and takes its
# exit status, and the VNC check reads pgrep and netstat.
stub_display() {
  local asleep="$1"
  mkdir -p "$WORK/bin"
  printf '#!/usr/bin/env bash\nexit %s\n' "$asleep" > "$WORK/bin/python3"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/pgrep"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/netstat"
  chmod +x "$WORK/bin/python3" "$WORK/bin/pgrep" "$WORK/bin/netstat"
}

# slack-noti records the post instead of making it. The webhook variable is what
# sends the backend down this branch rather than through tmux run-shell.
stub_slack() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/slack-noti" <<STUB
#!/usr/bin/env bash
printf '%s' "\$1" > "$WORK/slack"
STUB
  chmod +x "$WORK/bin/slack-noti"
}

assert_slack() {
  local want="$1" desc="$2" got=no
  [[ -f "$WORK/slack" ]] && got=yes
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $desc"; pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected slack=$want, got slack=$got)"; fail=$((fail + 1))
  fi
}

# One settled envelope from a pane in tmux, with the Slack path live. Extra
# environment for the case goes in "$@".
run_slack_event() {
  printf '%s' '{"version":1,"agent":"pi","event":"settled","session_name":"s","message":"done"}' | \
    env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_APP_NAME="$APP_NAME" \
        AGENT_NOTIFY_SLACK=true BOEHS_SLACK_NOTI_HOOK=hook \
        TMUX=x TMUX_PANE=%42 "$@" \
        "$NOTIFY" --event >/dev/null 2>&1
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
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_APP_NAME="$APP_NAME" \
      AGENT_NOTIFY_SLACK=false AGENT_NOTIFY_HOST=gfe TMUX= TMUX_PANE= \
      "$NOTIFY" --event >/dev/null 2>&1
assert_pair -title "gfe:api" "AGENT_NOTIFY_HOST prefixes the label"
teardown

# --- case 4b: label_suffix ------------------------------------------------
# A caller that knows something the label does not (agent-1p-notify knows the
# pane) can qualify it, and the qualifier has to survive the host prefix rather
# than displace it.
setup
run_event '{"version":1,"agent":"pi","event":"attention","session_name":"solar","cwd":"/x/proj","message":"1Password: Fastmail","label_suffix":"code:6.0"}'
assert_pair -title "solar · code:6.0" "label_suffix names the pane behind the session"
teardown
setup
run_event '{"version":1,"agent":"pi","event":"attention","cwd":"/x/proj","message":"1Password: Fastmail","label_suffix":"code:6.0"}'
assert_pair -title "proj · code:6.0" "and qualifies the cwd fallback too"
teardown
setup
run_event '{"version":1,"agent":"pi","event":"attention","session_name":"code:6.0","message":"1Password: Fastmail","label_suffix":"code:6.0"}'
assert_pair -title "code:6.0" "but never says the same thing twice"
teardown
setup
printf '%s' '{"version":1,"agent":"pi","event":"attention","session_name":"solar","message":"hi","label_suffix":"code:6.0"}' | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_APP_NAME="$APP_NAME" \
      AGENT_NOTIFY_SLACK=false AGENT_NOTIFY_HOST=gfe TMUX= TMUX_PANE= \
      "$NOTIFY" --event >/dev/null 2>&1
assert_pair -title "gfe:solar · code:6.0" "the host still prefixes the whole thing"
teardown
setup
# The Claude hook path resolves its own label, so the suffix is the only way a
# wrapper can add the pane there.
run_hook '{"title":"1Password unlock requested","message":"1Password: Fastmail","label_suffix":"code:6.0"}'
assert_pair -title "Session · code:6.0" "a titled hook payload takes the suffix too"
assert_pair -subtitle "1Password unlock requested" "and keeps its title as the subtitle"
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
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_APP_NAME="$APP_NAME" \
      AGENT_NOTIFY_SLACK=false AGENT_NOTIFY_IMAGE="$pinned" TMUX= TMUX_PANE= \
      "$NOTIFY" --event >/dev/null 2>&1
assert_pair -contentImage "$pinned" "an explicit AGENT_NOTIFY_IMAGE beats the mark"
teardown

# --- case 8: the scripts must parse under the bash the bundle actually gets ---
# A clicked notification runs through /bin/sh with a minimal PATH, so
# `#!/usr/bin/env bash` resolves to /bin/bash 3.2 rather than whatever modern
# bash sits on an interactive PATH. Syntax only 4+ accepts parses fine in
# development and dies at the click, after the tmux hop has already logged
# success - which looks exactly like a permissions problem.
if [ -x /bin/bash ]; then
  legacy=$(/bin/bash --version | head -1 | sed 's/.*version \([0-9.]*\).*/\1/')
  for f in "$REPO"/bin/*; do
    if /bin/bash -n "$f" 2>/dev/null; then
      echo "PASS: $(basename "$f") parses under /bin/bash $legacy"
      pass=$((pass + 1))
    else
      echo "FAIL: $(basename "$f") does not parse under /bin/bash $legacy"
      fail=$((fail + 1))
    fi
  done
fi

# --- case 9: a forwarded pi notification keeps pi's identity --------------
# The receiving machine never saw the envelope, and --recv runs as an ssh forced
# command with no environment. If the agent does not travel in the payload, a pi
# notification is drawn out of the Claude bundle: Claude's name, Claude's mark.
setup
mark="$WORK/Applications/$APP_NAME Notify.app/Contents/Resources/pi.png"
mkdir -p "$(dirname "$mark")" && : > "$mark"
printf '%s' "{\"label\":\"coop:api\",\"agent\":\"pi\",\"app\":\"$APP_NAME\",\"header\":\":robot_face: coop:api\",\"message\":\"hi\",\"host\":\"coop\",\"target\":\"w:1.0\"}" | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_SLACK=false \
      TMUX= TMUX_PANE= "$NOTIFY" --recv >/dev/null 2>&1
assert_pair -contentImage "$mark" "a forwarded pi notification keeps pi's mark"
assert_prefix -group "pi-" "a forwarded pi notification groups under pi"
teardown

# --- case 10: a forwarded Claude notification is unchanged ----------------
# Older senders forward no agent at all, and everything they could send was
# Claude's, so silence has to keep meaning Claude.
setup
printf '%s' '{"label":"coop:api","message":"hi","host":"coop","target":"w:1.0"}' | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_SLACK=false \
      AGENT_NOTIFY_APP_NAME="$APP_NAME" TMUX= TMUX_PANE= "$NOTIFY" --recv >/dev/null 2>&1
assert_prefix -group "claude-" "a payload with no agent still reads as Claude"
teardown

# --- case 11: a long reply reaches the banner whole, shape intact ---------
# The banner body used to be cut to its first paragraph and then flowed into a
# single line, so a verse or a list arrived as neither. Notification Center
# renders line breaks and truncates on its own, and it is the only party that
# knows how much room it has, so the backend hands over what it was given.
# Blockquote markers go the way of the other markdown: plain text draws them
# literally, and "> " down the left margin is noise where words could be.
setup
long=$'> All green, and the shape survives:\n> first line, then a second,\n\nand a closing note.'
want=$'All green, and the shape survives:\nfirst line, then a second,\n\nand a closing note.'
run_event "$(printf '{"version":1,"agent":"pi","event":"settled","cwd":"/p","message":%s}' "$(printf '%s' "$long" | jq -Rs .)")"
assert_pair_exact -message "$want" "a multi-line reply keeps its line breaks, minus the quote markers"
teardown

# --- case 12: the agent-neutral origin pane wins over the legacy alias -----
setup
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ssh" <<STUB
#!/usr/bin/env bash
cat > "$WORK/forwarded"
STUB
chmod +x "$WORK/bin/ssh"
printf '%s' '{"version":1,"agent":"pi","event":"settled","cwd":"/p","message":"hi"}' | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_FORWARD=receiver \
      AGENT_NOTIFY_SLACK=false LC_AGENT_NOTIFY_PANE=%new LC_CLAUDE_PANE=%old \
      TMUX= TMUX_PANE= "$NOTIFY" --event >/dev/null 2>&1
assert_json_field "$WORK/forwarded" .origin %new \
  "LC_AGENT_NOTIFY_PANE takes precedence over the legacy alias"
teardown

# --- case 13: the old origin variable remains a compatibility fallback -----
setup
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ssh" <<STUB
#!/usr/bin/env bash
cat > "$WORK/forwarded"
STUB
chmod +x "$WORK/bin/ssh"
printf '%s' '{"version":1,"agent":"pi","event":"settled","cwd":"/p","message":"hi"}' | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_FORWARD=receiver \
      AGENT_NOTIFY_SLACK=false LC_CLAUDE_PANE=%legacy \
      TMUX= TMUX_PANE= "$NOTIFY" --event >/dev/null 2>&1
assert_json_field "$WORK/forwarded" .origin %legacy \
  "LC_CLAUDE_PANE remains a compatibility fallback"
teardown

# --- case 14: per-tty state prefers the agent-notify directory -------------
setup
mkdir -p "$WORK/bin" "$WORK/.agent-notify/origin" "$WORK/.claude/origin"
cat > "$WORK/bin/ssh" <<STUB
#!/usr/bin/env bash
cat > "$WORK/forwarded"
STUB
cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-clients) printf '1|/dev/ttys001\n' ;;
  display-message)
    case "$*" in
      *'#{session_name}'*) printf 'code\n' ;;
      *'#{pane_active} #{window_active} #{session_attached}'*) printf '1 1 1\n' ;;
      *) printf 'code:1.0\n' ;;
    esac
    ;;
esac
STUB
chmod +x "$WORK/bin/ssh" "$WORK/bin/tmux"
printf '%s' %new-state > "$WORK/.agent-notify/origin/-dev-ttys001"
printf '%s' %old-state > "$WORK/.claude/origin/-dev-ttys001"
printf '%s' '{"version":1,"agent":"pi","event":"settled","cwd":"/p","message":"hi"}' | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_FORWARD=receiver \
      AGENT_NOTIFY_SLACK=false TMUX=x TMUX_PANE=%42 \
      "$NOTIFY" --event >/dev/null 2>&1
assert_json_field "$WORK/forwarded" .origin %new-state \
  "the agent-notify origin state takes precedence over legacy state"
teardown

# --- case 15: the old per-tty state directory remains a fallback -----------
setup
mkdir -p "$WORK/bin" "$WORK/.claude/origin"
cat > "$WORK/bin/ssh" <<STUB
#!/usr/bin/env bash
cat > "$WORK/forwarded"
STUB
cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-clients) printf '1|/dev/ttys001\n' ;;
  display-message)
    case "$*" in
      *'#{session_name}'*) printf 'code\n' ;;
      *'#{pane_active} #{window_active} #{session_attached}'*) printf '1 1 1\n' ;;
      *) printf 'code:1.0\n' ;;
    esac
    ;;
esac
STUB
chmod +x "$WORK/bin/ssh" "$WORK/bin/tmux"
printf '%s' %legacy-state > "$WORK/.claude/origin/-dev-ttys001"
printf '%s' '{"version":1,"agent":"pi","event":"settled","cwd":"/p","message":"hi"}' | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_FORWARD=receiver \
      AGENT_NOTIFY_SLACK=false TMUX=x TMUX_PANE=%42 \
      "$NOTIFY" --event >/dev/null 2>&1
assert_json_field "$WORK/forwarded" .origin %legacy-state \
  "the Claude origin directory remains a compatibility fallback"
teardown

# --- case 16: an iPad reading the pane keeps Slack quiet -------------------
# Blink reports terminal focus (DEC 1004) and tmux carries it as the client's
# `focused` flag, which is the only sign this machine gets that someone is
# reading over ssh. The Mac's own display is dark, so the away rule would
# otherwise post: the reply is already on a screen in the room.
setup
stub_tmux_client 'attached,focused,UTF-8' /dev/ttys014
stub_who /dev/ttys014 '(10.0.1.124)'
stub_display 0
stub_slack
run_slack_event AGENT_NOTIFY_SLACK_AWAY_ONLY=true
assert_slack no "a focused ssh client showing the pane keeps Slack quiet"
teardown

# --- case 17: a dark display does not un-focus the terminal in front of it --
# Nothing tells Ghostty the screen went to sleep, so its client stays `focused`
# with the agent pane on top. Believing that would silence the away channel for
# a laptop with the lid shut, which is the case it exists for.
setup
stub_tmux_client 'attached,focused,UTF-8' /dev/ttys000
stub_who /dev/ttys000
stub_display 0
stub_slack
run_slack_event AGENT_NOTIFY_SLACK_AWAY_ONLY=true
assert_slack yes "a local terminal's focus flag is not believed once away"
teardown

# --- case 18: attached is not watching ------------------------------------
# The client stays attached across an iOS background - the ssh socket survives -
# so the flag has to be the signal, not the connection.
setup
stub_tmux_client 'attached,UTF-8' /dev/ttys014
stub_who /dev/ttys014 '(10.0.1.124)'
stub_display 0
stub_slack
run_slack_event AGENT_NOTIFY_SLACK_AWAY_ONLY=true
assert_slack yes "an attached but unfocused client still gets the Slack post"
teardown

# --- case 19: the suppression can be turned off ---------------------------
setup
stub_tmux_client 'attached,focused,UTF-8' /dev/ttys014
stub_who /dev/ttys014 '(10.0.1.124)'
stub_display 0
stub_slack
run_slack_event AGENT_NOTIFY_SLACK_AWAY_ONLY=true AGENT_NOTIFY_SLACK_WHEN_WATCHED=true
assert_slack yes "AGENT_NOTIFY_SLACK_WHEN_WATCHED posts anyway"
teardown

# --- case 20: at the desk, the local terminal counts ----------------------
# With the display awake there is nothing stale about the focus flag, so a
# Ghostty tab showing the pane is as much "already read" as the iPad is. Only
# reachable with the away rule off, which is what asks for Slack regardless.
setup
stub_tmux_client 'attached,focused,UTF-8' /dev/ttys000
stub_who /dev/ttys000
stub_display 1
stub_slack
run_slack_event AGENT_NOTIFY_SLACK_AWAY_ONLY=false
assert_slack no "a focused local client on a live display counts as watching"
teardown

# --- case 21: the answer travels with a forwarded notification ------------
# Only the machine running the agent can see its own tmux, so the Mac has to be
# told rather than measure.
setup
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ssh" <<STUB
#!/usr/bin/env bash
cat > "$WORK/forwarded"
STUB
chmod +x "$WORK/bin/ssh"
stub_tmux_client 'attached,focused,UTF-8' /dev/ttys014
stub_who /dev/ttys014 '(10.0.1.124)'
stub_display 1
printf '%s' '{"version":1,"agent":"pi","event":"settled","cwd":"/p","message":"hi"}' | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_FORWARD=receiver \
      AGENT_NOTIFY_SLACK=true AGENT_NOTIFY_SLACK_WHEN_WATCHED=false \
      TMUX=x TMUX_PANE=%42 "$NOTIFY" --event >/dev/null 2>&1
assert_json_field "$WORK/forwarded" .watched 1 \
  "the sender reports that a focused client is reading the pane"
assert_json_field "$WORK/forwarded" .slack_when_watched false \
  "and the policy for it travels alongside the other Slack knobs"
teardown

# --- case 22: the receiver honours it -------------------------------------
# --recv runs as a forced command with no environment, and the Mac is asleep, so
# without the payload field it would post every one of these.
setup
stub_display 0
stub_slack
printf '%s' '{"label":"coop:api","agent":"pi","message":"hi","host":"coop","target":"%9","slack":"true","slack_away_only":"true","watched":"1"}' | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_APP_NAME="$APP_NAME" \
      BOEHS_SLACK_NOTI_HOOK=hook TMUX= TMUX_PANE= "$NOTIFY" --recv >/dev/null 2>&1
assert_slack no "a forwarded notification the sender says is being read stays off Slack"
teardown

setup
stub_display 0
stub_slack
printf '%s' '{"label":"coop:api","agent":"pi","message":"hi","host":"coop","target":"%9","slack":"true","slack_away_only":"true","watched":"0"}' | \
  env HOME="$WORK" AGENT_NOTIFY_FOREGROUND=1 AGENT_NOTIFY_APP_NAME="$APP_NAME" \
      BOEHS_SLACK_NOTI_HOOK=hook TMUX= TMUX_PANE= "$NOTIFY" --recv >/dev/null 2>&1
assert_slack yes "and one nobody is reading still reaches it"
teardown

# --- case 23: no tmux, no opinion -----------------------------------------
# Every step of the check fails open: a notification from outside tmux, or from
# a box where the commands are missing, is still worth a Slack post.
setup
stub_display 0
stub_slack
run_slack_event AGENT_NOTIFY_SLACK_AWAY_ONLY=true TMUX= TMUX_PANE=
assert_slack yes "a pane the check cannot see anything about still posts"
teardown

echo
echo "protocol: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
