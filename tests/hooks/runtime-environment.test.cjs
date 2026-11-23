"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const guard = path.resolve(__dirname, "../../hooks/claude/secret-write-guard.cjs");
const marker = path.join(__dirname, "fixtures/preload-marker.cjs");
const options = {
  input: "invalid JSON", encoding: "utf8", timeout: 5000, maxBuffer: 8192,
};

test("inherited preload executes before the guard despite absolute paths", () => {
  const result = spawnSync(process.execPath, ["--", guard], {
    ...options, env: { NODE_OPTIONS: `--require ${JSON.stringify(marker)}` },
  });
  assert.ifError(result.error);
  assert.equal(result.status, 73);
  assert.equal(result.stdout, "synthetic-preload-ran\n");
});

test("an explicitly empty child environment reaches the guard", () => {
  const result = spawnSync(process.execPath, ["--", guard], { ...options, env: {} });
  assert.ifError(result.error);
  assert.equal(result.status, 0);
  assert.equal(JSON.parse(result.stdout).hookSpecificOutput.permissionDecision, "deny");
  assert.ok(!result.stdout.includes("synthetic-preload-ran"));
});
