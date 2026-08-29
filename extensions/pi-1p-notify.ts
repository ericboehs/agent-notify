// pi-1p-notify: name the 1Password dialog pi just raised.
//
// pi has no hook config, so the PreToolUse(Bash) hook Claude Code uses to label
// 1Password's unlock prompt has no equivalent here — this extension is it. It
// watches `tool_call` for the bash tool, which fires before the command runs,
// and hands the command to bin/agent-1p-notify. That script owns the decision
// (is this really an `op` invocation, and what is it asking for?) so pi and
// Claude cannot drift apart on what counts.
//
// Deliberately one file, for the same reason as pi-notify.ts: installed by
// symlink into ~/.pi/agent/extensions, a relative import would resolve against
// that directory rather than the checkout, and a helper module next door would
// simply not be found.

import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

// ---------------------------------------------------------------------------
// Pure helpers (exported for the tests)
// ---------------------------------------------------------------------------

// A deliberately loose prefilter, and only a cost saver: without it every single
// bash tool call would spawn a shell and two jq processes to be told "no `op`
// here". Anything this lets through is decided properly by agent-1p-notify,
// which is the one place that knows which invocations raise the dialog. It has
// to stay a strict superset of that decision — the script's own pattern requires
// `op` followed by whitespace, so a substring test cannot be narrower.
export function mightRunOnePassword(command: string): boolean {
  return command.includes("op ");
}

export interface OnePasswordRequest {
  agent: "pi";
  command: string;
  session_id: string;
  session_name: string;
  cwd: string;
}

export function buildRequest(input: {
  command: string;
  sessionId?: string;
  sessionName?: string;
  cwd: string;
}): OnePasswordRequest {
  return {
    agent: "pi",
    command: input.command,
    session_id: input.sessionId ?? "",
    session_name: input.sessionName ?? "",
    cwd: input.cwd,
  };
}

// Where this file sits on disk, or undefined when the loader will not say. pi
// may evaluate an extension as CommonJS, where `import.meta` is a parse error
// rather than a catchable one, so ask for `__filename` instead — defined under
// CJS, a ReferenceError under ESM, which the catch turns into an honest
// "unknown". See the same note in pi-notify.ts.
export function selfPath(): string | undefined {
  try {
    return typeof __filename === "string" ? __filename : undefined;
  } catch {
    return undefined;
  }
}

// Resolve the labelling script: an explicit override, then the copy shipped
// alongside this extension, then the ~/bin symlink install.sh creates.
export function findOnePasswordNotifier(from?: string): string | undefined {
  const override = process.env.AGENT_1P_NOTIFY_BIN;
  if (override && existsSync(override)) return override;

  if (from) {
    const sibling = join(dirname(from), "..", "bin", "agent-1p-notify");
    if (existsSync(sibling)) return sibling;
  }

  const inBin = join(homedir(), "bin", "agent-1p-notify");
  if (existsSync(inBin)) return inBin;

  return undefined;
}

// pi banners post through "Pi Notify.app" so they carry pi's mark and never
// replace a Claude banner on the same pane. Same default as pi-notify.ts.
export function notifierEnv(base: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return {
    ...base,
    AGENT_NOTIFY_APP_NAME: base.AGENT_NOTIFY_APP_NAME || "Pi",
  };
}

// ---------------------------------------------------------------------------
// pi runtime
// ---------------------------------------------------------------------------

function announce(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  command: string,
): void {
  const bin = findOnePasswordNotifier(selfPath());
  if (!bin) return;

  const request = buildRequest({
    command,
    sessionId: ctx.sessionManager.getSessionId?.() ?? "",
    sessionName: pi.getSessionName() ?? "",
    cwd: ctx.cwd,
  });

  try {
    // Detached and unwaited: the banner wants to land next to the Touch ID
    // prompt, and the tool call must not wait on a notification either way.
    const child = spawn(bin, [], {
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
      env: notifierEnv(process.env),
    });
    child.on("error", () => {});
    child.stdin?.on("error", () => {});
    child.stdin?.end(JSON.stringify(request));
    child.unref();
  } catch {
    // Never let a notification failure surface inside pi.
  }
}

export default function (pi: ExtensionAPI): void {
  // Only the interactive session announces. A subagent or a headless run raises
  // the same dialog, but nobody is sitting in front of those panes to answer it.
  let active = false;

  pi.on("session_start", (_event, ctx) => {
    active = ctx.mode === "tui";
  });

  pi.on("tool_call", (event, ctx) => {
    if (!active || event.toolName !== "bash") return;
    const command = (event.input as { command?: unknown }).command;
    if (typeof command !== "string" || !mightRunOnePassword(command)) return;
    announce(pi, ctx, command);
  });

  pi.on("session_shutdown", () => {
    active = false;
  });
}
