import { describe, expect, it } from "vitest";
import { buildWorkspaceSkillStatus } from "./skills-status.js";
import type { SkillEntry } from "./skills/types.js";

function resolveMismatchedArch(arch: string): string {
  if (arch === "x64") {
    return "arm64";
  }
  if (arch === "arm64") {
    return "x64";
  }
  return "x64";
}

function resolveArchAlias(arch: string): string {
  if (arch === "x64") {
    return "x86_64";
  }
  if (arch === "arm64") {
    return "aarch64";
  }
  return arch;
}

describe("buildWorkspaceSkillStatus", () => {
  it("does not surface install options for OS-scoped skills on unsupported platforms", () => {
    if (process.platform === "win32") {
      // Keep this simple; win32 platform naming is already explicitly handled elsewhere.
      return;
    }

    const mismatchedOs = process.platform === "darwin" ? "linux" : "darwin";

    const entry: SkillEntry = {
      skill: {
        name: "os-scoped",
        description: "test",
        source: "test",
        filePath: "/tmp/os-scoped",
        baseDir: "/tmp",
        disableModelInvocation: false,
      },
      frontmatter: {},
      metadata: {
        os: [mismatchedOs],
        requires: { bins: ["fakebin"] },
        install: [
          {
            id: "brew",
            kind: "brew",
            formula: "fake",
            bins: ["fakebin"],
            label: "Install fake (brew)",
          },
        ],
      },
    };

    const report = buildWorkspaceSkillStatus("/tmp/ws", { entries: [entry] });
    expect(report.skills).toHaveLength(1);
    expect(report.skills[0]?.install).toEqual([]);
  });

  it("does not surface install options for arch-scoped installers on unsupported architectures", () => {
    const entry: SkillEntry = {
      skill: {
        name: "arch-scoped",
        description: "test",
        source: "test",
        filePath: "/tmp/arch-scoped",
        baseDir: "/tmp",
        disableModelInvocation: false,
      },
      frontmatter: {},
      metadata: {
        install: [
          {
            id: "deps",
            kind: "node",
            package: "example-package",
            arch: [resolveMismatchedArch(process.arch)],
          },
        ],
      },
    };

    const report = buildWorkspaceSkillStatus("/tmp/ws", { entries: [entry] });
    expect(report.skills).toHaveLength(1);
    expect(report.skills[0]?.install).toEqual([]);
  });

  it("accepts common architecture aliases in install metadata", () => {
    const entry: SkillEntry = {
      skill: {
        name: "arch-alias",
        description: "test",
        source: "test",
        filePath: "/tmp/arch-alias",
        baseDir: "/tmp",
        disableModelInvocation: false,
      },
      frontmatter: {},
      metadata: {
        install: [
          {
            id: "deps",
            kind: "node",
            package: "example-package",
            arch: [resolveArchAlias(process.arch)],
          },
        ],
      },
    };

    const report = buildWorkspaceSkillStatus("/tmp/ws", { entries: [entry] });
    expect(report.skills).toHaveLength(1);
    expect(report.skills[0]?.install).toHaveLength(1);
    expect(report.skills[0]?.install[0]?.id).toBe("deps");
  });
});
