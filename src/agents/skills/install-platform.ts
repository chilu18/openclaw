import type { SkillInstallSpec } from "./types.js";

const PLATFORM_ALIASES: Record<string, string> = {
  mac: "darwin",
  macos: "darwin",
  osx: "darwin",
  win: "win32",
  windows: "win32",
};

const ARCH_ALIASES: Record<string, string> = {
  amd64: "x64",
  x86_64: "x64",
  aarch64: "arm64",
};

function normalizePlatformName(name: string): string {
  const trimmed = name.trim().toLowerCase();
  if (!trimmed) {
    return "";
  }
  return PLATFORM_ALIASES[trimmed] ?? trimmed;
}

function normalizeArchName(name: string): string {
  const trimmed = name.trim().toLowerCase();
  if (!trimmed) {
    return "";
  }
  return ARCH_ALIASES[trimmed] ?? trimmed;
}

export function isInstallSpecSupportedOnCurrentRuntime(spec: SkillInstallSpec): boolean {
  const osList = (spec.os ?? []).map(normalizePlatformName).filter(Boolean);
  if (osList.length > 0 && !osList.includes(normalizePlatformName(process.platform))) {
    return false;
  }

  const archList = (spec.arch ?? []).map(normalizeArchName).filter(Boolean);
  if (archList.length > 0 && !archList.includes(normalizeArchName(process.arch))) {
    return false;
  }

  return true;
}
