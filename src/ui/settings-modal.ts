/**
 * Settings, in tabs: the provider new sessions default to and its credentials,
 * the environments a session can be started with, pi's own configuration, and
 * the variables every VM gets.
 *
 * Tabs rather than one long list because these are four unrelated things, and
 * two of them — a setup script and a JSON settings object — want the height of
 * a page to themselves rather than a line each. The provider setting is a
 * default, not a switch: a credential for each means every account is listed
 * and usable at once.
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
  TextArea,
  TextInput,
} from "../tui/widgets.ts";
import { SelectPopup } from "./select-popup.ts";
import type { AppConfig } from "../config/app-config.ts";
import { defaultEnvironments } from "../config/session-environment.ts";
import type { EnvVar } from "../config/env-var.ts";
import type { Workspace } from "../model/workspace.ts";
import type { VMProviderID } from "../providers/types.ts";
import { ALL_PROVIDERS, providerLabel } from "../model/provider-label.ts";

/**
 * The label column every row shares, so values line up and the caret lands in
 * the right place. Wide enough for the longest label plus a separating space.
 */
const LABEL_WIDTH = 18;

/** How each provider is reached, beside its name in the default-provider list. */
const PROVIDER_DETAIL: Record<VMProviderID, string> = {
  exe: "ssh to <name>.exe.xyz",
  sprites: "the sprite CLI",
  namespace: "dev boxes, via the devbox CLI",
  docker: "containers on this machine",
};

/** The pages, in the order they're offered. */
const TABS = ["Provider", "Environments", "pi", "Variables"] as const;
type Tab = typeof TABS[number];

/** Which multi-line value a text area is editing. */
type AreaField = "setupScript" | "piSettings";

type Row =
  | { kind: "provider" }
  | { kind: "token"; provider: "exe" | "sprites" }
  /** A provider whose credential lives in a local CLI: a status, not a field. */
  | { kind: "cliLogin"; provider: VMProviderID }
  | { kind: "environment" }
  | { kind: "startCommand" }
  /** A block that takes the rest of the page, not a line. */
  | { kind: "textArea"; field: AreaField }
  | { kind: "deleteEnvironment" }
  | { kind: "resetEnvironments" }
  | { kind: "envVar"; index: number }
  | { kind: "addEnvVar" };

export class SettingsModal {
  private tab: Tab = TABS[0];
  private selection = 0;
  private offset = 0;
  private editing: TextInput | null = null;
  private area: TextArea | null = null;
  private rows: Row[] = [];
  private hovered: string | null = null;
  private caret: { x: number; y: number } | null = null;
  /** How tall the current page's text area is; the renderer decides, the caret follows. */
  private areaHeight = 1;

  constructor(
    private config: AppConfig,
    private workspace: Workspace,
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
    const body = this.renderBody(inner, height - 2, rect, hits);
    return { lines: panel(width, height, "Settings", body, { bg: Color.panel }), rect };
  }

  private renderBody(width: number, height: number, rect: Rect, hits: HitMap): string[] {
    this.rows = this.buildRows();
    this.selection = Math.min(Math.max(0, this.selection), Math.max(0, this.rows.length - 1));
    this.caret = null;

    const lines: string[] = [this.tabBar(width, rect, hits)];
    // One line for the tab bar, one for the footer hint.
    const listHeight = height - 2;
    lines.push(...this.renderRows(width, listHeight, rect, hits));
    lines.push(this.footer(width));
    return lines;
  }

  /** The tab strip, and the hit targets that make it clickable. */
  private tabBar(width: number, rect: Rect, hits: HitMap): string {
    let text = "";
    let column = 0;
    for (const tab of TABS) {
      const label = ` ${tab} `;
      hits.add(
        { x: rect.x + 1 + column, y: rect.y + 1, width: label.length, height: 1 },
        `settings.tab:${tab}`,
      );
      text += tab === this.tab
        ? styled(label, { fg: Color.fg, bg: Color.selection, bold: true })
        : styled(label, { fg: Color.dimmer, bg: Color.panel });
      column += label.length;
    }
    return fit(text, width, { bg: Color.panel });
  }

