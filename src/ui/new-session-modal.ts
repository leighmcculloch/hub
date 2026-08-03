/**
 * The new-session flow: choose a name, environment and model, pick GitHub
 * repos, then provision a VM and open a session on it. The second tab reopens a
 * VM that already exists on the account.
 */

import { Color, elideMiddle, fit, styled } from "../tui/ansi.ts";
import {
  control,
  dropdown,
  type HitMap,
  panel,
  type Rect,
  row as listRow,
  TextInput,
  wrap,
} from "../tui/widgets.ts";
import { vmNameFrom } from "../model/bootstrap.ts";
import { modelLabel } from "../model/llm-gateway.ts";
import { normalizeRepo } from "../github/repo-reference.ts";
import { SelectPopup } from "./select-popup.ts";
import type { SessionProvisioner } from "../model/session-provisioner.ts";
import type { AppConfig } from "../config/app-config.ts";
import type { Workspace } from "../model/workspace.ts";
import type { VMProviderID } from "../providers/types.ts";
import { ALL_PROVIDERS, providerLabel } from "../model/provider-label.ts";

type Field =
  | "provider"
  | "name"
  | "environment"
  | "model"
  | "search"
  | "repos"
  | "manual"
  | "submit";

const CREATE_FIELDS: Field[] = [
  "provider",
  "name",
  "environment",
  "model",
  "search",
  "repos",
  "manual",
  "submit",
];

export class NewSessionModal {
  mode: "create" | "reopen" = "create";
  private field: Field = "name";
  private nameInput = new TextInput();
  private searchInput = new TextInput();
  private manualInput = new TextInput();
  private repoIndex = 0;
  private repoOffset = 0;
  private vmIndex = 0;
  /**
   * Which account a new VM goes on. Starts at the configured default; both
   * providers are always offered, since a provider you have no token for is
   * one you may simply not have set up yet.
   */
  private providerID: VMProviderID;
  private hovered: string | null = null;
  private caret: { x: number; y: number } | null = null;

  constructor(
    private workspace: Workspace,
    private config: AppConfig,
    public provisioner: SessionProvisioner,
    private onClose: () => void,
    private onOpenPopup: (popup: SelectPopup) => void,
  ) {
    this.providerID = config.data.provider;
  }

  /** Which account new VMs go on, and the heading that says so. */
  private reopenHeading(): string {
    return this.workspace.configuredProviders.length > 1
      ? "VMs on your accounts"
      : "VMs on your account";
  }

  /**
   * Change which account this session provisions on. The provisioner is bound
   * to one provider, so it is rebuilt — the repo and model choices already made
   * are carried over, since neither depends on the VM host.
   */
  private selectProvider(provider: VMProviderID): void {
    if (provider === this.providerID) return;
    this.providerID = provider;
    const kept = this.provisioner;
    const next = this.workspace.makeProvisioner(provider);
    next.sessionName = kept.sessionName;
    next.search = kept.search;
    next.manualRepo = kept.manualRepo;
    next.selected = kept.selected;
    next.repos = kept.repos;
    next.reposError = kept.reposError;
    next.models = kept.models;
    next.modelsError = kept.modelsError;
    this.provisioner = next;
    // The catalogue is the new provider's, not the old one's: exe.dev's gateway
    // and OpenRouter list different models, and Namespace lists none at all.
    // The carried-over list stays on screen until the new one answers.
    void next.loadModels();
  }

  /** Step to the next provider chip, wrapping. */
  private stepProvider(step: number): void {
    const at = ALL_PROVIDERS.indexOf(this.providerID);
    const next = (at + step + ALL_PROVIDERS.length) % ALL_PROVIDERS.length;
    this.selectProvider(ALL_PROVIDERS[next]);
  }

  /** Kick off the loads the picker needs. Safe to call once, on open. */
  load(): void {
    void this.provisioner.loadModels();
    void this.provisioner.loadRepos();
    // The reopen tab shows the workspace's own list, which already covers every
    // configured provider; refreshing it here keeps the modal current.
    void this.workspace.loadAvailableVMs();
  }

