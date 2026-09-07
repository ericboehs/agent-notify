# agent-notify

Desktop notifications for coding agents — [Claude Code](https://claude.com/claude-code)
and [pi](https://pi.dev) — that know which pane they came from, so clicking a
banner lands you on the Herdr or tmux pane that sent it. tmux targets can also
span another machine.

Claude Code supplies hooks for turns ending, blocking questions, and permission
prompts; pi supplies lifecycle events when work settles. `agent-notify` turns
both into macOS banners tagged with the tmux target of the sending pane. A
machine with no GUI ships its banners over ssh to one that has — no daemon, no
open port, no sshd configuration on either end.

```
┌─────────────────────┐        ┌──────────────────────────┐
│ headless box        │  ssh   │ the Mac you sit at       │
│ Stop hook           │ ─────► │ agent-notify --recv      │
│ agent-notify        │        │ → banner → click         │
└─────────────────────┘        │ → tmux-focus (local tab) │
           ▲                   └──────────┬───────────────┘
           └──────────── ssh ─────────────┘
             tmux-focus, on its own tmux
```

## Install

```bash
git clone https://github.com/ericboehs/agent-notify ~/Code/agent-notify
cd ~/Code/agent-notify && ./install.sh
```

That symlinks the scripts into `~/bin`, builds the notifier app bundle, and
prints the hook configuration to add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop":         [{ "hooks": [{ "type": "command", "command": "$HOME/bin/agent-notify" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "$HOME/bin/agent-notify" }] }],
    "PreToolUse":   [{ "matcher": "AskUserQuestion",
                       "hooks": [{ "type": "command", "command": "$HOME/bin/agent-notify" }] }]
  }
}
```

To click a banner through to its pane, `.zshrc` has to tell the far end which pane
an ssh session came from. See [Clicking through, two hops](#clicking-through-two-hops).

## Pi (the pi coding agent)

The same backend also drives notifications for [pi](https://pi.dev). Instead of a
hook, pi loads an extension (`extensions/pi-notify.ts`) that turns pi lifecycle
events into the canonical `agent-notify --event` envelope, so tmux targeting,
visible-pane suppression, forwarding, Slack, and click-through all work exactly as
they do for Claude Code.

Build the branded `Pi Notify.app` bundle alongside the Claude one:

```bash
cd ~/Code/agent-notify && ./install.sh --pi
```

Then install the extension as a pi package (pins to the current commit):

```bash
pi install git:github.com/ericboehs/agent-notify
```

or load it from a checkout for development:

```bash
pi -e ~/Code/agent-notify/extensions/pi-notify.ts
```

or symlink it in, so every session picks it up and edits to the checkout are live:

```bash
ln -s ~/Code/agent-notify/extensions/pi-notify.ts ~/.pi/agent/extensions/
ln -s ~/Code/agent-notify/extensions/pi-1p-notify.ts ~/.pi/agent/extensions/
```

The second extension is the 1Password labeller — pi's stand-in for the hook
Claude Code uses. See [Naming the 1Password prompt](#naming-the-1password-prompt).

The extension is deliberately a single file so that last one works: pi resolves
an extension's relative imports against the symlink path, not its target, so a
helper module next to it in the checkout would not be found.

Installed by symlink the extension cannot see the checkout it came from, so it
looks for the backend at `~/bin/agent-notify` (what `install.sh` creates). If it
lives somewhere else, point `AGENT_NOTIFY_BIN` at it.

The extension announces on `agent_settled` — pi's authoritative terminal
watermark, which already accounts for retries, compaction recovery, and queued
follow-ups. It stays quiet while [`pi-background-tasks`](https://github.com/ismailsaleekh/pi-background-tasks)
or [`pi-subagents`](https://github.com/nicobailon/pi-subagents) report active work,
since that work's own completion wakes a later turn that settles and announces.
No hook configuration is needed for pi.

Pi banners post through `Pi Notify.app` and use a `pi-` notification group, so pi
and Claude notifications carry distinct icons and never replace each other on the
same pane.

## Herdr

No additional agent configuration is needed inside Herdr. It injects
`HERDR_PANE_ID` and `HERDR_SOCKET_PATH` into every managed pane; the backend
captures those values when it posts a banner. Clicking runs `herdr-focus`, which
asks that original Herdr session to focus the exact agent pane and then raises
Ghostty. The stable pane ID survives tab and workspace switches.

Notifications for the pane already selected in a frontmost Ghostty stay quiet,
just as visible tmux panes do. Set `AGENT_NOTIFY_WHEN_VISIBLE=true` to override
that behavior for a test.

Herdr's own system delivery and agent-notify are independent and will both post
while both are enabled. Once agent-notify is verified as the notification owner,
avoid duplicates with:

```toml
[ui.toast]
delivery = "off"
```

## Naming the 1Password prompt

1Password's authorization dialog is system-modal and says only that `op` wants in
— not which agent asked, or what it wants. With several agent panes running there
is nothing to approve on sight. `bin/agent-1p-notify` fires a banner naming both
just *before* the command runs, so it lands next to the Touch ID prompt, and
clicking it focuses the pane that asked.

Claude Code calls it as a `PreToolUse(Bash)` hook:

```json
"PreToolUse": [
  { "matcher": "Bash",
    "hooks": [{ "type": "command", "command": "$HOME/bin/agent-1p-notify",
                "timeout": 5, "async": true }] }
]
```

pi has no hooks, so `extensions/pi-1p-notify.ts` is the equivalent: it watches
`tool_call` for the bash tool, which fires before the command runs, and hands the
command to the same script. Both agents therefore agree on what counts as an `op`
invocation — `op` in command position anywhere in the pipeline, minus the few
subcommands (`--version`, `completion`, …) that unlock nothing.

The banner names what is being asked for, whether that is an item title or a
secret reference, and summarises past three (`Personal/EG4/api-key + P/a/b +1
more`). Its title says *who* is asking — the session name and the tmux pane, e.g.
`solar · code:6.0` — because that is the question the modal cannot answer: with
four agents running, "op wants in" names none of them. Both agents get this: the
pane travels as a `label_suffix` on the payload, which `agent-notify` appends to
whatever it ends up calling the session, and drops when the label is already
those coordinates. Clicking still lands on that pane.

Slack gets a copy only while you are away (display asleep, or someone driving the
Mac over VNC). The dialog also takes a typed password, so over VNC it really is
answerable, and a prompt that times out unseen has to be re-triggered by asking
the agent to try again. Item titles reach a channel in that case and no other;
`AGENT_NOTIFY_SLACK=false` silences it entirely.

Every request is logged to `~/.agent-notify/1p-requests.log` (agent, pane, item),
which answers "what did that prompt an hour ago want?" after the fact. Titles
only; the script never sees a secret value.

## The pieces

| | |
|---|---|
| `bin/agent-notify` | Reads the hook payload, decides whether to post, routes it locally or over ssh |
| `bin/agent-1p-notify` | Turns an `op` invocation into a banner naming the agent and the item it wants |
| `bin/tmux-focus` | Spends a tmux address: selects the pane, its window, and its Ghostty tab |
| `bin/herdr-focus` | Spends a Herdr address: focuses the agent pane through its session socket |
| `bin/agent-notify-app` | Builds `~/Applications/Claude Code Notify.app`, the bundle that can receive a click |

## What stays quiet

Four things post nothing at all.

**A pane you are already watching.** If the terminal is frontmost and the source
pane is selected in Herdr — or its tmux window and terminal tab are both selected
— a banner would be describing the screen you are looking at. Every check has to
agree before it stays quiet: a failed state lookup, denied Accessibility grant,
sleeping display, or pane on another machine all mean "cannot tell", which posts.
`AGENT_NOTIFY_WHEN_VISIBLE=true` turns the suppression off.

A screen someone is reading counts even when it is not this one: a client with
terminal focus showing the pane (below) suppresses the banner too, because a
notification about a reply being read on an iPad is a banner nobody is at the
Mac to dismiss, and they stack up until whoever it was walks back to the desk.
That check runs first, being both cheaper and better evidence — the terminal
says it holds keyboard focus, rather than us inferring it through Accessibility.

A forwarded notification splits the question in two, because neither machine can
answer both halves. The sending box says whether the pane was on top of its own
tmux and puts that in the payload; the Mac says whether the tab holding that ssh
session is the one in front. Only if both agree does the banner stay unsent.

**A pane somebody is reading over ssh.** Slack is the away channel, and away has
one more shape than a dark display: on the couch with the iPad, reading the same
tmux through Blink. Terminals report keyboard focus with DEC private mode 1004,
and Blink sends focus-out as iOS backgrounds it and focus-in on return; with
`focus-events on`, tmux carries that as the client's `focused` flag. So at notify
time — polled, not hooked, which is stateless and race-free — the notification is
dropped when a client attached to the pane's session says it has focus *and* the
pane is the active one of the active window. Both halves matter: in testing,
Blink was focused while the session sat on window 3 and the agent was working in
window 6, and focus alone would have swallowed a ping nobody could see.

The connection is not the signal. An iOS background leaves the ssh socket and
the tmux client attached the whole time; only the focus flag moves.

A *local* terminal's flag is only believed while this machine is not away.
Nothing tells Ghostty that the display went dark, so it stays `focused` for as
long as it was the frontmost window — a laptop left with an agent pane on top
and the lid shut would otherwise never Slack again, which is the one case the
away channel exists for. `who` names the host an ssh login came from and leaves
local ttys bare, which is the cheap way to tell a screen in the room from the one
that went to sleep. Everything else fails open: no tmux, no pane, a `who` that
says nothing, and the post goes out. `AGENT_NOTIFY_SLACK_WHEN_WATCHED=true`
turns the Slack half of the suppression off and `AGENT_NOTIFY_WHEN_VISIBLE=true`
the banner half; each knob stays with the thing it governs. Like the other Slack
policy it travels in a forwarded payload — only the machine running the agent can
see its own tmux, so it answers the question as `watched` and the Mac takes its
word, for the banner as much as for Slack.

**Permission prompts.** Claude Code fires its `Notification` event for approvals,
but the payload names no tool — just "Claude needs your permission" — and it lands
moments after the `AskUserQuestion` banner that *does* say what is being asked.
They share a group, so the vague one replaced the useful one. Off by default;
`AGENT_NOTIFY_PERMISSION=true` brings it back.

**A session still waiting on its own agents.** A turn that ends while background
agents are still running is the session waiting, not finishing — and each of those
agents wakes it again on its way out, so one `/pr-review-toolkit:review-pr`
fanning out to six reviewers drew six banners, none of which was the review.
Claude wakes a session by queueing a `<task-notification>` carrying the tool_use
id of the call that started the task, so the ids launched since the last thing you
typed, minus the ids already reported back, is what is still out there. Zero of
them means the work is genuinely over, and that turn gets the banner.

Any other announcer that fires on `Stop` wants the same count, so it is available
on its own:

```bash
agent-notify --pending-tasks ~/.claude/projects/<project>/<session>.jsonl
```

## Forwarding from a headless machine

A box with no GUI has nowhere to draw a banner. Set `AGENT_NOTIFY_FORWARD` on it
and `agent-notify` ships the notification to a machine that does, over ssh:

```bash
AGENT_NOTIFY_HOST=coop AGENT_NOTIFY_SLACK=false \
  AGENT_NOTIFY_FORWARD=e14,e14-wifi $HOME/bin/agent-notify
