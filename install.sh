#!/bin/bash

# claude-notify installer

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/bin"

echo "Installing claude-notify..."

mkdir -p "$BIN_DIR"

# Symlinked rather than copied, so claude-notify keeps finding tmux-focus and
# claude-notify-app as siblings of its own resolved path, and an edit in the repo
# is live immediately.
echo "Symlinking to $BIN_DIR..."
for script in "$SCRIPT_DIR/bin/"*; do
  [ -f "$script" ] && ln -sf "$script" "$BIN_DIR/$(basename "$script")"
done

# The branded bundle is what makes a click answerable at all; without it
# claude-notify falls back to the terminal-notifier CLI, which can only draw.
if [ "$(uname)" = "Darwin" ]; then
  echo "Building notifier app bundle..."
  "$SCRIPT_DIR/bin/claude-notify-app" || echo "  (skipped - see claude-notify-app output above)"
fi

cat << 'EOF'

Installation complete.

Add to the "hooks" section of ~/.claude/settings.json:

  "Stop": [
    { "hooks": [{ "type": "command", "command": "$HOME/bin/claude-notify" }] }
  ],
  "Notification": [
    { "hooks": [{ "type": "command", "command": "$HOME/bin/claude-notify" }] }
  ],
  "PreToolUse": [
    { "matcher": "AskUserQuestion",
      "hooks": [{ "type": "command", "command": "$HOME/bin/claude-notify" }] }
  ]

On a machine with no GUI, prefix that command with its forwarding config:

  CLAUDE_NOTIFY_HOST=thisbox CLAUDE_NOTIFY_FORWARD=yourmac $HOME/bin/claude-notify

Then:
  1. Ensure ~/bin is in your PATH
  2. Restart your Claude sessions to pick up the hooks
  3. Allow the notification prompt on the first banner, and the Accessibility
     prompt on the first click
EOF
