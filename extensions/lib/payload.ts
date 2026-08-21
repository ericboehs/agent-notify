// Pure helpers for pi-notify, split out so they can be unit-tested without the
// pi runtime. No imports from @earendil-works/* here: everything is plain data
// in, plain data out, plus filesystem probing for the backend binary.

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const BODY_MAX = 400;
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

export function condense(text: string): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  return oneLine.length > BODY_MAX ? `${oneLine.slice(0, BODY_MAX - 1)}…` : oneLine;
}

// The banner wants the answer, not the whole reply. A model that ends every turn
// with a "Next steps" block (or any other standing instruction) would otherwise
// push the actual result off the two lines macOS gives us. The first paragraph is
// the general rule that handles it without pattern-matching anyone's prose.
export function firstParagraph(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return "";
  const [first] = trimmed.split(/\n[ \t]*\n/);
  return (first ?? trimmed).trim();
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
  const banner = condense(firstParagraph(text));
  const slack = clampForSlack(text);
  // No point shipping a duplicate when the reply was a single paragraph.
  return { message: banner, slackMessage: slack === banner ? "" : slack };
}

// Compute the environment overrides for the backend given the caller env. Kept
// pure (env in, env out) so the branching is testable.
export function notifierEnv(
  event: NotifyEvent,
  base: NodeJS.ProcessEnv,
): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...base,
    CLAUDE_NOTIFY_APP_NAME: base.AGENT_NOTIFY_APP_NAME || "Pi",
  };
  if (base.AGENT_NOTIFY_EMOJI) env.AGENT_NOTIFY_EMOJI = base.AGENT_NOTIFY_EMOJI;
  // Drop the Claude-branded default thumbnail for plain completions unless the
  // user pinned one. Question/attention banners leave it unset so the backend
  // can apply its own question glyph.
  if (
    event === "settled" &&
    base.CLAUDE_NOTIFY_IMAGE === undefined &&
    base.AGENT_NOTIFY_IMAGE === undefined
  ) {
    env.CLAUDE_NOTIFY_IMAGE = "";
  } else if (base.AGENT_NOTIFY_IMAGE !== undefined) {
    env.CLAUDE_NOTIFY_IMAGE = base.AGENT_NOTIFY_IMAGE;
  }
  return env;
}

// Resolve the claude-notify backend. Prefer an explicit override, then the copy
// shipped alongside this extension (git checkout or installed pi package), then
// the conventional ~/bin symlink. `moduleUrl` is import.meta.url of the caller.
export function findNotifier(moduleUrl?: string): string | undefined {
  const override = process.env.AGENT_NOTIFY_BIN;
  if (override && existsSync(override)) return override;

  if (moduleUrl) {
    try {
      const here = dirname(new URL(moduleUrl).pathname);
      // extensions/lib/../../bin/claude-notify when called from the extension,
      // which imports this module from extensions/lib/payload.ts.
      const sibling = join(here, "..", "..", "bin", "claude-notify");
      if (existsSync(sibling)) return sibling;
      const flat = join(here, "..", "bin", "claude-notify");
      if (existsSync(flat)) return flat;
    } catch {
      // Malformed URL under some loaders; fall through.
    }
  }

  const inBin = join(homedir(), "bin", "claude-notify");
  if (existsSync(inBin)) return inBin;

  return undefined;
}
