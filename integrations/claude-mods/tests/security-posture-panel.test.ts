import { expect, test } from "claude-code/testing";

const CLEAN_STATE = JSON.stringify({
  schema_version: 1,
  runner: "agent-shield-scan",
  status: "clean",
  scanners: [
    { scanner: "gitleaks", status: "clean" },

    { scanner: "trivy", status: "clean" },
  ],
});

async function mountPanel($: any) {
  return $.ui.mount({
    plugin: "agentshield-security-posture",
    surface: "terminal",
    component: "Pane",
    requestId: "agentshield-security",
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120 },
  } as any);
}

function registerHome(on: any) {
  on("env.get", (_$: any, event: any) => ({
    value: event.key === "HOME" ? "/home/test" : undefined,
  }));
}

async function openPanel($: any) {
  await $.session.start({});
  await $.command.run({ command: "agentshield", args: "" });
}

test("renders a read-only local dashboard from validated state", async ($: any, on: any) => {
  registerHome(on);
  on("fs.read", (_$: any, event: any) => {
    expect(event.path).toMatch(/\.git-hooks[\\/]last-scan\.json$/);
    return { value: CLEAN_STATE };
  });

  await openPanel($);
  const ui = await mountPanel($);
  expect(await ui.find({ type: "Text", text: "Overall: clean" })).toBeDefined();
  expect(await ui.find({ type: "Text", text: "gitleaks: clean" })).toBeDefined();

  expect(await ui.find({ type: "Text", text: "trivy: clean" })).toBeDefined();
  await ui.unmount();
});

test("fails closed for malformed state", async ($: any, on: any) => {
  registerHome(on);
  on("fs.read", () => ({ value: "not-json" }));

  await openPanel($);
  const ui = await mountPanel($);
  expect(await ui.find({ type: "Text", text: "No validated local scan state is available." })).toBeDefined();
  await ui.unmount();
});

test("fails closed for oversized state", async ($: any, on: any) => {
  registerHome(on);
  on("fs.read", () => ({ value: "x".repeat(8193) }));

  await openPanel($);
  const ui = await mountPanel($);
  expect(await ui.find({ type: "Text", text: "No validated local scan state is available." })).toBeDefined();
  await ui.unmount();
});
