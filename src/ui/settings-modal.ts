/**
 * Settings: which provider to use, the API tokens, and the environments a
 * session can be started with.
 *
 * Everything here writes straight into the shared config and saves on change,
 * so a new session picks up an edit without the modal being dismissed first.
 */

import { Color, elideHead, fit, styled } from "../tui/ansi.ts";
import {
  dropdown,
  type HitMap,
  panel,
  type Rect,
  row as listRow,
  TextInput,
} from "../tui/widgets.ts";
import { SelectPopup } from "./select-popup.ts";
import type { AppConfig } from "../config/app-config.ts";
import type { EnvVar } from "../config/env-var.ts";

/**
 * The label column every row shares, so values line up and the caret lands in
 * the right place. Wide enough for the longest label plus a separating space.
 */
const LABEL_WIDTH = 18;

type Row =
  | { kind: "heading"; text: string }
  | { kind: "provider" }
  | { kind: "token"; provider: "exe" | "sprites" }
  | { kind: "environment" }
  | { kind: "startCommand" }
  | { kind: "setupScript" }
  | { kind: "envVar"; index: number }
  | { kind: "addEnvVar" };

export class SettingsModal {
  private selection = 0;
  private offset = 0;
  private editing: TextInput | null = null;
  private rows: Row[] = [];
  private hovered: string | null = null;
  private caret: { x: number; y: number } | null = null;

  constructor(
    private config: AppConfig,
    private onOpenPopup: (popup: SelectPopup) => void,
  ) {}

  /** Where the caret goes this frame, or null when nothing is being edited. */
  cursorPosition(): { x: number; y: number } | null {
    return this.caret;
  }

  render(cols: number, rows: number, hits: HitMap): { lines: string[]; rect: Rect } {
    const width = Math.min(74, cols - 4);
    const height = Math.min(24, rows - 2);
    const rect: Rect = {
      x: Math.floor((cols - width) / 2),
      y: Math.floor((rows - height) / 2),
      width,
      height,
    };
    const inner = width - 2;
    const body = this.renderRows(inner, height - 2, rect, hits);
    return { lines: panel(width, height, "Settings", body, { bg: Color.panel }), rect };
  }

  private renderRows(width: number, height: number, rect: Rect, hits: HitMap): string[] {
    this.rows = this.buildRows();
    this.selection = Math.min(Math.max(0, this.selection), this.rows.length - 1);
    // Headings aren't selectable, and the list opens on one, so step off it.
    while (this.rows[this.selection]?.kind === "heading" && this.selection < this.rows.length - 1) {
      this.selection += 1;
    }
    // Recomputed every frame: only the row being edited carries the caret.
    this.caret = null;

    const listHeight = height - 1;
    if (this.selection < this.offset) this.offset = this.selection;
    if (this.selection >= this.offset + listHeight) {
      this.offset = this.selection - listHeight + 1;
    }

    const lines: string[] = [];
    for (let index = 0; index < listHeight; index += 1) {
      const entry = this.rows[this.offset + index];
      if (!entry) {
        lines.push(fit("", width, { bg: Color.panel }));
        continue;
      }
      if (entry.kind === "heading") {
        lines.push(
          fit(
            ` ${
              styled(entry.text.toUpperCase(), { fg: Color.dimmer, bold: true, bg: Color.panel })
            }`,
            width,
            {
              bg: Color.panel,
            },
          ),
        );
        continue;
      }
      const id = `settings.row:${this.offset + index}`;
      hits.add({ x: rect.x + 1, y: rect.y + 1 + index, width, height: 1 }, id);
      const active = this.offset + index === this.selection;
      if (active && this.editing) {
        // The value column starts after the row's selection bar and its label.
        const fieldWidth = width - 2 - LABEL_WIDTH;
        this.caret = {
          x: rect.x + 2 + LABEL_WIDTH + this.editing.cursorOffset(fieldWidth),
          y: rect.y + 1 + index,
        };
      }
      lines.push(
        fit(
          listRow(this.rowText(entry, width - 2, active), width, {
            selected: active,
            hovered: this.hovered === id,
            focused: true,
          }),
          width,
          { bg: Color.panel },
        ),
      );
    }
    lines.push(
      fit(
        ` ${
          styled("Enter edits · Space toggles · Del removes · Esc closes", {
            fg: Color.dimmer,
            bg: Color.panel,
          })
        }`,
        width,
        { bg: Color.panel },
      ),
    );
    return lines;
  }