  // MARK: - Rendering

  render(cols: number, rows: number, hits: HitMap): { lines: string[]; rect: Rect } {
    const width = Math.min(78, cols - 4);
    const height = Math.min(28, rows - 2);
    const rect: Rect = {
      x: Math.floor((cols - width) / 2),
      y: Math.floor((rows - height) / 2),
      width,
      height,
    };
    const inner = width - 2;
    const body = this.provisioner.phase === "picking"
      ? this.renderPicker(inner, height - 2, rect, hits)
      : this.renderProgress(inner, height - 2);
    return { lines: panel(width, height, "New Session", body, { bg: Color.panel }), rect };
  }

  private renderProgress(width: number, height: number): string[] {
    const lines: string[] = [fit("", width, { bg: Color.panel })];
    for (const line of this.provisioner.statusLines) {
      for (const wrapped of wrap(line, width - 2)) {
        lines.push(fit(` ${styled(wrapped, { fg: Color.fg, bg: Color.panel })}`, width, {
          bg: Color.panel,
        }));
      }
    }
    if (this.provisioner.errorMessage) {
      lines.push(fit("", width, { bg: Color.panel }));
      for (const wrapped of wrap(this.provisioner.errorMessage, width - 2)) {
        lines.push(fit(` ${styled(wrapped, { fg: Color.red, bg: Color.panel })}`, width, {
          bg: Color.panel,
        }));
      }
      lines.push(fit("", width, { bg: Color.panel }));
      lines.push(
        fit(` ${styled("Esc to close", { fg: Color.dimmer, bg: Color.panel })}`, width, {
          bg: Color.panel,
        }),
      );
    }
    while (lines.length < height) lines.push(fit("", width, { bg: Color.panel }));
    return lines.slice(0, height);
  }

