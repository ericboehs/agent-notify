#!/bin/bash

# agent-notify installer

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/bin"

# --pi also builds the branded "Pi Notify.app" bundle and prints pi setup notes.
# The pi extension (extensions/pi-notify.ts) drives the same backend for the pi
# coding agent; it needs its own bundle so pi and Claude banners carry distinct
# icons and do not replace each other.
WITH_PI=""
for arg in "$@"; do
  case "$arg" in
    --pi) WITH_PI=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

echo "Installing agent-notify..."

mkdir -p "$BIN_DIR"

# Symlinked rather than copied, so agent-notify keeps finding tmux-focus and
# agent-notify-app as siblings of its own resolved path, and an edit in the repo
# is live immediately.
echo "Symlinking to $BIN_DIR..."
for script in "$SCRIPT_DIR/bin/"*; do
  [ -f "$script" ] && ln -sf "$script" "$BIN_DIR/$(basename "$script")"
done

# The branded bundle is what makes a click answerable at all; without it
# agent-notify falls back to the terminal-notifier CLI, which can only draw.
if [ "$(uname)" = "Darwin" ]; then
  echo "Building notifier app bundle..."
  "$SCRIPT_DIR/bin/agent-notify-app" || echo "  (skipped - see agent-notify-app output above)"
  if [ -n "$WITH_PI" ]; then
    echo "Building Pi notifier app bundle..."
    AGENT_NOTIFY_APP_NAME=Pi AGENT_NOTIFY_BUNDLE_ID=com.ericboehs.pi-notify \
      "$SCRIPT_DIR/bin/agent-notify-app" || echo "  (skipped - see agent-notify-app output above)"
  fi
fi

if [ -n "$WITH_PI" ]; then
cat << EOF

Pi integration:

  Install the extension as a pi package (pins to the current commit):

    pi install git:github.com/ericboehs/agent-notify

  Or load it from this checkout for development:

    pi -e $SCRIPT_DIR/extensions/pi-notify.ts

  The extension announces on agent_settled, suppresses while pi-background-tasks
  or pi-subagents report active work, and posts through "Pi Notify.app". No hook
  config is needed for pi.
EOF
fi

cat << 'EOF'

Installation complete.

Add to the "hooks" section of ~/.claude/settings.json:

  "Stop": [
    { "hooks": [{ "type": "command", "command": "$HOME/bin/agent-notify" }] }
  ],
  "Notification": [
    { "hooks": [{ "type": "command", "command": "$HOME/bin/agent-notify" }] }
  ],
  "PreToolUse": [
    { "matcher": "AskUserQuestion",
      "hooks": [{ "type": "command", "command": "$HOME/bin/agent-notify" }] }
  ]

On a machine with no GUI, prefix that command with its forwarding config:

  AGENT_NOTIFY_HOST=thisbox AGENT_NOTIFY_FORWARD=yourmac $HOME/bin/agent-notify

Then:
  1. Ensure ~/bin is in your PATH
  2. Restart your Claude sessions to pick up the hooks
  3. Allow the notification prompt on the first banner, and the Accessibility
     prompt on the first click
EOF