  private footer(width: number): string {
    const hint = this.area
      ? "Enter adds a line · Esc saves and closes the editor"
      : this.rows[this.selection]?.kind === "textArea"
      ? "Enter edits · ←/→ changes tab · Esc closes"
      : "Enter edits · ←/→ changes tab · Del removes · Esc closes";
    return fit(` ${styled(hint, { fg: Color.dimmer, bg: Color.panel })}`, width, {
      bg: Color.panel,
    });
  }

  private renderRows(width: number, height: number, rect: Rect, hits: HitMap): string[] {
    // A text area takes whatever the single-line rows above it leave behind.
    const areaIndex = this.rows.findIndex((entry) => entry.kind === "textArea");
    this.areaHeight = areaIndex === -1 ? 1 : Math.max(1, height - (this.rows.length - 1));

    if (this.selection < this.offset) this.offset = this.selection;
    if (this.selection >= this.offset + height) this.offset = this.selection - height + 1;

    const lines: string[] = [];
    let index = this.offset;
    // `rect.y + 1` is the tab bar, so the first row sits one line below it.
    const firstRowY = rect.y + 2;
    while (lines.length < height) {
      const entry = this.rows[index];
      if (!entry) {
        lines.push(fit("", width, { bg: Color.panel }));
        index += 1;
        continue;
      }
      const id = `settings.row:${index}`;
      const active = index === this.selection;
      const top = firstRowY + lines.length;

      if (entry.kind === "textArea") {
        const rows = Math.min(this.areaHeight, height - lines.length);
        hits.add({ x: rect.x + 1, y: top, width, height: rows }, id);
        lines.push(...this.renderArea(entry.field, width, rows, rect, top, active));
        index += 1;
        continue;
      }

      hits.add({ x: rect.x + 1, y: top, width, height: 1 }, id);
      if (active && this.editing) {
        // The value column starts after the row's selection bar and its label.
        const fieldWidth = width - 2 - LABEL_WIDTH;
        this.caret = {
          x: rect.x + 2 + LABEL_WIDTH + this.editing.cursorOffset(fieldWidth),
          y: top,
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
      index += 1;
    }
    return lines;
  }

  /**
   * The multi-line block: the stored value when it is at rest, the editor's own
   * view of it while it is being edited.
   */
  private renderArea(
    field: AreaField,
    width: number,
    height: number,
    rect: Rect,
    top: number,
    active: boolean,
  ): string[] {
    const editing = active && this.area !== null;
    const background = editing ? Color.selection : active ? Color.hover : Color.panelAlt;
    const inner = Math.max(1, width - 2);
    const text = editing ? null : this.areaValue(field);
    const rows = editing
      ? this.area!.render(inner, height - 1)
      : (text ? text.split("\n") : []).slice(0, height - 1);

    if (editing) {
      const cell = this.area!.cursorCell(inner, height - 1);
      if (cell) this.caret = { x: rect.x + 2 + cell.x, y: top + 1 + cell.y };
    }

    const lines = [
      fit(
        ` ${styled(this.areaLabel(field), { fg: active ? Color.fg : Color.dim, bg: Color.panel })}`,
        width,
        { bg: Color.panel },
      ),
    ];
    for (let index = 0; index < height - 1; index += 1) {
      const line = rows[index] ?? "";
      const shown = index === 0 && !editing && !text ? "(none)" : line;
      lines.push(
        fit(
          ` ${styled(shown, { fg: shown === "(none)" ? Color.dimmer : Color.fg, bg: background })}`,
          width,
          {
            bg: background,
          },
        ),
      );
    }
    return lines;
  }

  private areaLabel(field: AreaField): string {
    return field === "setupScript" ? "Setup script" : "pi settings (~/.pi/agent/settings.json)";
  }

  private areaValue(field: AreaField): string {
    return field === "setupScript"
      ? this.config.selectedEnvironment.setupScript
      : this.config.data.piSettings;
  }

  private buildRows(): Row[] {
    switch (this.tab) {
      case "Provider":
        return [
          { kind: "provider" },
          { kind: "cliLogin", provider: "docker" },
          { kind: "token", provider: "exe" },
          { kind: "token", provider: "sprites" },
          { kind: "cliLogin", provider: "namespace" },
        ];
      case "Environments":
        return [
          { kind: "environment" },
          { kind: "startCommand" },
          { kind: "deleteEnvironment" },
          { kind: "resetEnvironments" },
          { kind: "textArea", field: "setupScript" },
        ];
      case "pi":
        return [{ kind: "textArea", field: "piSettings" }];
      case "Variables": {
        const rows: Row[] = [];
        for (let index = 0; index < this.config.data.globalEnvironment.length; index += 1) {
          rows.push({ kind: "envVar", index });
        }
        rows.push({ kind: "addEnvVar" });
        return rows;
      }
    }
  }

  private rowText(entry: Row, width: number, active: boolean): string {
    const label = (text: string) => styled(text.padEnd(LABEL_WIDTH), { fg: Color.dim });
    const editing = active && this.editing !== null;
    const field = width - LABEL_WIDTH;
    const hovered = this.hovered !== null && active;

    switch (entry.kind) {
      case "provider":
        // Every provider that is set up is live at once; this only picks which
        // one a new session starts on by default.
        return label("Default") +
          dropdown(providerLabel(this.config.data.provider), field, {
            focused: active,
            hovered,
          });
      case "cliLogin": {
        // Nothing to type: the credential is the CLI's — a login for Namespace,
        // a running daemon for Docker. All this row can do is say whether that
        // CLI answers, and name the command that says why it doesn't.
        const provider = this.workspace.providerFor(entry.provider);
        const credential = provider.credential;
        const command = credential.kind === "cli" ? credential.loginCommand : "";
        return label(`${provider.displayName} login`) + " " +
          (this.workspace.isConfigured(entry.provider)
            ? styled(`the ${credential.kind === "cli" ? credential.binary : ""} CLI is ready`, {
              fg: Color.green,
            })
            : styled(`not ready — run \`${command}\``, { fg: Color.orange }));
      }
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
      case "envVar": {
        const variable = this.config.data.globalEnvironment[entry.index];
        if (editing) return label(variable.key || "(new)") + this.editing!.render(field, true);
        return label(variable.key || "(unnamed)") + " " +
          styled(elideHead(variable.value ? mask(variable.value) : "(empty)", field - 1), {
            fg: variable.value ? Color.fg : Color.dimmer,
          });
      }
      case "deleteEnvironment": {
        // Refused rather than hidden when it is the last one: a config with no
        // environments has nothing to start a session with.
        const last = this.config.data.environments.length <= 1;
        return styled(
          last ? " ✕ Delete environment (the only one)" : " ✕ Delete this environment",
          { fg: last ? Color.dimmer : Color.orange },
        );
      }
      case "resetEnvironments":
        return styled(" ↺ Reset environments to defaults", { fg: Color.accent });
      case "addEnvVar":
        if (editing) return label("New variable") + this.editing!.render(field, true);
        return styled(" + Add variable", { fg: Color.accent });
      case "textArea":
        return "";
    }
  }

  setHover(id: string | null): void {
    this.hovered = id;
  }

  /** Returns true when the modal should close. */
  key(event: { name: string; ctrl: boolean; alt: boolean; shift: boolean }): boolean {
    // A text area owns Enter — it is how you add a line — so Esc is what ends
    // the edit, and it saves rather than discarding: losing a script someone
    // just typed because they reached for the usual way out is not a trade
    // worth making.
    if (this.area) {
      if (event.name === "escape") {
        this.commitArea();
        return false;
      }
      this.area.handle(event);
      return false;
    }

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
      case "left":
        this.moveTab(-1);
        return false;
      case "right":
        this.moveTab(1);
        return false;
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
    if (id.startsWith("settings.tab:")) {
      const tab = id.slice("settings.tab:".length) as Tab;
      if (TABS.includes(tab)) this.selectTab(tab);
      return false;
    }
    if (!id.startsWith("settings.row:")) return false;
    const index = Number(id.slice("settings.row:".length));
    if (index === this.selection) {
      // A second click on the row opens its list, or starts editing its value.
      this.beginEdit();
    } else {
      this.selection = index;
      this.editing = null;
      this.area = null;
    }
    return false;
  }

  scroll(delta: number): void {
    this.offset = Math.max(0, this.offset + delta);
  }

  private moveTab(step: number): void {
    const index = TABS.indexOf(this.tab);
    this.selectTab(TABS[(index + step + TABS.length) % TABS.length]);
  }

  private selectTab(tab: Tab): void {
    if (tab === this.tab) return;
    this.tab = tab;
    this.selection = 0;
    this.offset = 0;
    this.editing = null;
    this.area = null;
  }

  private move(offset: number): void {
    if (this.rows.length === 0) return;
    this.selection = (this.selection + offset + this.rows.length) % this.rows.length;
    this.editing = null;
    this.area = null;
  }

  /** Open the list behind whichever dropdown the selection is on. */
  private openList(): void {
    const entry = this.rows[this.selection];
    if (entry?.kind === "provider") {
      this.onOpenPopup(
        new SelectPopup(
          "Default provider",
          ALL_PROVIDERS.map((id) => ({ label: providerLabel(id), detail: PROVIDER_DETAIL[id] })),
          Math.max(0, ALL_PROVIDERS.indexOf(this.config.data.provider)),
          (index) => {
            this.config.data.provider = ALL_PROVIDERS[index];
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
      case "textArea":
        this.area = new TextArea(this.areaValue(entry.field));
        return;
      case "token":
        this.editing = new TextInput(
          entry.provider === "exe" ? this.config.data.exeToken : this.config.data.spritesToken,
        );
        return;
      case "startCommand":
        this.editing = new TextInput(this.config.selectedEnvironment.startCommand);
        return;
      case "envVar": {
        const variable = this.config.data.globalEnvironment[entry.index];
        this.editing = new TextInput(`${variable.key}=${variable.value}`);
        return;
      }
      case "addEnvVar":
        this.editing = new TextInput("KEY=value");
        return;
      case "deleteEnvironment":
        this.deleteEnvironment();
        return;
      case "resetEnvironments":
        this.resetEnvironments();
        return;
      case "cliLogin":
        // Nothing to edit here — but asking the CLI again is exactly what you
        // want right after logging in in the window next door.
        void this.workspace.refreshCLICredentials();
        return;
      default:
        // provider and environment: dropdowns, which open their list instead.
        this.openList();
    }
  }

  private commitArea(): void {
    const entry = this.rows[this.selection];
    const value = this.area?.value ?? "";
    this.area = null;
    if (entry?.kind !== "textArea") return;
    if (entry.field === "setupScript") {
      this.updateEnvironment((environment) => {
        environment.setupScript = value;
      });
    } else {
      this.config.data.piSettings = value;
    }
    this.config.save();
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

  /**
   * Drop the environment currently selected, and fall in behind whichever one
   * takes its place. Never the last one: `selectedEnvironment` would fall back
   * to a blank, and a session started on that runs nothing.
   */
  private deleteEnvironment(): void {
    const environments = this.config.data.environments;
    if (environments.length <= 1) return;
    const index = environments.findIndex((one) => one.id === this.config.selectedEnvironment.id);
    if (index === -1) return;
    environments.splice(index, 1);
    const next = environments[Math.min(index, environments.length - 1)];
    this.config.data.selectedEnvironmentID = next?.id ?? null;
    this.config.save();
  }

  /** Back to what a fresh install starts with, edits and additions included. */
  private resetEnvironments(): void {
    this.config.data.environments = defaultEnvironments();
    this.config.data.selectedEnvironmentID = this.config.data.environments[0]?.id ?? null;
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
