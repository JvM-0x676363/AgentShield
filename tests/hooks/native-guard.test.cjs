"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { evaluate } = require("../../hooks/claude/secret-write-guard.cjs");
const executable = process.env.AGENTSHIELD_TEST_GUARD;

test("native guard matches prototype decisions and ignores Node loader options", { skip: !executable }, () => {
  const fake = "AK" + "IA" + "Z".repeat(16);
  const inputs = [null, [], {},
    ...["Write", "Edit", "NotebookEdit", "MultiEdit"].flatMap(tool =>
      ["safe", fake, null].map(value => ({
        hook_event_name: "PreToolUse", tool_name: tool,
        tool_input: { content: value, new_string: value, new_source: value, edits: [{ new_string: value }] },
      }))),
  ];
  for (const input of inputs) {
    const result = spawnSync(executable, [], {
      input: JSON.stringify(input), encoding: "utf8", timeout: 5000, maxBuffer: 8192,
      env: { NODE_OPTIONS: "--require nonexistent-synthetic-module" },
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0);
    assert.equal(result.stderr, "");
    const expected = evaluate(input).hookSpecificOutput?.permissionDecision;
    assert.equal(JSON.parse(result.stdout).hookSpecificOutput?.permissionDecision, expected);
    assert.ok(!result.stdout.includes(fake));
  }
});
