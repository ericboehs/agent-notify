// Unit tests for the pure pi-1p-notify helpers.
// Run: node --test test/*.test.ts   (Node 23.6+ strips TypeScript types natively)

import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  buildRequest,
  findOnePasswordNotifier,
  mightRunOnePassword,
  notifierEnv,
} from "../extensions/pi-1p-notify.ts";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

test("mightRunOnePassword passes anything the script might act on", () => {
  // Every shape agent-1p-notify recognises has to survive the prefilter, or the
  // two disagree and a real unlock goes unlabelled.
  assert.ok(mightRunOnePassword("op read op://P/a/b"));
  assert.ok(mightRunOnePassword("op signin --account my && op item get Foo"));
  assert.ok(mightRunOnePassword("KEY=$(op read op://P/a/b) make deploy"));
  assert.ok(mightRunOnePassword("(op vault list)"));
});

test("mightRunOnePassword drops commands with no op invocation", () => {
  assert.equal(mightRunOnePassword("ls -la"), false);
  assert.equal(mightRunOnePassword("git commit -m 'fix the parser'"), false);
});

test("mightRunOnePassword is allowed to be wrong in the safe direction", () => {
  // "stop the loop" contains "op ". The prefilter exists to save a process
  // spawn, not to decide anything: agent-1p-notify sees this one and says no.
  assert.ok(mightRunOnePassword("git commit -m 'stop the loop'"));
});

test("buildRequest names the agent and fills absent ids with empty strings", () => {
  assert.deepEqual(buildRequest({ command: "op read op://P/a/b", cwd: "/tmp" }), {
    agent: "pi",
    command: "op read op://P/a/b",
    session_id: "",
    session_name: "",
    cwd: "/tmp",
  });
});

test("buildRequest carries the session identity through", () => {
  const request = buildRequest({
    command: "op item get Foo",
    sessionId: "abc",
    sessionName: "solar",
    cwd: "/tmp/proj",
  });
  assert.equal(request.session_id, "abc");
  assert.equal(request.session_name, "solar");
});

test("notifierEnv posts through Pi Notify.app by default", () => {
  assert.equal(notifierEnv({}).AGENT_NOTIFY_APP_NAME, "Pi");
});

test("notifierEnv leaves an explicitly chosen bundle alone", () => {
  assert.equal(
    notifierEnv({ AGENT_NOTIFY_APP_NAME: "Claude Code" }).AGENT_NOTIFY_APP_NAME,
    "Claude Code",
  );
});

test("findOnePasswordNotifier prefers the explicit override", () => {
  const script = join(repoRoot, "bin", "agent-1p-notify");
  process.env.AGENT_1P_NOTIFY_BIN = script;
  try {
    assert.equal(findOnePasswordNotifier(undefined), script);
  } finally {
    delete process.env.AGENT_1P_NOTIFY_BIN;
  }
});

test("findOnePasswordNotifier finds the script beside the extension", () => {
  const from = join(repoRoot, "extensions", "pi-1p-notify.ts");
  assert.equal(
    findOnePasswordNotifier(from),
    join(repoRoot, "extensions", "..", "bin", "agent-1p-notify"),
  );
});
