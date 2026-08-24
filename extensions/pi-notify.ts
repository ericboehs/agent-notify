// pi-notify: desktop + Slack notifications for the pi coding agent.
//
// This is the pi-side producer for the agent-notify backend. It translates pi
// lifecycle events into the canonical `agent-notify --event` envelope and lets
// the proven shell/Swift backend own tmux targeting, visible-pane suppression,
// SSH forwarding, Slack, macOS banners, and click-through to the origin pane.
//
// Design notes:
//   - Announce on `agent_settled`, the authoritative terminal watermark that
//     accounts for retries, compaction recovery, and queued follow-ups. Never
//     `agent_end`.
//   - Suppress while other work is still running by consulting the two systems
//     Eric actually runs: pi-background-tasks (EventBus status) and pi-subagents
//     (in-process RPC status). Either reporting active work silences the banner;
//     its own completion will wake another turn that settles and announces.
//   - Notification-only background-task completions (notify, no trigger) are
//     announced here, mirroring the tmux-attention extension.
//   - `pi.events` is in-process only, so this never sees other pi processes or
//     child subagents. That is exactly what we want: each session announces for
//     itself.
//
// Deliberately one file. The usual way to install a pi extension is to symlink
// it into ~/.pi/agent/extensions, and pi resolves a relative import against the
// symlink path rather than its target - so a second file next door is simply not
// found. Everything below the pi imports is pure and exported for the tests.

import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

// ---------------------------------------------------------------------------
// Pure helpers (plain data in, plain data out; unit-tested without pi)
// ---------------------------------------------------------------------------

// A banner body is bounded only so a runaway reply does not travel as argv and,
// on a forwarded notification, as JSON over ssh - it is a transport guard, not a
// display decision. Notification Center cuts the text off long before this, and
// it knows how much room it has; guessing on its behalf here only threw away
// words it would have shown.
export const BODY_MAX = 2000;
// Slack renders the whole reply, so it gets a far larger bound than a banner and
// keeps its line breaks. Still bounded: a runaway reply should not become a wall
// of text in a shared channel.
export const SLACK_MAX = 1500;

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Best-effort text of an assistant message. Content is either a plain string or
// an array of parts; only `text` parts contribute to a banner body.
export function assistantText(message: unknown): string {
  if (!isRecord(message)) return "";
  if (message.role !== "assistant") return "";
  const content = message.content;
  if (typeof content === "string") return content.trim();
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const part of content) {
    if (isRecord(part) && part.type === "text" && typeof part.text === "string") {
      parts.push(part.text);
    }
  }
  return parts.join("").trim();
}

// Keep the reply's own shape. Notification Center honours line breaks, so a
// verse stays a verse and a list stays a list; flowing it all into one paragraph
// was a guess at what would fit, and guessing about the available room is the
// thing this code should stop doing. Only the length is bounded.
export function clampForBanner(text: string): string {
  const trimmed = text.trim();
  return trimmed.length > BODY_MAX ? `${trimmed.slice(0, BODY_MAX - 1)}…` : trimmed;
}

// Slack body: keep the line breaks that make a list a list, bound the length.
export function clampForSlack(text: string): string {
  const trimmed = text.trim();
  return trimmed.length > SLACK_MAX ? `${trimmed.slice(0, SLACK_MAX - 1)}…` : trimmed;
}

export type NotifyEvent = "settled" | "question" | "attention";

export interface EnvelopeInput {
  event: NotifyEvent;
  message: string;
  slackMessage?: string;
  sessionId?: string;
  sessionName?: string;
  cwd: string;
}

export interface Envelope {
  version: 1;
  agent: "pi";
  event: NotifyEvent;
  session_id: string;
  session_name: string;
  cwd: string;
  message: string;
  slack_body: string;
}

export function buildEnvelope(input: EnvelopeInput): Envelope {
  return {
    version: 1,
    agent: "pi",
    event: input.event,
    session_id: input.sessionId ?? "",
    session_name: input.sessionName ?? "",
    cwd: input.cwd,
    message: input.message,
    // Empty means "nothing extra to say"; the backend falls back to message.
    slack_body: input.slackMessage ?? "",
  };
}

// Split one assistant reply into the two bodies the backend wants.
export function bodiesFor(text: string): { message: string; slackMessage: string } {
  if (!text.trim()) return { message: "", slackMessage: "" };
  const banner = clampForBanner(text);
  const slack = clampForSlack(text);
  // No point shipping a duplicate when the reply was a single paragraph.
  return { message: banner, slackMessage: slack === banner ? "" : slack };
}

