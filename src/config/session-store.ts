/**
 * Records which VM tabs were open so quitting doesn't lose the workspace.
 *
 * Kept separate from `AppConfig`: this is session state the app manages, not
 * settings the user edits. The file path is injectable so the behaviour can be
 * tested without touching the real config directory.
 */

import { configPath, readJSON, writeJSON } from "./paths.ts";
import type { VMProviderID } from "../providers/types.ts";

export interface PersistedSession {
  destination: string;
  title: string;
  vmName: string | null;
  /** Which provider the tab ran on, so restore rebuilds the right transport. */
  provider: VMProviderID;
}

export interface PersistedWorkspace {
  sessions: PersistedSession[];
  /** Destination of the tab that was in front, if any. */
  selected: string | null;
}

export class SessionStore {
  private path: string;

  constructor(path = configPath("sessions.json")) {
    this.path = path;
  }

  /** The previously open tabs. A missing or unreadable file just means none. */
  load(): PersistedWorkspace {
    const raw = readJSON<unknown>(this.path);
    if (raw === null) return { sessions: [], selected: null };
    // Files written before the selection was recorded hold a bare array.
    // Reading them is what stops an upgrade from emptying the workspace.
    if (Array.isArray(raw)) return { sessions: decodeSessions(raw), selected: null };
    if (typeof raw !== "object") return { sessions: [], selected: null };
    const entry = raw as Record<string, unknown>;
    return {
      sessions: decodeSessions(entry.sessions),
      selected: typeof entry.selected === "string" ? entry.selected : null,
    };
  }

  save(workspace: PersistedWorkspace): void {
    writeJSON(this.path, workspace);
  }
}

function decodeSessions(value: unknown): PersistedSession[] {
  if (!Array.isArray(value)) return [];
  const sessions: PersistedSession[] = [];
  for (const raw of value) {
    if (typeof raw !== "object" || raw === null) continue;
    const entry = raw as Record<string, unknown>;
    if (typeof entry.destination !== "string" || !entry.destination) continue;
    sessions.push({
      destination: entry.destination,
      title: typeof entry.title === "string" ? entry.title : "",
      vmName: typeof entry.vmName === "string" ? entry.vmName : null,
      // A file written before providers existed has no `provider` key; it's an
      // exe.dev session.
      provider: entry.provider === "sprites" ? "sprites" : "exe",
    });
  }
  return sessions;
}

/**
 * Which persisted tabs to restore, given the VMs that currently exist.
 *
 * Tabs whose VM is gone are dropped so a deleted VM doesn't come back as a dead
 * tab. But if the VM list is empty — no token, or the lookup failed — the
 * persisted list is trusted rather than silently wiping the workspace over a
 * network blip.
 */
export function restorable(
  persisted: PersistedSession[],
  knownDestinations: Set<string>,
): PersistedSession[] {
  if (knownDestinations.size === 0) return persisted;
  return persisted.filter((session) => knownDestinations.has(session.destination));
}

/**
 * Which tab to put in front on restore: the one that was active, when it came
 * back — landing on the first tab after a restart loses your place for no
 * reason. Falls back to the first when the active tab's VM is gone.
 */
export function restorableSelection(
  selected: string | null,
  sessions: PersistedSession[],
): string | null {
  if (selected && sessions.some((session) => session.destination === selected)) return selected;
  return sessions[0]?.destination ?? null;
}
