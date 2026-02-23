import { beforeEach, describe, expect, it, vi } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import { setActivePluginRegistry } from "../plugins/runtime.js";
import { createTestRegistry } from "../test-utils/channel-plugins.js";
import type { WizardPrompter } from "../wizard/prompts.js";
import { createExitThrowingRuntime, createWizardPrompter } from "./test-wizard-helpers.js";

const hoisted = vi.hoisted(() => {
  const ensureOnboardingPluginInstalledMock = vi.fn();
  const reloadOnboardingPluginRegistryMock = vi.fn();
  return {
    ensureOnboardingPluginInstalledMock,
    reloadOnboardingPluginRegistryMock,
  };
});

vi.mock("./onboarding/plugin-install.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./onboarding/plugin-install.js")>();
  return {
    ...actual,
    ensureOnboardingPluginInstalled: hoisted.ensureOnboardingPluginInstalledMock,
    reloadOnboardingPluginRegistry: hoisted.reloadOnboardingPluginRegistryMock,
  };
});

const { setupChannels } = await import("./onboard-channels.js");

function createPrompter(overrides: Partial<WizardPrompter>): WizardPrompter {
  return createWizardPrompter(
    {
      progress: vi.fn(() => ({ update: vi.fn(), stop: vi.fn() })),
      ...overrides,
    },
    { defaultSelect: "__done__" },
  );
}

describe("setupChannels fallback install", () => {
  beforeEach(() => {
    // Simulate a runtime where the selected core channel plugin is not currently loaded.
    setActivePluginRegistry(createTestRegistry([]));
    hoisted.ensureOnboardingPluginInstalledMock.mockReset();
    hoisted.reloadOnboardingPluginRegistryMock.mockReset();
    hoisted.ensureOnboardingPluginInstalledMock.mockImplementation(
      async (params: { cfg: OpenClawConfig }) => ({
        cfg: params.cfg,
        installed: true,
      }),
    );
  });

  it("falls back to npm install metadata for missing core channel plugins", async () => {
    const note = vi.fn(async (_message?: string, _title?: string) => {});
    const select = vi.fn(async ({ message }: { message: string }) => {
      if (message === "Select channel (QuickStart)") {
        return "discord";
      }
      return "__done__";
    });
    const prompter = createPrompter({
      note,
      select: select as unknown as WizardPrompter["select"],
    });
    const runtime = createExitThrowingRuntime();

    await setupChannels({} as OpenClawConfig, runtime, prompter, {
      skipConfirm: true,
      quickstartDefaults: true,
    });

    const firstCall = hoisted.ensureOnboardingPluginInstalledMock.mock.calls[0]?.[0];
    expect(firstCall?.entry?.id).toBe("discord");
    expect(firstCall?.entry?.install?.npmSpec).toBe("@openclaw/discord");

    const sawUnavailableNote = note.mock.calls.some(
      ([message, title]) =>
        title === "Channel setup" && String(message).includes("discord plugin not available."),
    );
    expect(sawUnavailableNote).toBe(true);
  });
});
