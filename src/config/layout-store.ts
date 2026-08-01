/**
 * Where the panes were left: the sidebar widths, the diff sidebar's split
 * heights, and whether each sidebar was showing.
 *
 * Kept beside the session list rather than in `AppConfig` for the same reason
 * that is: this is state the app maintains as you drag things around, not a
 * setting anyone opens Settings to change. Sizing the panes to your screen once
 * and having them come back that way is most of what makes a layout yours.
 */

import { configPath, readJSON, writeJSON } from "./paths.ts";

export interface PersistedLayout {
  sidebarWidth: number;
  diffWidth: number;
  scopeHeight: number;
  filesHeight: number;
  showSessionSidebar: boolean;
  showDiffSidebar: boolean;
}

export function defaultLayout(): PersistedLayout {
  return {
    sidebarWidth: 26,
    diffWidth: 46,
    scopeHeight: 10,
    filesHeight: 8,
    showSessionSidebar: true,
    showDiffSidebar: true,
  };
}

/**
 * Decode field by field, like the rest of the stored files. Sizes are clamped
 * rather than rejected: a layout saved on a wide screen and reopened on a narrow
 * one is a number that's too big, not a corrupt file, and the layout pass will
 * shrink it to fit anyway.
 */
export function decodeLayout(raw: unknown): PersistedLayout {
  const defaults = defaultLayout();
  if (typeof raw !== "object" || raw === null) return defaults;
  const entry = raw as Record<string, unknown>;

  const size = (key: keyof PersistedLayout, fallback: number) => {
    const value = entry[key];
    if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
    return Math.max(1, Math.round(value));
  };
  const flag = (key: keyof PersistedLayout, fallback: boolean) =>
    typeof entry[key] === "boolean" ? entry[key] as boolean : fallback;

  return {
    sidebarWidth: size("sidebarWidth", defaults.sidebarWidth),
    diffWidth: size("diffWidth", defaults.diffWidth),
    scopeHeight: size("scopeHeight", defaults.scopeHeight),
    filesHeight: size("filesHeight", defaults.filesHeight),
    showSessionSidebar: flag("showSessionSidebar", defaults.showSessionSidebar),
    showDiffSidebar: flag("showDiffSidebar", defaults.showDiffSidebar),
  };
}

export class LayoutStore {
  private path: string;

  constructor(path = configPath("layout.json")) {
    this.path = path;
  }

  load(): PersistedLayout {
    return decodeLayout(readJSON<unknown>(this.path));
  }

  save(layout: PersistedLayout): void {
    writeJSON(this.path, layout);
  }
}
