"use strict";

const MAX_BYTES = 1024 * 1024;
const PATTERNS = [
  ["private_key", /-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/],
  ["aws_access_key_id", /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/],
  ["github_token", /\bgh[pousr]_[A-Za-z0-9]{36,}\b/],
  ["github_fine_grained_token", /\bgithub_pat_[A-Za-z0-9_]{40,}\b/],
  ["gitlab_token", /\bglpat-[A-Za-z0-9_-]{20,}/],
  ["slack_token", /\bxox[baprs]-[A-Za-z0-9-]{20,}/],
];

function deny(code) {
  return { hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: `AgentShield: ${code}. Write blocked; no submitted content is included in this diagnostic.`,
  } };
}

function evaluate(event) {
  if (!event || typeof event !== "object" || Array.isArray(event) ||
      event.hook_event_name !== "PreToolUse") return deny("invalid_event");
  const input = event.tool_input;
  if (!input || typeof input !== "object" || Array.isArray(input)) return deny("invalid_input");
  let texts;
  switch (event.tool_name) {
    case "Write": texts = [input.content]; break;
    case "Edit": texts = [input.new_string]; break;
    case "NotebookEdit": texts = input.edit_mode === "delete" ? [""] : [input.new_source]; break;
    case "MultiEdit":
      if (!Array.isArray(input.edits) || !input.edits.length) return deny("invalid_edits");
      texts = input.edits.map(edit => edit && edit.new_string);
      break;
    default: return deny("unsupported_tool");
  }
  if (!texts.every(text => typeof text === "string")) return deny("invalid_content");
  if (texts.reduce((size, text) => size + Buffer.byteLength(text, "utf8"), 0) > MAX_BYTES) {
    return deny("input_limit");
  }
  for (const text of texts) {
    for (const [name, pattern] of PATTERNS) {
      if (pattern.test(text)) return deny(`secret_pattern_${name}`);
    }
  }
  // No allow decision: existing permissions and other hooks still apply.
  return {};
}

function main() {
  let chunks = [];
  let size = 0;
  let finished = false;
  const finish = result => {
    if (finished) return;
    finished = true;
    chunks = [];
    process.stdout.write(JSON.stringify(result) + "\n");
  };
  process.stdin.on("data", chunk => {
    if (finished) return;
    size += chunk.length;
    if (size > MAX_BYTES) {
      finish(deny("input_limit"));
      process.stdin.destroy();
      return;
    }
    chunks.push(chunk);
  });
  process.stdin.on("error", () => finish(deny("input_read_failed")));
  process.stdin.on("end", () => {
    if (finished) return;
    try {
      const raw = new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks));
      finish(evaluate(JSON.parse(raw)));
    } catch {
      finish(deny("evaluation_failed"));
    }
  });
}

module.exports = { evaluate, MAX_BYTES };
if (require.main === module) main();