```

`AGENT_NOTIFY_HOST` prefixes the label, so banners read `coop:code:1.0`. The
forward list is tried in order until one connection succeeds — a wired address
and a wireless one for the same laptop is the useful pairing.

On the receiving Mac, restrict the key to exactly the one thing it may do:

```
restrict,command="/Users/you/bin/agent-notify --recv" ssh-ed25519 AAAA… notify@coop
```

A forced command inherits no environment, which is why `--recv` re-exports a PATH
and why the Slack knobs travel *in the payload*: set `AGENT_NOTIFY_SLACK`,
`AGENT_NOTIFY_SLACK_AWAY_ONLY` and `AGENT_NOTIFY_SLACK_WHEN_WATCHED` on the
machine Claude runs on, not on the Mac. Whether anyone is around to see a banner
stays the receiver's question, since it is the only one that can measure it —
except for who is reading the sender's own tmux, which only the sender can see,
so that answer rides along as `watched`.

`restrict` is carrying weight here, not decoration: it refuses a pty, port
forwarding, agent forwarding and the rest, and `command=` replaces whatever the
client asked to run — so a machine holding only this key cannot get a shell on the
Mac, which is what makes it safe to point at a box running work you do not trust.
What such a box can still do is hand arbitrary JSON to that one command, so
nothing on the path from payload to click is assembled by string interpolation:
the click action is quoted field by field with `printf %q`, `tmux-focus`
allowlists the host and target of the second hop before either reaches a command
line, and both AppleScript blocks take their input through `on run argv`.

### Clicking through, two hops

A forwarded banner has to walk further than a local one: first to whatever holds
the ssh session on the Mac, then to the pane running the agent on the far side.
`tmux-focus` takes both, and the local half comes in one of two shapes.

**The ssh runs inside a tmux pane.** `.zshrc` exports
`LC_AGENT_NOTIFY_PANE=$TMUX_PANE`, which rides along on ssh's stock
`SendEnv LANG LC_*` and is accepted by sshd's stock `AcceptEnv LANG LC_*` —
nothing to configure. On arrival `.zshrc` records it per-tty, because the value a
tmux *server* inherited names whichever pane started it, possibly days ago:

```bash
if [[ -n $SSH_TTY ]]; then
  agent_notify_origin=${LC_AGENT_NOTIFY_PANE:-${LC_CLAUDE_PANE:-}}
  mkdir -p ~/.agent-notify/origin ~/.claude/origin
  if [[ -n $agent_notify_origin ]]; then
    print -r -- "$agent_notify_origin" > ~/.agent-notify/origin/${SSH_TTY//\//-}
    print -r -- "$agent_notify_origin" > ~/.claude/origin/${SSH_TTY//\//-}
  else
    rm -f ~/.agent-notify/origin/${SSH_TTY//\//-} ~/.claude/origin/${SSH_TTY//\//-}
  fi
  unset agent_notify_origin
elif [[ -n $TMUX_PANE ]]; then
  export LC_AGENT_NOTIFY_PANE=$TMUX_PANE
  export LC_CLAUDE_PANE=$TMUX_PANE
fi
```

`LC_AGENT_NOTIFY_PANE` and `~/.agent-notify/origin` are canonical. The legacy
variable and state file are mirrored during migration so older installations keep
working; `agent-notify` prefers the new names but accepts either.

The `else` branch matters: a login with no pane to declare has to *erase* the last
one's answer, not merely decline to write. Ttys get reused, so `/dev/pts/0` keeps
whatever an earlier connection left there, and a stale id is live and wrong. When
the attached client never registered one, `agent-notify` reports no pane at all
rather than that stale id — a click that lands confidently on an unrelated pane
is worse than one that falls through to the tab match below.

**The ssh runs in a plain terminal tab.** There is no pane to select, and wrapping
it in a local tmux purely to invent one would nest a tmux inside a tmux. Instead
the click addresses the tab by title — Ghostty titles a bare tab with its command
line, so `tab:ssh coop` finds it, and `tmux-focus` skips its tmux half entirely:

```bash
tmux-focus 'tab:ssh coop' Ghostty coop:code:1.0
```

Either way the second hop is the same: ssh back to the far machine and run
`tmux-focus` there against its own tmux, so the right window is already selected
by the time the tab comes forward. It is backgrounded, so a sleeping box delays
nothing locally.

## Banner icon

macOS reads a notification's icon and name off the bundle that posted it and
ignores `terminal-notifier -appIcon`, so out of the box every banner wears the
generic Terminal icon. `agent-notify-app` (run by `install.sh`) builds a small
app at `~/Applications/Claude Code Notify.app` from `lib/agent-notifier.swift`,
carrying your terminal's icon and its own bundle id — banners then show the ghost,
and the app gets its own row in System Settings › Notifications instead of hiding
under "terminal-notifier".

Building one rather than dressing up `terminal-notifier` is what makes a click
work at all. `terminal-notifier` posts through `NSUserNotification`, deprecated
long ago and finally inert on macOS 26: the banner still appears, but the click
never comes back, so `-execute` runs nothing and there is no way to reach the
pane. `agent-notifier` posts through `UserNotifications` instead and answers
`didReceive` by running the command. The `terminal-notifier` CLI stays as a
fallback, but all it can do is put a banner on screen.

The first banner triggers a one-time macOS authorization prompt; allow it. Re-run
`agent-notify-app` to point at a different terminal:

```bash
AGENT_NOTIFY_TERMINAL=iTerm agent-notify-app
```

### Letting a click reach the tab

Selecting the tmux pane needs no permission. Clicking the terminal *tab* it lives
in does, because that goes through the accessibility API — so the first click asks
to control your computer, and until you allow **Claude Code** under System Settings
› Privacy & Security › Accessibility, clicks land on the right pane inside the
wrong tab.

Worth knowing when that starts happening again for no apparent reason: the app is
ad-hoc signed, macOS ties the grant to the signature, and every rebuild produces a
new one. The stale grant is then unsatisfiable, and TCC answers no *without* asking
again. So `agent-notify-app` ends by dropping both grants —

```bash
tccutil reset Accessibility com.ericboehs.agent-notify
tccutil reset AppleEvents   com.ericboehs.agent-notify
```

— trading one fresh prompt for a permission that silently no longer works.

Banners also carry a thumbnail on the right, which splits the two questions: the
left icon says *which terminal*, the thumbnail says *what it wants*:

| Thumbnail | Event |
|-----------|-------|
| Claude glyph | `Stop` — done, nothing owed |
| Question mark | `AskUserQuestion` — blocked until you pick an option |
| 1Password key | an unlock prompt that names neither pane nor item |

So a banner that needs an *answer* is distinguishable from one that is merely
finished without reading the text. Override per-call with
`AGENT_NOTIFY_IMAGE=/path/to/icon` (`.icns` works as-is, and an explicit value
beats the per-event defaults), or set it empty to drop the thumbnail.

The question mark is rendered from the `questionmark.circle.fill` SF Symbol into
the app bundle by `agent-notify-app`, via `lib/render-symbol.js` — JXA rather
than something needing installation, since the ObjC bridge ships on every Mac and
PyObjC does not. Retint or restyle it there:

```bash
osascript -l JavaScript lib/render-symbol.js exclamationmark.triangle.fill out.png D97757
```

## Costing the turn nothing

Claude holds a turn open until its hook exits, so every second the banner spends
being drawn is a second the session still looks busy. A stop forwarded from a
headless box was spending six of them.

Most of that was waiting for text. A banner wants the last thing Claude said, and
that used to mean tailing the transcript until the message landed — Claude appends
it *after* firing the hook, so reading immediately hands back the turn before last.
The `Stop` payload carries `last_assistant_message`, which is the same answer for
nothing. The transcript wait survives as a fallback for payloads without the field,
and now ends as soon as the turn's last message has landed: once anything newer
than the user side is there, a message with no text means none is coming, and the
remaining tenths were being spent confirming it.

What is left is the ssh out to a machine with a screen, which nothing makes
instant. So the hook hands the payload to a detached copy of itself and exits —
the turn ends, and the banner arrives a moment later on its own. Only `--recv`
stays in the foreground, since the ssh that invoked it wants its exit status.

## When a banner is late

A banner crosses two machines before anyone sees it, so "it showed up late" has
several possible authors: the hook firing late, the wait for the reply text, the
ssh, or macOS sitting on a notification it was handed promptly. Timestamping the
stages settles which, and costs nothing when nobody is asking:

```bash
touch ~/.agent-notify-debug     # on either machine, or both
tail -f ~/.agent-notify-debug   # hook entry, forward, draw, suppression
rm ~/.agent-notify-debug        # stop
```

## Environment

| Variable | Effect |
|---|---|
| `AGENT_NOTIFY_FORWARD` | Comma-separated hosts to ship banners to; tried in order until one connects |
| `AGENT_NOTIFY_HOST` | Prefix the session label, so banners read `coop:code:1.0` |
| `AGENT_NOTIFY_TERMINAL` | Which terminal a click should raise (default `Ghostty`) |
| `AGENT_NOTIFY_WHEN_VISIBLE` | Post even for a pane you are already looking at, or one a focused tmux client is showing |
| `AGENT_NOTIFY_PERMISSION` | Bring the vague permission notifications back |
| `AGENT_NOTIFY_IMAGE` | Override the banner thumbnail; empty drops it |
| `AGENT_NOTIFY_SLACK` | Post to Slack as well as the desktop; travels in the forwarded payload |
| `AGENT_NOTIFY_SLACK_AWAY_ONLY` | Slack only when away — display asleep or a VNC session — measured by the receiver (old name: `AGENT_NOTIFY_SLACK_SLEEP_ONLY`) |
| `AGENT_NOTIFY_SLACK_WHEN_WATCHED` | Slack even when a tmux client with terminal focus is showing the pane (an iPad on Blink counts); travels in the forwarded payload. Banners have their own knob above |
| `AGENT_NOTIFY_BIN` | (pi) Explicit path to the `agent-notify` backend, overriding autodiscovery |
| `AGENT_1P_NOTIFY_BIN` | (pi) Explicit path to `agent-1p-notify`, overriding autodiscovery |
| `AGENT_NOTIFY_1P_LOG` | Where 1Password requests are logged (default `~/.agent-notify/1p-requests.log`) |
| `AGENT_NOTIFY_1P_IMAGE` | Thumbnail for a 1Password banner; empty drops it |
| `AGENT_NOTIFY_APP_NAME` | App-bundle name to post through (default `Claude Code` → `Claude Code Notify.app`; the pi extension sets `Pi` → `Pi Notify.app`) |
| `AGENT_NOTIFY_EMOJI` | (pi) Slack header emoji for pi banners (default `:robot_face:`) |
| `LC_AGENT_NOTIFY_PANE` | Origin tmux pane forwarded over SSH; `LC_CLAUDE_PANE` remains a compatibility alias |

## Requirements

- macOS on the machine that draws banners (the sending box can be anything with bash)
- Claude Code
- Herdr or tmux for click-through to a pane (tmux also needs `focus-events on` for the watched check)
- `jq`
- Xcode command line tools (`xcrun swiftc`), to build the notifier app
- `terminal-notifier`, as a fallback when the app bundle is missing
- `slack-noti` (optional), only for the Slack path

## License

MIT
