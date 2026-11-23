"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { inspectUnixPath, preflight } = require("../../hooks/claude/runtime-preflight.cjs");

function fixture(overrides = {}) {
  const visited = [];
  const lstat = value => {
    visited.push(value);
    if (overrides[value] instanceof Error) throw overrides[value];
    return {
      uid: 0, mode: 0o755,
      isSymbolicLink: () => false,
      isFile: () => value === "/opt/managed/node",
      isDirectory: () => value !== "/opt/managed/node",
      ...overrides[value],
    };
  };
  return { lstat, visited };
}

test("checks every ancestor including the filesystem root", () => {
  const mock = fixture();
  assert.equal(inspectUnixPath("/opt/managed/node", { executable: true, ...mock }).passed, true);
  assert.deepEqual(mock.visited, ["/opt/managed/node", "/opt/managed", "/opt", "/"]);
});

test("rejects writable, replaced, linked and unavailable path components", () => {
  for (const component of ["/opt/managed/node", "/opt/managed", "/opt", "/"]) {
    for (const value of [
      { uid: 1000 }, { mode: 0o775 }, { mode: 0o757 },
      { isSymbolicLink: () => true },
      { isFile: () => false, isDirectory: () => false }, new Error("unavailable"),
    ]) {
      assert.equal(inspectUnixPath("/opt/managed/node", fixture({ [component]: value })).passed, false);
    }
  }
});

test("requires executable runtime but permits a non-executable guard", () => {
  const mock = fixture({ "/opt/managed/node": { mode: 0o644 } });
  assert.equal(inspectUnixPath("/opt/managed/node", { ...mock, executable: true }).reason, "not_executable");
  assert.equal(inspectUnixPath("/opt/managed/node", mock).passed, true);
});

test("invalid paths are rejected before filesystem access", () => {
  const mock = fixture();
  for (const value of [undefined, "node", "/opt/../node", "/opt/./node", "/opt/node\n", "C:\\node.exe"]) {
    assert.equal(inspectUnixPath(value, mock).passed, false);
  }
  assert.deepEqual(mock.visited, []);
});

test("no Windows or unknown platform is approved using POSIX metadata", () => {
  for (const platform of ["win32", "unknown"]) {
    assert.deepEqual(preflight({ platform }), { ready: false, reason: "native_platform_adapter_required" });
  }
});