  private buildRows(): Row[] {
    const rows: Row[] = [
      { kind: "heading", text: "Provider" },
      { kind: "provider" },
      { kind: "token", provider: "exe" },
      { kind: "token", provider: "sprites" },
      { kind: "heading", text: "Environment" },
      { kind: "environment" },
      { kind: "startCommand" },
      { kind: "setupScript" },
      { kind: "heading", text: "Global environment variables" },
    ];
    for (let index = 0; index < this.config.data.globalEnvironment.length; index += 1) {
      rows.push({ kind: "envVar", index });
    }
    rows.push({ kind: "addEnvVar" });
    return rows;
  }

  private rowText(entry: Row, width: number, active: boolean): string {
    const label = (text: string) => styled(text.padEnd(LABEL_WIDTH), { fg: Color.dim });
    const editing = active && this.editing !== null;
    const field = width - LABEL_WIDTH;
    const hovered = this.hovered !== null && active;

    switch (entry.kind) {
      case "provider":
        return label("Provider") +
          dropdown(
            this.config.data.provider === "exe" ? "exe.dev" : "sprites.dev",
            field,
            { focused: active, hovered },
          );
      case "token": {
        const name = entry.provider === "exe" ? "exe.dev token" : "sprites.dev token";
        if (editing) return label(name) + this.editing!.render(field, true);
        const stored = entry.provider === "exe"
          ? this.config.data.exeToken
          : this.config.data.spritesToken;
        const effective = this.config.tokenFor(entry.provider);
        const shown = stored
          ? mask(stored)
          : effective
          ? styled(`from the environment (${mask(effective)})`, { fg: Color.dimmer })
          : styled("not set", { fg: Color.orange });
        return label(name) + ` ${shown}`;
      }
      case "environment":
        return label("Session env") +
          dropdown(this.config.selectedEnvironment.name || "Untitled", field, {
            focused: active,
            hovered,
          });
      case "startCommand":
        if (editing) return label("Start command") + this.editing!.render(field, true);
        return label("Start command") + " " +
          styled(
            elideHead(
              this.config.selectedEnvironment.startCommand || "(a plain shell)",
              field - 1,
            ),
            { fg: Color.fg },
          );
      case "setupScript":
        if (editing) return label("Setup script") + this.editing!.render(field, true);
        return label("Setup script") + " " +
          styled(
            elideHead(
              oneLine(this.config.selectedEnvironment.setupScript) || "(none)",
              field - 1,
            ),
            { fg: Color.fg },
          );
      case "envVar": {
        const variable = this.config.data.globalEnvironment[entry.index];
        if (editing) return label(variable.key || "(new)") + this.editing!.render(field, true);
        return label(variable.key || "(unnamed)") + " " +
          styled(elideHead(variable.value ? mask(variable.value) : "(empty)", field - 1), {
            fg: variable.value ? Color.fg : Color.dimmer,
          });
      }
      case "addEnvVar":
        if (editing) return label("New variable") + this.editing!.render(field, true);
        return styled(" + Add variable", { fg: Color.accent });
      case "heading":
        return "";
    }
  }

  setHover(id: string | null): void {
    this.hovered = id;
  }

  /** Returns true when the modal should close. */
  key(event: { name: string; ctrl: boolean; alt: boolean; shift: boolean }): boolean {
    if (this.editing) {
      if (event.name === "escape") {
        this.editing = null;
        return false;
      }
      if (event.name === "enter") {
        this.commitEdit();
        return false;
      }
      this.editing.handle(event);
      return false;
    }

    switch (event.name) {
      case "escape":
        return true;
      case "up":
        this.move(-1);
        return false;
      case "down":
        this.move(1);
        return false;
      case "space":
      case "enter":
        // A dropdown row opens its list; anything else starts editing.
        this.beginEdit();
        return false;
      case "delete":
      case "backspace":
        this.removeCurrent();
        return false;
      default:
        return false;
    }
  }

  click(id: string): boolean {
    if (!id.startsWith("settings.row:")) return false;
    const index = Number(id.slice("settings.row:".length));
    if (index === this.selection) {
      // A second click on the row opens its list, or starts editing its value.
      this.beginEdit();
    } else {
      this.selection = index;
      this.editing = null;
    }
    return false;
  }

  scroll(delta: number): void {
    this.offset = Math.max(0, this.offset + delta);
  }