// Compute the environment overrides for the backend given the caller env. Kept
// pure (env in, env out) so the branching is testable.
export function notifierEnv(
  _event: NotifyEvent,
  base: NodeJS.ProcessEnv,
): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...base,
    AGENT_NOTIFY_APP_NAME: base.AGENT_NOTIFY_APP_NAME || "Pi",
  };
  if (base.AGENT_NOTIFY_EMOJI) env.AGENT_NOTIFY_EMOJI = base.AGENT_NOTIFY_EMOJI;
  // Leave the thumbnail alone unless the user pinned one. The backend fills in
  // pi's mark for a settled banner and the question glyph for a question, and
  // setting this here - even to empty - reads as the caller pinning an image and
  // suppresses both. `event` stays in the signature because which glyph applies
  // is still an event-shaped question, just one answered further down.
  if (base.AGENT_NOTIFY_IMAGE !== undefined) {
    env.AGENT_NOTIFY_IMAGE = base.AGENT_NOTIFY_IMAGE;
  }
  return env;
}

// Where this file sits on disk, or undefined when the loader will not say.
//
// pi may evaluate an extension as CommonJS - a symlink into ~/.pi/agent/extensions
// resolves against that directory, which carries no "type": "module" - and there
// `import.meta` is a parse error, fatal before any try/catch could run. So this
// asks for `__filename` instead: defined under CJS, a ReferenceError under ESM,
// which the catch turns into an honest "unknown". Callers must cope with
// undefined, which is why AGENT_NOTIFY_BIN exists.
export function selfPath(): string | undefined {
  try {
    return typeof __filename === "string" ? __filename : undefined;
  } catch {
    return undefined;
  }
}

// Resolve the agent-notify backend. Prefer an explicit override, then the copy
// shipped alongside this extension (git checkout or installed pi package), then
// the conventional ~/bin symlink.
export function findNotifier(from?: string): string | undefined {
  const override = process.env.AGENT_NOTIFY_BIN;
  if (override && existsSync(override)) return override;

  if (from) {
    // <checkout>/extensions/pi-notify.ts -> <checkout>/bin/agent-notify.
    // Installed by symlink this lands in ~/.pi/agent/bin, which will not exist,
    // and we fall through to the ~/bin symlink below.
    const sibling = join(dirname(from), "..", "bin", "agent-notify");
    if (existsSync(sibling)) return sibling;
  }

  const inBin = join(homedir(), "bin", "agent-notify");
  if (existsSync(inBin)) return inBin;

  return undefined;
}

// ---------------------------------------------------------------------------
// pi runtime
// ---------------------------------------------------------------------------

// --- background-tasks EventBus (mirrors ~/.pi-agent/extensions/tmux-attention.ts) ---
const BG_REQUEST = "pi-background-tasks:request:v1";
const BG_RESPONSE = "pi-background-tasks:response:v1";
const BG_TERMINAL = "pi-background-tasks:terminal:v1";
const BG_REQUEST_SCHEMA = "pi-background-tasks.extension-request.v1";
const BG_RESPONSE_SCHEMA = "pi-background-tasks.extension-response.v1";
const BG_TERMINAL_SCHEMA = "pi-background-tasks.extension-terminal.v1";
const BG_RESPONSE_TIMEOUT_MS = 250;

// --- pi-subagents in-process RPC ---
const SUB_RPC_REQUEST = "subagents:rpc:v1:request";
const SUB_RPC_REPLY_PREFIX = "subagents:rpc:v1:reply:";
const SUB_RPC_TIMEOUT_MS = 250;

let requestSequence = 0;

interface BackgroundTask {
  status?: unknown;
  notifyOnCompletion?: unknown;
  triggerOnCompletion?: unknown;
}

// True when pi-background-tasks reports at least one running task. Absent
// package => no reply => resolves false within the timeout.
function hasRunningBackgroundTasks(pi: ExtensionAPI): Promise<boolean> {
  const requestId = `pi-notify-${process.pid}-${Date.now()}-${++requestSequence}`;
  return new Promise((resolve) => {
    let finished = false;
    let timer: ReturnType<typeof setTimeout>;
    const finish = (running: boolean) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      off();
      resolve(running);
    };
    const off = pi.events.on(BG_RESPONSE, (value: unknown) => {
      if (!isRecord(value) || value.schema_version !== BG_RESPONSE_SCHEMA) return;
      if (value.request_id !== requestId || value.ok !== true) return;
      if (!isRecord(value.result) || !Array.isArray(value.result.tasks)) return;
      finish(
        value.result.tasks.some(
          (task: BackgroundTask) => isRecord(task) && task.status === "running",
        ),
      );
    });
    timer = setTimeout(() => finish(false), BG_RESPONSE_TIMEOUT_MS);
    try {
      pi.events.emit(BG_REQUEST, {
        schema_version: BG_REQUEST_SCHEMA,
        request_id: requestId,
        operation: "status",
        payload: {},
      });
    } catch {
      finish(false);
    }
  });
}

