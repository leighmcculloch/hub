/** Higher-level exe.dev operations composed from CLI commands. */

import { ExeClient, ExeError } from "./exe-client.ts";
import { condense } from "../model/message-text.ts";
import { MINT_TOKEN_COMMAND } from "../model/auto-name.ts";
import type { EnvVar } from "../config/env-var.ts";

/** One integration as returned by `integrations list --json`. */
export interface ExeIntegration {
  name: string;
  type: string;
  attachments?: string[] | null;
  config?: { repositories?: string[] | null; act_as_user?: boolean | null } | null;
}

/** A VM as returned by `new --json` / `ls --json`. */
export interface ExeVM {
  vm_name?: string | null;
  ssh_dest?: string | null;
  https_url?: string | null;
  status?: string | null;
  region?: string | null;
  tags?: string[] | null;
}

/** The first `tag:<name>` an integration is attached to, if any. */
export function attachedTag(integration: ExeIntegration): string | null {
  for (const attachment of integration.attachments ?? []) {
    if (attachment.startsWith("tag:")) return attachment.slice("tag:".length);
  }
  return null;
}

export class ExeService {
  constructor(readonly client: ExeClient) {}

  listIntegrations(): Promise<ExeIntegration[]> {
    return this.client.runJSON<ExeIntegration[]>("integrations list --json");
  }

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
   * Ensure a GitHub integration exists for `repo` ("owner/name") and return the
   * tag that binds it to a VM, creating the integration (acting as the user) if
   * it doesn't already exist.
   */
  async ensureGithubIntegration(repo: string, existing: ExeIntegration[]): Promise<string> {
    const slug = repoSlug(repo);

    const match = existing.find((integration) =>
      integration.type === "github" && (integration.config?.repositories ?? []).includes(repo)
    );
    if (match) {
      const tag = attachedTag(match);
      if (tag) return tag;
      // Integration exists but isn't tag-attached; attach a tag we can bind.
      await this.client.run(`integrations attach ${match.name} tag:${slug}`);
      return slug;
    }

    await this.client.run(
      `integrations add github --name ${slug} --repository ${repo} --act-as-user --attach tag:${slug}`,
    );
    return slug;
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

/**
 * Slug used for integration name and tag, e.g. "owner/Repo.Name" →
 * "owner-repo-name".
 *
 * exe.dev requires tag names to match `^[a-z][a-z0-9_-]*$`, so a repo whose
 * owner starts with a digit (e.g. `4d63/x`) must be prefixed rather than passed
 * through.
 */
export function repoSlug(repo: string): string {
  const slug = repo.toLowerCase().replace(/[^a-z0-9_-]/g, "-");
  return /^[a-z]/.test(slug) ? slug : `r-${slug}`;
}