  private move(offset: number): void {
    let next = this.selection;
    for (let step = 0; step < this.rows.length; step += 1) {
      next = (next + offset + this.rows.length) % this.rows.length;
      if (this.rows[next].kind !== "heading") break;
    }
    this.selection = next;
    this.editing = null;
  }

  /** Open the list behind whichever dropdown the selection is on. */
  private openList(): void {
    const entry = this.rows[this.selection];
    if (entry?.kind === "provider") {
      this.onOpenPopup(
        new SelectPopup(
          "Provider",
          [
            { label: "exe.dev", detail: "ssh to <name>.exe.xyz" },
            { label: "sprites.dev", detail: "the sprite CLI" },
          ],
          this.config.data.provider === "exe" ? 0 : 1,
          (index) => {
            this.config.data.provider = index === 0 ? "exe" : "sprites";
            this.config.save();
          },
        ),
      );
      return;
    }
    if (entry?.kind === "environment") {
      const environments = this.config.data.environments;
      if (environments.length === 0) return;
      const current = environments.findIndex((one) =>
        one.id === this.config.selectedEnvironment.id
      );
      this.onOpenPopup(
        new SelectPopup(
          "Session environment",
          environments.map((environment) => ({
            label: environment.name || "Untitled",
            detail: environment.startCommand || "a plain shell",
          })),
          Math.max(0, current),
          (index) => {
            this.config.data.selectedEnvironmentID = environments[index].id;
            this.config.save();
          },
        ),
      );
    }
  }

  private beginEdit(): void {
    const entry = this.rows[this.selection];
    if (!entry) return;
    switch (entry.kind) {
      case "token":
        this.editing = new TextInput(
          entry.provider === "exe" ? this.config.data.exeToken : this.config.data.spritesToken,
        );
        return;
      case "startCommand":
        this.editing = new TextInput(this.config.selectedEnvironment.startCommand);
        return;
      case "setupScript":
        // Edited as one line: a full multi-line editor is more machinery than
        // a setup script needs here, and `; ` chains fine in a shell.
        this.editing = new TextInput(oneLine(this.config.selectedEnvironment.setupScript));
        return;
      case "envVar": {
        const variable = this.config.data.globalEnvironment[entry.index];
        this.editing = new TextInput(`${variable.key}=${variable.value}`);
        return;
      }
      case "addEnvVar":
        this.editing = new TextInput("KEY=value");
        return;
      default:
        // provider and environment: dropdowns, which open their list instead.
        this.openList();
    }
  }

  private commitEdit(): void {
    const entry = this.rows[this.selection];
    const value = this.editing?.value ?? "";
    this.editing = null;
    if (!entry) return;
    switch (entry.kind) {
      case "token":
        if (entry.provider === "exe") this.config.data.exeToken = value.trim();
        else this.config.data.spritesToken = value.trim();
        break;
      case "startCommand":
        this.updateEnvironment((environment) => {
          environment.startCommand = value;
        });
        break;
      case "setupScript":
        this.updateEnvironment((environment) => {
          environment.setupScript = value;
        });
        break;
      case "envVar":
        this.config.data.globalEnvironment[entry.index] = parseEnvVar(value);
        break;
      case "addEnvVar":
        if (value.trim() && value.trim() !== "KEY=value") {
          this.config.data.globalEnvironment.push(parseEnvVar(value));
        }
        break;
      default:
        return;
    }
    this.config.save();
  }

  private removeCurrent(): void {
    const entry = this.rows[this.selection];
    if (entry?.kind !== "envVar") return;
    this.config.data.globalEnvironment.splice(entry.index, 1);
    this.config.save();
  }

  private updateEnvironment(
    mutate: (environment: { startCommand: string; setupScript: string }) => void,
  ): void {
    const selected = this.config.selectedEnvironment;
    const stored = this.config.data.environments.find((one) => one.id === selected.id);
    if (stored) mutate(stored);
  }
}

/** `KEY=value`, with everything after the first `=` kept as the value. */
function parseEnvVar(text: string): EnvVar {
  const index = text.indexOf("=");
  if (index === -1) return { key: text.trim(), value: "" };
  return { key: text.slice(0, index).trim(), value: text.slice(index + 1) };
}

/** Tokens and secrets are shown by their ends only. */
function mask(value: string): string {
  if (value.length <= 8) return "•".repeat(value.length);
  return `${value.slice(0, 4)}${"•".repeat(6)}${value.slice(-4)}`;
}

function oneLine(text: string): string {
  return text.split("\n").map((line) => line.trim()).filter((line) => line).join("; ");
}
