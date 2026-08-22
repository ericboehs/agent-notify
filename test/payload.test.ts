// Unit tests for the pure pi-notify helpers.
// Run: node --test test/*.test.ts   (Node 23.6+ strips TypeScript types natively)

import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  assistantText,
  bodiesFor,
  BODY_MAX,
  buildEnvelope,
  clampForSlack,
  condense,
  findNotifier,
  notifierEnv,
  SLACK_MAX,
} from "../extensions/pi-notify.ts";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

test("assistantText reads a plain string body", () => {
  assert.equal(
    assistantText({ role: "assistant", content: "  hello  " }),
    "hello",
  );
});

test("assistantText joins only text parts", () => {
  const message = {
    role: "assistant",
    content: [
      { type: "text", text: "one " },
      { type: "tool_use", id: "x" },
      { type: "text", text: "two" },
    ],
  };
  assert.equal(assistantText(message), "one two");
});

test("assistantText ignores non-assistant roles and junk", () => {
  assert.equal(assistantText({ role: "user", content: "hi" }), "");
  assert.equal(assistantText(null), "");
  assert.equal(assistantText({ role: "assistant", content: 42 }), "");
});

test("condense flows text into one line and bounds it only for transport", () => {
  assert.equal(condense("a\n\n  b\t c "), "a b c");
  // A reply far longer than a banner can show still travels whole - Notification
  // Center decides where to stop, which is the entire point of the large bound.
  const realistic = "x".repeat(600);
  assert.equal(condense(realistic), realistic);
  const huge = "x".repeat(BODY_MAX + 200);
  const out = condense(huge);
  assert.equal(out.length, BODY_MAX);
  assert.ok(out.endsWith("…"));
});

test("buildEnvelope fills defaults and pins version/agent", () => {
  const env = buildEnvelope({ event: "settled", message: "done", cwd: "/p" });
  assert.deepEqual(env, {
    version: 1,
    agent: "pi",
    event: "settled",
    session_id: "",
    session_name: "",
    cwd: "/p",
    message: "done",
    slack_body: "",
  });
});

test("clampForSlack preserves newlines and bounds length", () => {
  const listy = "pong\n\nNext steps:\n1. a\n2. b";
  assert.equal(clampForSlack(listy), listy);
  const huge = "y".repeat(SLACK_MAX + 200);
  const out = clampForSlack(huge);
  assert.equal(out.length, SLACK_MAX);
  assert.ok(out.endsWith("\u2026"));
});

test("bodiesFor sends the whole reply to the banner, flowed into one line", () => {
  // The exact shape Eric's AGENTS.md produces: answer, then a Next steps block.
  // Both belong on the banner - Notification Center decides how much fits.
  const reply = "pong\n\nNext steps:\n1. Run a health check\n2. Pick a task";
  const { message, slackMessage } = bodiesFor(reply);
  assert.equal(message, "pong Next steps: 1. Run a health check 2. Pick a task");
  assert.equal(slackMessage, reply);
});

test("bodiesFor omits a duplicate Slack body for single-paragraph replies", () => {
  const { message, slackMessage } = bodiesFor("just this");
  assert.equal(message, "just this");
  assert.equal(slackMessage, "");
});

test("bodiesFor returns empty bodies for empty text", () => {
  assert.deepEqual(bodiesFor("  \n "), { message: "", slackMessage: "" });
});

test("notifierEnv leaves the thumbnail to the backend for settled banners", () => {
  // Setting it here at all - even to empty - would read as the caller pinning an
  // image, and suppress the pi mark the backend would otherwise supply.
  const env = notifierEnv("settled", {});
  assert.equal(env.CLAUDE_NOTIFY_APP_NAME, "Pi");
  assert.ok(!("CLAUDE_NOTIFY_IMAGE" in env));
});

test("notifierEnv keeps the image unset for question banners", () => {
  const env = notifierEnv("question", {});
  assert.equal(env.CLAUDE_NOTIFY_IMAGE, undefined);
});

test("notifierEnv honours AGENT_NOTIFY_APP_NAME and AGENT_NOTIFY_IMAGE overrides", () => {
  const env = notifierEnv("settled", {
    AGENT_NOTIFY_APP_NAME: "MyAgent",
    AGENT_NOTIFY_IMAGE: "/tmp/icon.png",
  });
  assert.equal(env.CLAUDE_NOTIFY_APP_NAME, "MyAgent");
  assert.equal(env.CLAUDE_NOTIFY_IMAGE, "/tmp/icon.png");
});

test("findNotifier resolves the backend shipped alongside the extension", () => {
  const prev = process.env.AGENT_NOTIFY_BIN;
  delete process.env.AGENT_NOTIFY_BIN;
  try {
    const resolved = findNotifier(join(repoRoot, "extensions", "pi-notify.ts"));
    assert.equal(resolved, join(repoRoot, "bin", "claude-notify"));
  } finally {
    if (prev !== undefined) process.env.AGENT_NOTIFY_BIN = prev;
  }
});

test("findNotifier does not invent a sibling that is not there", () => {
  // What a symlink install looks like from inside the loader: it reports the
  // link path, and ../bin under it does not exist. The fallback may legitimately
  // find ~/bin/claude-notify; what it must never do is answer from a directory
  // it never confirmed.
  const prev = process.env.AGENT_NOTIFY_BIN;
  delete process.env.AGENT_NOTIFY_BIN;
  try {
    const resolved = findNotifier("/nonexistent/extensions/pi-notify.ts");
    assert.ok(resolved === undefined || !resolved.startsWith("/nonexistent"));
  } finally {
    if (prev !== undefined) process.env.AGENT_NOTIFY_BIN = prev;
  }
});

test("findNotifier honours AGENT_NOTIFY_BIN when the path exists", () => {
  const bin = join(repoRoot, "bin", "claude-notify");
  const prev = process.env.AGENT_NOTIFY_BIN;
  process.env.AGENT_NOTIFY_BIN = bin;
  try {
    assert.equal(findNotifier(undefined), bin);
  } finally {
    if (prev === undefined) delete process.env.AGENT_NOTIFY_BIN;
    else process.env.AGENT_NOTIFY_BIN = prev;
  }
});
