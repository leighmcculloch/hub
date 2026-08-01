/**
 * The command palette's contents.
 *
 * Every shortcut in the app is an Alt chord, which is fine once you know them
 * and invisible until you do. The palette is the other half: one key that lists
 * everything the app can do, filterable by name, with the shortcut shown beside
 * each entry so using it teaches the chord.
 */

import type { SelectOption } from "./select-popup.ts";

export interface Command {
  label: string;
  /** The shortcut, shown so the palette teaches it. */
  shortcut?: string;
  /** Hidden when false — a command that makes no sense right now. */
  enabled?: boolean;
  run(): void | Promise<void>;
}

/** The palette's options, in the order the commands were given. */
export function commandOptions(commands: Command[]): SelectOption[] {
  return commands.map((command) => ({ label: command.label, detail: command.shortcut }));
}

/** Drop the commands that don't apply, so the list never offers a no-op. */
export function availableCommands(commands: Command[]): Command[] {
  return commands.filter((command) => command.enabled !== false);
}
