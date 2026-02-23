import { beforeEach, describe, expect, it, vi } from "vitest";
import type { GatewayService } from "../../daemon/service.js";

const inspectPortUsage = vi.hoisted(() => vi.fn());

vi.mock("../../infra/ports.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../infra/ports.js")>();
  return {
    ...actual,
    inspectPortUsage: (...args: unknown[]) => inspectPortUsage(...args),
  };
});

import { inspectGatewayRestart } from "./restart-health.js";

describe("inspectGatewayRestart", () => {
  const service = {
    readRuntime: vi.fn(),
  };
  const gatewayService = service as unknown as GatewayService;

  beforeEach(() => {
    service.readRuntime.mockReset();
    inspectPortUsage.mockReset();
  });

  it("treats a running gateway child process as healthy for wrapped services", async () => {
    service.readRuntime.mockResolvedValue({ status: "running", pid: 1037 });
    inspectPortUsage.mockResolvedValue({
      port: 18789,
      status: "busy",
      listeners: [{ pid: 1127, commandLine: "openclaw-gateway --port 18789" }],
      hints: [],
    });

    const snapshot = await inspectGatewayRestart({
      service: gatewayService,
      port: 18789,
    });

    expect(snapshot.healthy).toBe(true);
    expect(snapshot.staleGatewayPids).toEqual([]);
  });

  it("still marks gateway listeners as stale when runtime is not running", async () => {
    service.readRuntime.mockResolvedValue({ status: "stopped", pid: 1037 });
    inspectPortUsage.mockResolvedValue({
      port: 18789,
      status: "busy",
      listeners: [{ pid: 1127, commandLine: "openclaw-gateway --port 18789" }],
      hints: [],
    });

    const snapshot = await inspectGatewayRestart({
      service: gatewayService,
      port: 18789,
    });

    expect(snapshot.healthy).toBe(false);
    expect(snapshot.staleGatewayPids).toEqual([1127]);
  });
});
