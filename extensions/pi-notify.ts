// pi-notify: desktop + Slack notifications for the pi coding agent.
//
// This is the pi-side producer for the claude-notify backend. It translates pi
// lifecycle events into the canonical `claude-notify --event` envelope and lets
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

import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import {
  assistantText,
  bodiesFor,
  buildEnvelope,
  findNotifier,
  isRecord,
  notifierEnv,
  type NotifyEvent,
} from "./lib/payload.ts";

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
  const bin = findNotifier(import.meta.url);
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