// True when pi-subagents reports active async runs. Uses the public RPC status
// (fleet.totalActive when advertised). Absent package => no reply => false.
function hasActiveSubagents(pi: ExtensionAPI): Promise<boolean> {
  const requestId = `pi-notify-${process.pid}-${Date.now()}-${++requestSequence}`;
  return new Promise((resolve) => {
    let finished = false;
    let timer: ReturnType<typeof setTimeout>;
    const finish = (active: boolean) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      off();
      resolve(active);
    };
    const off = pi.events.on(`${SUB_RPC_REPLY_PREFIX}${requestId}`, (value: unknown) => {
      if (!isRecord(value) || value.success !== true) return finish(false);
      const data = isRecord(value.data) ? value.data : undefined;
      const fleet = data && isRecord(data.fleet) ? data.fleet : undefined;
      if (fleet && typeof fleet.totalActive === "number") {
        return finish(fleet.totalActive > 0);
      }
      // Older builds without the fleet DTO: treat a present entries array as
      // authoritative, otherwise assume idle.
      if (fleet && Array.isArray(fleet.entries)) {
        return finish(fleet.entries.length > 0);
      }
      finish(false);
    });
    timer = setTimeout(() => finish(false), SUB_RPC_TIMEOUT_MS);
    try {
      pi.events.emit(SUB_RPC_REQUEST, {
        version: 1,
        requestId,
        method: "status",
        params: {},
      });
    } catch {
      finish(false);
    }
  });
}

async function otherWorkRunning(pi: ExtensionAPI): Promise<boolean> {
  const [bg, sub] = await Promise.all([
    hasRunningBackgroundTasks(pi),
    hasActiveSubagents(pi),
  ]);
  return bg || sub;
}

interface NotifyPayload {
  event: NotifyEvent;
  message: string;
  slackMessage?: string;
}

function emit(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  { event, message, slackMessage }: NotifyPayload,
): void {
  const bin = findNotifier(selfPath());
  if (!bin) return;

  const envelope = buildEnvelope({
    event,
    message,
    slackMessage,
    sessionId: ctx.sessionManager.getSessionId?.() ?? "",
    sessionName: pi.getSessionName() ?? "",
    cwd: ctx.cwd,
  });

  const env = notifierEnv(event, process.env);

  try {
    const child = spawn(bin, ["--event"], {
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
      env,
    });
    child.on("error", () => {});
    child.stdin?.on("error", () => {});
    child.stdin?.end(JSON.stringify(envelope));
    child.unref();
  } catch {
    // Never let a notification failure surface inside pi.
  }
}

export default function (pi: ExtensionAPI): void {
  // Only the interactive session should announce for itself. Child subagent
  // processes and non-TUI runners settle too, but they are not what a human is
  // waiting on at a terminal.
  let active = false;
  let lastAssistantText = "";
  let removeTerminalListener: (() => void) | undefined;

  pi.on("session_start", (_event, ctx) => {
    active = ctx.mode === "tui";
    if (!active) return;

    removeTerminalListener?.();
    removeTerminalListener = pi.events.on(BG_TERMINAL, (value: unknown) => {
      if (!isRecord(value) || value.schema_version !== BG_TERMINAL_SCHEMA) return;
      if (!isRecord(value.task)) return;
      const task = value.task as BackgroundTask;
      // A triggering completion wakes another turn; let that turn's
      // agent_settled announce. Only notification-only completions are ours to
      // surface, and only when no other foreground/background work remains.
      if (
        task.notifyOnCompletion !== true ||
        task.triggerOnCompletion === true ||
        !ctx.isIdle()
      ) {
        return;
      }
      void otherWorkRunning(pi).then((running) => {
        if (!running) {
          emit(pi, ctx, {
            event: "settled",
            message: "A background task finished.",
          });
        }
      });
    });
  });

  pi.on("message_end", (event) => {
    if (!active) return;
    const text = assistantText((event as { message?: unknown }).message);
    if (text) lastAssistantText = text;
  });

  pi.on("agent_settled", async (_event, ctx) => {
    if (!active) return;
    // Suppress while other work is still running; its completion will settle a
    // later turn that announces then.
    if (await otherWorkRunning(pi)) return;

    const { message, slackMessage } = bodiesFor(lastAssistantText);
    lastAssistantText = "";
    emit(pi, ctx, { event: "settled", message, slackMessage });
  });

  pi.on("session_shutdown", () => {
    removeTerminalListener?.();
    removeTerminalListener = undefined;
    active = false;
  });
}
