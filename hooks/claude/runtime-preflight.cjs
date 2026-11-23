"use strict";

const fs = require("node:fs");
const path = require("node:path");

function inspectUnixPath(filePath, { executable = false, lstat = fs.lstatSync } = {}) {
  if (typeof filePath !== "string" || !path.posix.isAbsolute(filePath) ||
      /[\x00-\x1f\\]/.test(filePath) || filePath.split("/").some(p => p === ".." || p === ".")) {
    return { passed: false, reason: "absolute_literal_path_required" };
  }
  let current = filePath;
  let leaf = true;
  try {
    for (;;) {
      const stat = lstat(current);
      if (stat.isSymbolicLink()) return { passed: false, reason: "symbolic_link" };
      if (leaf ? !stat.isFile() : !stat.isDirectory()) {
        return { passed: false, reason: "unexpected_file_type" };
      }
      if (stat.uid !== 0) return { passed: false, reason: "non_root_owner" };
      if ((stat.mode & 0o022) !== 0) return { passed: false, reason: "group_or_other_writable" };
      if (leaf && executable && (stat.mode & 0o111) === 0) {
        return { passed: false, reason: "not_executable" };
      }
      if (current === "/") break;
      current = path.posix.dirname(current);
      leaf = false;
    }
  } catch {
    return { passed: false, reason: "metadata_unavailable" };
  }
  return { passed: true, reason: "posix_metadata_checked" };
}

function preflight({ platform = process.platform, runtimePath, guardPath } = {}) {
  if (!["linux", "darwin"].includes(platform) || platform !== process.platform) {
    return { ready: false, reason: "native_platform_adapter_required" };
  }
  const runtime = inspectUnixPath(runtimePath, { executable: true });
  const guard = inspectUnixPath(guardPath);
  return {
    ready: false,
    reason: runtime.passed && guard.passed ? "additional_integrity_checks_required" : "unsafe_path_metadata",
    runtime, guard,
  };
}

module.exports = { inspectUnixPath, preflight };
