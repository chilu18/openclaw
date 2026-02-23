import { describe, expect, it } from "vitest";
import { buildPortHints } from "../../infra/ports.js";
import { renderPortDiagnosticsForCli, type DaemonStatus } from "./status.gather.js";

function makeStatus(params: {
  runtimeStatus: "running" | "stopped" | "unknown";
  listeners: Array<{ pid?: number; commandLine?: string }>;
}): DaemonStatus {
  const port = 18789;
  return {
    service: {
      label: "systemd",
      loaded: true,
      loadedText: "enabled",
      notLoadedText: "disabled",
      runtime: { status: params.runtimeStatus },
    },
    port: {
      port,
      status: "busy",
      listeners: params.listeners,
      hints: buildPortHints(params.listeners, port),
    },
    extraServices: [],
  };
}

describe("renderPortDiagnosticsForCli", () => {
  it("suppresses false port-conflict warnings when service is running and gateway owns the port", () => {
    const status = makeStatus({
      runtimeStatus: "running",
      listeners: [{ pid: 1127, commandLine: "openclaw-gateway --port 18789" }],
    });

    expect(renderPortDiagnosticsForCli(status)).toEqual([]);
  });

  it("keeps port-conflict warnings for non-gateway listeners", () => {
    const status = makeStatus({
      runtimeStatus: "running",
      listeners: [{ pid: 2201, commandLine: "python -m http.server 18789" }],
    });

    const lines = renderPortDiagnosticsForCli(status);
    expect(lines[0]).toContain("Port 18789 is already in use.");
    expect(lines.some((line) => line.includes("Another process is listening on this port."))).toBe(
      true,
    );
  });

  it("still reports gateway listener conflicts when runtime is not running", () => {
    const status = makeStatus({
      runtimeStatus: "stopped",
      listeners: [{ pid: 1127, commandLine: "openclaw-gateway --port 18789" }],
    });

    expect(renderPortDiagnosticsForCli(status).length).toBeGreaterThan(0);
  });
});
