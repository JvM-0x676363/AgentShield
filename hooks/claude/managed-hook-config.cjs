"use strict";

const path = require("node:path");

function createConfig({ platform, runtimePath, guardPath, claudeVersion, purpose } = {}) {
  if (purpose !== "isolated-test") throw new Error("managed_activation_not_ready");
  const paths = platform === "win32" ? path.win32 : path.posix;
  if (!["win32", "linux", "darwin"].includes(platform)) throw new Error("unsupported_platform");
  for (const value of [runtimePath, guardPath]) {
    if (typeof value !== "string" || !paths.isAbsolute(value) || /[\x00-\x1f$`]/.test(value)) {
      throw new Error("absolute_literal_path_required");
    }
    if (platform === "win32" && (!/^[A-Za-z]:[\\/]/.test(value) || value.slice(2).includes(":"))) {
      throw new Error("local_drive_path_required");
    }
    if (value.split(/[\\/]/).includes("..")) throw new Error("path_traversal");
  }
  const version = /^(\d+)\.(\d+)\.(\d+)$/.exec(claudeVersion || "");
  if (!version) throw new Error("stable_claude_version_required");
  const [major, minor, patch] = version.slice(1).map(Number);
  if (major < 2 || (major === 2 && (minor < 1 || (minor === 1 && patch < 295)))) {
    throw new Error("claude_2_1_295_required");
  }
  return { hooks: { PreToolUse: [{
    matcher: "^(Write|Edit|MultiEdit|NotebookEdit)$",
    hooks: [{ type: "command", command: runtimePath,
      args: ["--", guardPath], timeout: 5, onFailure: "block" }],
  }] } };
}

module.exports = { createConfig };