  private renderPicker(width: number, height: number, rect: Rect, hits: HitMap): string[] {
    const lines: string[] = [];
    // Recomputed every frame: the focused field, and so the caret, moves.
    this.caret = null;
    const originX = rect.x + 1;
    const originY = rect.y + 1;
    const put = (text: string) => lines.push(fit(text, width, { bg: Color.panel }));
    const register = (id: string, height_ = 1) => {
      hits.add({ x: originX, y: originY + lines.length, width, height: height_ }, id);
    };

    // Mode switch. Both chips live on one line, so each claims its own span of
    // it rather than the whole row.
    hits.add({ x: originX + 1, y: originY + lines.length, width: 11, height: 1 }, "new.create");
    hits.add({ x: originX + 14, y: originY + lines.length, width: 11, height: 1 }, "new.reopen");
    put(
      ` ${
        control(" Create VM ", {
          active: this.mode === "create",
          hovered: this.hovered === "new.create",
        })
      }  ${
        control(" Reopen VM ", {
          active: this.mode === "reopen",
          hovered: this.hovered === "new.reopen",
        })
      }`,
    );
    put("");

    if (this.mode === "reopen") {
      return this.renderReopen(lines, width, height, originX, originY, hits);
    }

    // Which account to create on. Always shown, and as chips rather than a
    // dropdown: with a list you have to open it to discover the app can talk to
    // two providers at all, which is exactly the thing worth being obvious.
    let chipX = originX + 11;
    let chips = ` ${styled("Provider  ", { fg: Color.dim, bg: Color.panel })}`;
    for (const id of ALL_PROVIDERS) {
      const label = ` ${providerLabel(id)} `;
      const chipID = `new.provider:${id}`;
      hits.add({ x: chipX, y: originY + lines.length, width: label.length, height: 1 }, chipID);
      chips += control(label, {
        active: id === this.providerID,
        focused: this.field === "provider" && id === this.providerID,
        hovered: this.hovered === chipID,
      }) + " ";
      chipX += label.length + 1;
    }
    // A provider that isn't set up is still offered: selecting it is how you
    // find out what it needs, and the line below says so.
    if (!this.workspace.isConfigured(this.providerID)) {
      const kind = this.workspace.providerFor(this.providerID).credential.kind;
      chips += styled(kind === "cli" ? "not ready" : "no token", {
        fg: Color.orange,
        bg: Color.panel,
      });
    }
    put(chips);
    put("");

    // Name.
    put(` ${styled("Session name", { fg: Color.dim, bg: Color.panel })}`);
    register("new.name");
    this.placeCaret("name", this.nameInput, originX + 1, originY + lines.length, width - 2);
    put(
      ` ${
        this.nameInput.render(
          width - 2,
          this.field === "name",
          "optional",
          this.hovered === "new.name",
        )
      }`,
    );
    const typed = this.nameInput.value.trim();
    const preview = typed
      ? `VM name: ${vmNameFrom(typed)}`
      : "Unnamed — the VM names itself from the agent's first prompt.";
    put(` ${styled(elideMiddle(preview, width - 2), { fg: Color.dimmer, bg: Color.panel })}`);
    put("");

    // Environment and model: dropdowns, so their whole lists are one click away.
    const environment = this.config.selectedEnvironment;
    register("new.environment");
    put(
      ` ${styled("Environment", { fg: Color.dim, bg: Color.panel })} ` +
        dropdown(environment.name || "Untitled", width - 14, {
          focused: this.field === "environment",
          hovered: this.hovered === "new.environment",
        }),
    );
    register("new.model");
    const model = this.config.data.model;
    put(
      ` ${styled("Model      ", { fg: Color.dim, bg: Color.panel })} ` +
        dropdown(model ? modelLabel(model) : "Custom — the VM's own setup", width - 14, {
          focused: this.field === "model",
          hovered: this.hovered === "new.model",
        }),
    );
    if (this.provisioner.modelsError) {
      put(
        ` ${
          styled(elideMiddle(this.provisioner.modelsError, width - 2), {
            fg: Color.orange,
            bg: Color.panel,
          })
        }`,
      );
    }
    if (!this.workspace.isConfigured(this.providerID)) {
      const provider = this.workspace.providerFor(this.providerID);
      const credential = provider.credential;
      // What to do about it, in the provider's own terms: a token to paste, or
      // a command to run.
      put(
        ` ${
          styled(
            credential.kind === "cli"
              ? `${provider.displayName} needs the ${credential.binary} CLI — run \`${credential.loginCommand}\``
              : `No ${provider.displayName} token — set one in Settings (Alt+,) or ` +
                credential.envVar,
            { fg: Color.orange, bg: Color.panel },
          )
        }`,
      );
    }
    put("");

    // Repositories.
    const chosen = this.provisioner.chosenRepos;
    put(
      ` ${styled("Repositories to clone", { fg: Color.dim, bg: Color.panel })}  ` +
        styled(
          chosen.length === 0 ? "none selected" : `${chosen.length} selected`,
          { fg: Color.dimmer, bg: Color.panel },
        ),
    );
    register("new.search");
    this.placeCaret("search", this.searchInput, originX + 1, originY + lines.length, width - 2);
    put(
      ` ${
        this.searchInput.render(
          width - 2,
          this.field === "search",
          "Filter repositories…",
          this.hovered === "new.search",
        )
      }`,
    );

    const listTop = lines.length;
    const listHeight = Math.max(3, height - listTop - 6);
    const repos = this.provisioner.filteredRepos;
    this.repoIndex = Math.min(Math.max(0, this.repoIndex), Math.max(0, repos.length - 1));
    if (this.repoIndex < this.repoOffset) this.repoOffset = this.repoIndex;
    if (this.repoIndex >= this.repoOffset + listHeight) {
      this.repoOffset = this.repoIndex - listHeight + 1;
    }
    for (let index = 0; index < listHeight; index += 1) {
      const repo = repos[this.repoOffset + index];
      if (!repo) {
        put(
          index === 0 && repos.length === 0
            ? ` ${
              styled(
                this.provisioner.loadingRepos
                  ? "Loading repositories…"
                  : this.provisioner.reposError ?? "No repositories found.",
                { fg: Color.dimmer, bg: Color.panel },
              )
            }`
            : "",
        );
        continue;
      }
      const id = `new.repo:${this.repoOffset + index}`;
      hits.add({ x: originX, y: originY + lines.length, width, height: 1 }, id);
      const checked = this.provisioner.selected.has(repo.fullName);
      const box = checked
        ? styled("[x]", { fg: Color.accent, bg: Color.panel })
        : styled("[ ]", { fg: Color.dimmer, bg: Color.panel });
      const lock = repo.isPrivate ? styled("🔒", { fg: Color.dimmer, bg: Color.panel }) : "  ";
      const text = `${box} ${lock} ${elideMiddle(repo.fullName, Math.max(8, width - 10))}`;
      const active = this.field === "repos" && this.repoOffset + index === this.repoIndex;
      lines.push(
        fit(
          listRow(text, width, { selected: active, hovered: this.hovered === id, focused: true }),
          width,
          {
            bg: Color.panel,
          },
        ),
      );
    }

    // Manual entry and the action row.
    register("new.manual");
    this.placeCaret("manual", this.manualInput, originX + 1, originY + lines.length, width - 2);
    put(
      ` ${
        this.manualInput.render(
          width - 2,
          this.field === "manual",
          "owner/repo or a URL",
          this.hovered === "new.manual",
        )
      }`,
    );
    if (this.manualInput.value.trim() && !normalizeRepo(this.manualInput.value)) {
      put(
        ` ${
          styled("Use the owner/repo form, e.g. apple/swift.", {
            fg: Color.orange,
            bg: Color.panel,
          })
        }`,
      );
    }
    hits.add({ x: originX + 1, y: originY + lines.length, width: 16, height: 1 }, "new.submit");
    put(
      ` ${
        control(" Create Session ", {
          focused: this.field === "submit",
          hovered: this.hovered === "new.submit",
          active: true,
        })
      }  ` +
        styled("Esc cancels · Tab moves · Space toggles", { fg: Color.dimmer, bg: Color.panel }),
    );

    while (lines.length < height) lines.push(fit("", width, { bg: Color.panel }));
    return lines.slice(0, height);
  }

  private renderReopen(
    lines: string[],
    width: number,
    height: number,
    originX: number,
    originY: number,
    hits: HitMap,
  ): string[] {
    const vms = this.workspace.availableVMs;
    lines.push(
      fit(
        ` ${styled(this.reopenHeading(), { fg: Color.dim, bg: Color.panel })}  ` +
          styled(this.workspace.loadingVMs ? "◌" : `${vms.length}`, {
            fg: Color.dimmer,
            bg: Color.panel,
          }),
        width,
        { bg: Color.panel },
      ),
    );
    const listHeight = height - lines.length - 2;
    this.vmIndex = Math.min(Math.max(0, this.vmIndex), Math.max(0, vms.length - 1));
    for (let index = 0; index < listHeight; index += 1) {
      const vm = vms[index];
      if (!vm) {
        lines.push(fit("", width, { bg: Color.panel }));
        continue;
      }
      const id = `new.vm:${index}`;
      hits.add({ x: originX, y: originY + lines.length, width, height: 1 }, id);
      const running = vm.status === "running";
      // Which account it's on, when there is more than one to be on.
      const where = this.workspace.configuredProviders.length > 1
        ? ` ${styled(providerLabel(vm.provider), { fg: Color.dimmer, bg: Color.panel })}`
        : "";
      const text =
        `${styled("•", { fg: running ? Color.green : Color.dimmer, bg: Color.panel })} ` +
        `${elideMiddle(vm.name, Math.max(8, width - 30))} ` +
        styled(vm.status ?? "", { fg: Color.dimmer, bg: Color.panel }) + where;
      lines.push(
        fit(
          listRow(text, width, {
            selected: index === this.vmIndex,
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
        ` ${styled("Enter opens · Esc cancels", { fg: Color.dimmer, bg: Color.panel })}`,
        width,
        { bg: Color.panel },
      ),
    );
    while (lines.length < height) lines.push(fit("", width, { bg: Color.panel }));
    return lines.slice(0, height);
  }

  /**
   * Note where the caret belongs while laying a field out, so the app can put
   * the terminal's own cursor there once the frame is composed.
   */
  private placeCaret(field: Field, input: TextInput, x: number, y: number, width: number): void {
    if (this.field !== field) return;
    this.caret = { x: x + input.cursorOffset(width), y };
  }

  /** Where the caret goes this frame, or null when no field has the keyboard. */
  cursorPosition(): { x: number; y: number } | null {
    return this.caret;
  }

  // MARK: - Interaction

  setHover(id: string | null): void {
    this.hovered = id;
  }

  /** Returns true when the modal should close. */
  async key(
    event: { name: string; ctrl: boolean; alt: boolean; shift: boolean },
  ): Promise<boolean> {
    if (this.provisioner.phase !== "picking") {
      // Nothing to type into while it provisions; Esc dismisses a failure.
      return event.name === "escape";
    }
    if (event.name === "escape") return true;

    if (this.mode === "reopen") {
      switch (event.name) {
        case "up":
          this.vmIndex = Math.max(0, this.vmIndex - 1);
          return false;
        case "down":
          this.vmIndex = Math.min(this.workspace.availableVMs.length - 1, this.vmIndex + 1);
          return false;
        case "tab":
          this.mode = "create";
          return false;
        case "enter": {
          const vm = this.workspace.availableVMs[this.vmIndex];
          if (vm) {
            this.workspace.reopen(vm);
            return true;
          }
          return false;
        }
        default:
          return false;
      }
    }

    if (event.name === "tab") {
      const index = Math.max(0, CREATE_FIELDS.indexOf(this.field));
      const step = event.shift ? -1 : 1;
      this.field = CREATE_FIELDS[(index + step + CREATE_FIELDS.length) % CREATE_FIELDS.length];
      return false;
    }

    switch (this.field) {
      case "name":
        if (event.name === "enter") {
          this.field = "environment";
          return false;
        }
        this.nameInput.handle(event);
        this.provisioner.sessionName = this.nameInput.value;
        return false;
      case "search":
        if (event.name === "enter") {
          this.field = "repos";
          return false;
        }
        this.searchInput.handle(event);
        this.provisioner.search = this.searchInput.value;
        this.repoIndex = 0;
        return false;
      case "manual":
        if (event.name === "enter") {
          this.field = "submit";
          return false;
        }
        this.manualInput.handle(event);
        this.provisioner.manualRepo = this.manualInput.value;
        return false;
      case "provider":
        if (
          event.name === "left" || event.name === "right" ||
          event.name === "enter" || event.name === "space"
        ) {
          this.stepProvider(event.name === "left" ? -1 : 1);
        }
        return false;
      case "environment":
        // Enter and Space open the list; the arrows step without opening it.
        if (event.name === "enter" || event.name === "space" || event.name === "down") {
          this.openEnvironmentPopup();
        } else if (event.name === "left") this.stepEnvironment(-1);
        else if (event.name === "right") this.stepEnvironment(1);
        return false;
      case "model":
        if (event.name === "enter" || event.name === "space" || event.name === "down") {
          this.openModelPopup();
        } else if (event.name === "left") this.stepModel(-1);
        else if (event.name === "right") this.stepModel(1);
        return false;
      case "repos": {
        const repos = this.provisioner.filteredRepos;
        if (event.name === "up") this.repoIndex = Math.max(0, this.repoIndex - 1);
        else if (event.name === "down") {
          this.repoIndex = Math.min(repos.length - 1, this.repoIndex + 1);
        } else if (event.name === "space" || event.name === "enter") {
          const repo = repos[this.repoIndex];
          if (repo) this.provisioner.toggleRepo(repo.fullName);
        }
        return false;
      }
      case "submit":
        if (event.name === "enter" || event.name === "space") return await this.submit();
        return false;
    }
  }

  /** Returns true when the modal should close. */
  async click(id: string, _shift: boolean): Promise<boolean> {
    if (id === "new.create" || id === "new.reopen") {
      this.mode = id === "new.create" ? "create" : "reopen";
      return false;
    }
    if (id === "new.name") {
      this.field = "name";
      return false;
    }
    if (id === "new.search") {
      this.field = "search";
      return false;
    }
    if (id === "new.manual") {
      this.field = "manual";
      return false;
    }
    if (id.startsWith("new.provider:")) {
      this.field = "provider";
      this.selectProvider(id.slice("new.provider:".length) as VMProviderID);
      return false;
    }
    if (id === "new.environment") {
      this.field = "environment";
      this.openEnvironmentPopup();
      return false;
    }
    if (id === "new.model") {
      this.field = "model";
      this.openModelPopup();
      return false;
    }
    if (id === "new.submit") return await this.submit();
    if (id.startsWith("new.repo:")) {
      const index = Number(id.slice("new.repo:".length));
      const repo = this.provisioner.filteredRepos[index];
      if (repo) {
        this.field = "repos";
        this.repoIndex = index;
        this.provisioner.toggleRepo(repo.fullName);
      }
      return false;
    }
    if (id.startsWith("new.vm:")) {
      const vm = this.workspace.availableVMs[Number(id.slice("new.vm:".length))];
      if (vm) {
        this.workspace.reopen(vm);
        return true;
      }
    }
    return false;
  }

  scroll(delta: number): void {
    if (this.mode === "reopen") {
      this.vmIndex = Math.max(
        0,
        Math.min(this.workspace.availableVMs.length - 1, this.vmIndex + delta),
      );
      return;
    }
    this.repoOffset = Math.max(0, this.repoOffset + delta);
  }

  /** Step the environment without opening its list, for the arrow keys. */
  private stepEnvironment(step: number): void {
    const environments = this.config.data.environments;
    if (environments.length === 0) return;
    const current = environments.findIndex((one) => one.id === this.config.selectedEnvironment.id);
    const next = (current + step + environments.length) % environments.length;
    this.config.data.selectedEnvironmentID = environments[next].id;
    this.config.save();
  }

  /** Step the model without opening its list. */
  private stepModel(step: number): void {
    const options = [null, ...this.provisioner.modelOptions];
    const selected = this.config.data.model;
    const current = options.findIndex((option) =>
      option === null
        ? selected === null
        : selected !== null && option.provider === selected.provider &&
          option.model === selected.model
    );
    this.config.data.model = options[(current + step + options.length) % options.length];
    this.config.save();
  }

  /** The environment list, as a dropdown rather than a value to step through. */
  private openEnvironmentPopup(): void {
    const environments = this.config.data.environments;
    if (environments.length === 0) return;
    const current = environments.findIndex((one) => one.id === this.config.selectedEnvironment.id);
    this.onOpenPopup(
      new SelectPopup(
        "Environment",
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

  /**
   * The model list. The catalogue runs to hundreds of entries, which is exactly
   * why this is a filterable popup and not a value you arrow through.
   */
  private openModelPopup(): void {
    // null — "Custom" — is one of the options, hence the leading slot.
    const options = [null, ...this.provisioner.modelOptions];
    const selected = this.config.data.model;
    const current = options.findIndex((option) =>
      option === null
        ? selected === null
        : selected !== null && option.provider === selected.provider &&
          option.model === selected.model
    );
    this.onOpenPopup(
      new SelectPopup(
        "Model",
        options.map((option) =>
          option === null
            ? { label: "Custom", detail: "leave the VM's own setup" }
            : { label: modelLabel(option), detail: option.model }
        ),
        Math.max(0, current),
        (index) => {
          this.config.data.model = options[index];
          this.config.save();
        },
      ),
    );
  }

  private async submit(): Promise<boolean> {
    this.provisioner.sessionName = this.nameInput.value;
    this.provisioner.manualRepo = this.manualInput.value;
    const result = await this.provisioner.provision(this.workspace.gitIdentity);
    if (!result) return false; // the failure is shown in place
    this.workspace.addSession({
      title: result.title,
      provider: this.workspace.providerFor(this.providerID),
      destination: result.destination,
      bootstrap: result.bootstrap,
      vmName: result.vmName,
      webURL: result.webURL,
      autoName: result.autoName,
    });
    void this.workspace.loadAvailableVMs();
    this.onClose();
    return true;
  }
}
