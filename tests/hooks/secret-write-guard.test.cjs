"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const guard = path.resolve(__dirname, "../../hooks/claude/secret-write-guard.cjs");
const { evaluate, MAX_BYTES } = require(guard);
const event = (tool, input) => ({ hook_event_name: "PreToolUse", tool_name: tool, tool_input: input });
const blocked = value => assert.equal(value.hookSpecificOutput.permissionDecision, "deny");
const fake = "AK" + "IA" + "Z".repeat(16);

test("recognized secret shapes are blocked without leaking content or paths", () => {
  for (const content of [fake, "gh" + "p_" + "z".repeat(36),
    "github_" + "pat_" + "z".repeat(50), "gl" + "pat-" + "z".repeat(20),
    "xox" + "b-" + "z".repeat(24), "-----BEGIN " + "PRIVATE KEY-----"]) {
    const result = evaluate(event("Write", { content, file_path: "private-project-name" }));
    blocked(result);
    assert.ok(!JSON.stringify(result).includes(content));
    assert.ok(!JSON.stringify(result).includes("private-project-name"));
  }
});

test("example suffixes and ignore markers do not exempt a match", () => {
  blocked(evaluate(event("Write", { file_path: ".env.example", content: fake + " # scan-secrets: ignore" })));
});

test("all supported write inputs are checked", () => {
  blocked(evaluate(event("Edit", { new_string: fake })));
  blocked(evaluate(event("NotebookEdit", { new_source: fake })));
  blocked(evaluate(event("MultiEdit", { edits: [{ new_string: "safe" }, { new_string: fake }] })));
});

test("benign input leaves the normal permission flow unchanged", () => {
  for (const content of ["", "process.env.API_TOKEN", "os.environ['API_KEY']", "<redacted>", "example"]) {
    assert.deepEqual(evaluate(event("Write", { content })), {});
  }
  assert.deepEqual(evaluate(event("NotebookEdit", { edit_mode: "delete" })), {});
});

test("malformed schemas and unsupported tools block", () => {
  for (const input of [null, [], {}, event("Bash", { command: "echo ok" }),
    event("Write", {}), event("Write", { content: 123 }),
    event("MultiEdit", { edits: [null] }), event("MultiEdit", { edits: [] })]) {
    blocked(evaluate(input));
  }
});

test("input limit counts UTF-8 bytes", () => {
  blocked(evaluate(event("Write", { content: "é".repeat(MAX_BYTES) })));
});

function run(input) {
  return spawnSync(process.execPath, [guard], {
    input, encoding: "utf8", timeout: 5000, maxBuffer: 8192, env: {},
  });
}

test("CLI emits a single decision and never echoes malformed input", () => {
  for (const input of ["{" + fake, Buffer.from([0xff]), " ".repeat(MAX_BYTES + 1)]) {
    const result = run(input);
    assert.equal(result.status, 0);
    assert.equal(result.stderr, "");
    blocked(JSON.parse(result.stdout));
    assert.ok(!result.stdout.includes(fake));
  }
});

test("CLI clean and finding protocol", () => {
  for (const content of ["safe", fake]) {
    const result = run(JSON.stringify(event("Write", { content })));
    assert.equal(result.status, 0);
    assert.equal(result.stderr, "");
    if (content === fake) blocked(JSON.parse(result.stdout));
    else assert.deepEqual(JSON.parse(result.stdout), {});
  }
});
