/** Higher-level exe.dev operations composed from CLI commands. */

import { ExeClient, ExeError } from "./exe-client.ts";
import { condense } from "../model/message-text.ts";
import { MINT_TOKEN_COMMAND } from "../model/auto-name.ts";
import type { EnvVar } from "../config/env-var.ts";

/** A VM as returned by `new --json` / `ls --json`. */
export interface ExeVM {
  vm_name?: string | null;
  ssh_dest?: string | null;
  https_url?: string | null;
  status?: string | null;
  region?: string | null;
  tags?: string[] | null;
}

export class ExeService {
  constructor(readonly client: ExeClient) {}

  /** Existing VMs on the account, so a closed session can be reopened. */
  async listVMs(): Promise<ExeVM[]> {
    const list = await this.client.runJSON<{ vms: ExeVM[] }>("ls --json");
    return list.vms ?? [];
  }

  /** Destroy a VM and its disk. Irreversible. */
  async deleteVM(name: string): Promise<void> {
    await this.client.run(`rm ${name}`);
  }

  /**
   * Mint the token a VM renames itself with — scoped to `rename` alone, so it
   * can sit on a machine an agent runs unattended on.
   *
   * Throws when the account's own token isn't allowed to mint one, which is the
   * common case until `ssh-key generate-api-key` is added to its `cmds`.
   */
  async generateRenameToken(): Promise<string> {
    const body = await this.client.run(MINT_TOKEN_COMMAND);
    const token = apiKeyFrom(body);
    if (!token) throw new ExeError(`No API key in exe.dev's reply: ${condense(body)}`);
    return token;
  }

  /**
   * Create a VM with the given tags (so tag-attached integrations bind to it)
   * and environment variables set on the host.
   */
  createVM(name: string, tags: string[], environment: EnvVar[] = []): Promise<ExeVM> {
    let command = `new --name ${name} --json`;
    if (tags.length > 0) command += ` --tag ${tags.join(",")}`;
    for (const variable of environment) {
      if (!variable.key) continue;
      command += ` --env ${exeQuote(`${variable.key}=${variable.value}`)}`;
    }
    return this.client.runJSON<ExeVM>(command);
  }
}

/**
 * The token out of `ssh-key generate-api-key --json`.
 *
 * Found by shape rather than by key name: exe.dev tokens are `exe0.`/`exe1.`
 * strings, and that is the one thing about this response worth relying on — a
 * renamed field would otherwise turn auto-naming off silently.
 */
export function apiKeyFrom(body: string): string | null {
  try {
    return tokenIn(JSON.parse(body) as unknown);
  } catch {
    return null;
  }
}

function tokenIn(value: unknown): string | null {
  if (typeof value === "string") {
    return value.startsWith("exe0.") || value.startsWith("exe1.") ? value : null;
  }
  if (Array.isArray(value)) {
    for (const entry of value) {
      const found = tokenIn(entry);
      if (found) return found;
    }
    return null;
  }
  if (typeof value === "object" && value !== null) {
    // Sorted so a response with two token-shaped values resolves the same way
    // every time rather than on property order.
    const keys = Object.keys(value as Record<string, unknown>).sort();
    for (const key of keys) {
      const found = tokenIn((value as Record<string, unknown>)[key]);
      if (found) return found;
    }
  }
  return null;
}

/**
 * Single-quote an argument for the exe.dev command parser, so values with
 * spaces or shell metacharacters survive intact.
 */
export function exeQuote(argument: string): string {
  return `'${argument.replaceAll("'", "'\\''")}'`;
}
