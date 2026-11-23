const MAX_STATE_BYTES = 8192;
const PANE_ID = "agentshield-security";
const STATE_SUFFIX = "/.git-hooks/last-scan.json";
const SCAN_STATES = new Set(["clean", "findings", "environment_blocked"]);
const SCANNER_NAMES = ["gitleaks", "trivy"];

let panelState = null;

function formatStatus(status) {
  return status.replaceAll("_", " ");
}

function colorFor(status) {
  if (status === "clean") return "green";
  if (status === "findings") return "red";
  return "yellow";
}

function formatTimestamp(timestamp) {
  if (typeof timestamp !== "string" || timestamp.length > 40) return null;
  const parsed = new Date(timestamp);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString().replace("T", " ").replace(".000Z", " UTC");
}

function parseScanState(raw) {
  if (typeof raw !== "string" || new TextEncoder().encode(raw).length > MAX_STATE_BYTES) {
    return null;
  }

  try {
    const value = JSON.parse(raw);
    if (
      value?.schema_version !== 1 ||
      value.runner !== "agent-shield-scan" ||
      !SCAN_STATES.has(value.status)
    ) {
      return null;
    }

    const scannerStates = new Map();
    for (const scanner of Array.isArray(value.scanners) ? value.scanners : []) {
      if (SCANNER_NAMES.includes(scanner?.scanner) && SCAN_STATES.has(scanner?.status)) {
        scannerStates.set(scanner.scanner, scanner.status);
      }
    }

    return {
      status: value.status,
      timestamp: formatTimestamp(value.timestamp_utc),
      scanners: scannerStates,
    };
  } catch {
    return null;
  }
}

async function readScanState($) {
  try {
    const home = (await $.env.get("HOME")) || (await $.env.get("USERPROFILE"));
    if (typeof home !== "string" || home.length === 0 || home.length > 4096) {
      return null;
    }

    const path = home.replace(/[\\/]+$/, "") + STATE_SUFFIX;
    return parseScanState(await $.fs.read(path));
  } catch {
    return null;
  }
}

function renderScanner(Text, scanner, status) {
  if (!status) return Text({ dimColor: true, children: `${scanner}: not recorded` });
  return Text({ color: colorFor(status), children: `${scanner}: ${formatStatus(status)}` });
}

export function register(on) {
  on("session.start", async ($, event, next) => {
    await $.command.register({
      name: "agentshield",
      description: "Open the local AgentShield scan panel",
    });
    return next(event);
  });

  on("command.run", { command: "agentshield" }, async ($) => {
    panelState = await readScanState($);
    await $.ui.open({ id: PANE_ID, title: "AgentShield", closeOnEscape: true });
    return {};
  });

  on("ui.render", { component: "Pane" }, async ($, event, next) => {
    if (event.requestId !== PANE_ID) return next(event);

    const { Box, Text } = $.ui.resolve(event);
    if (!panelState) {
      return Box({
        flexDirection: "column",
        children: [
          Text({ children: "AgentShield" }),
          Text({ dimColor: true, children: "No validated local scan state is available." }),
          Text({ dimColor: true, children: "Run /agentshield again after a local scan." }),
        ],
      });
    }

    const timestamp = panelState.timestamp ? `Last scan: ${panelState.timestamp}` : "Last scan: not recorded";
    return Box({
      flexDirection: "column",
      children: [
        Text({ children: "AgentShield" }),
        Text({ color: colorFor(panelState.status), children: `Overall: ${formatStatus(panelState.status)}` }),
        Text({ dimColor: true, children: timestamp }),
        Text({ children: "Scanners" }),
        ...SCANNER_NAMES.map((scanner) => renderScanner(Text, scanner, panelState.scanners.get(scanner))),
        Text({ dimColor: true, children: "This panel is read-only. It does not run scanners or change policy." }),
      ],
    });
  });
}
