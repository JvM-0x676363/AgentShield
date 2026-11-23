"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { createConfig } = require("../../hooks/claude/managed-hook-config.cjs");
const testConfig = options => createConfig({ ...options, purpose: "isolated-test" });
const examples = [
  { platform: "win32", runtimePath: "C:\\Program Files\\nodejs\\node.exe", guardPath: "C:\\Program Files\\ClaudeCode\\hooks\\secret-write-guard.cjs" },
  { platform: "linux", runtimePath: "/usr/bin/node", guardPath: "/etc/claude-code/hooks/secret-write-guard.cjs" },
  { platform: "darwin", runtimePath: "/opt/managed/node/bin/node", guardPath: "/Library/Application Support/ClaudeCode/hooks/secret-write-guard.cjs" },
];

test("each platform uses exec form and blocks host failures", () => {
  for (const example of examples) {
    const result = testConfig({ ...example, claudeVersion: "2.1.295" });
    const entry = result.hooks.PreToolUse[0];
    assert.equal(entry.hooks[0].command, example.runtimePath);
    assert.deepEqual(entry.hooks[0].args, ["--", example.guardPath]);
    assert.equal(entry.hooks[0].onFailure, "block");
    assert.equal(entry.hooks[0].timeout, 5);
    assert.ok(!new RegExp(entry.matcher).test("SomeOtherWrite"));
    assert.ok(new RegExp(entry.matcher).test("NotebookEdit"));
  }
});

test("old, unknown and prerelease client versions are rejected", () => {
  for (const claudeVersion of ["2.1.294", "2.0.999", "1.99.999", "", "2.1.295-beta", "latest"]) {
    assert.throws(() => testConfig({ ...examples[0], claudeVersion }));
  }
});

test("relative paths, network paths, expressions and traversal are rejected", () => {
  for (const runtimePath of ["node", "C:\\tools\\..\\node.exe", "\\\\server\\share\\node.exe",
    "C:\\tools\\node.exe:stream", "$env:ProgramFiles/node.exe", "C:\\tools\\node\n.exe"]) {
    assert.throws(() => testConfig({ ...examples[0], runtimePath, claudeVersion: "2.1.295" }));
  }
});

test("configuration generation does not mutate caller data", () => {
  const input = Object.freeze({ ...examples[1], claudeVersion: "2.1.316" });
  assert.deepEqual(testConfig(input), testConfig(input));
});

test("configuration generation requires an explicit isolated-test purpose", () => {
  for (const purpose of [undefined, "deployment", "", true]) {
    assert.throws(() => createConfig({ ...examples[0], claudeVersion: "2.1.295", purpose }),
      /managed_activation_not_ready/);
  }
  assert.throws(() => createConfig(), /managed_activation_not_ready/);
});
