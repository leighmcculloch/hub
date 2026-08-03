/**
 * sprites.dev as a `VMProvider`: the REST API at `api.sprites.dev` for sprite
 * lifecycle, the `sprite` CLI for running commands, GitHub cloning via a token
 * in the sprite's environment, and sprites.dev's own LLM gateway.
 *
 * Unlike exe.dev, sprites.dev has no `rename` and no reflection endpoint, so
 * `supportsAutoNaming` is false. VMs are reached by name through the `sprite`
 * CLI, not by a direct SSH hostname.
 */

import { type Sprite, SpritesClient, SpritesError } from "./sprites-client.ts";
import { SpritesCLITransport } from "./sprites-cli-transport.ts";
import { profileEnvironmentSetup } from "../model/bootstrap.ts";
import { tokenGitHubSetup } from "./github-setup.ts";
import {
  codexConfig,
  describe,
  gatewayEnvironment,
  type GatewayModel,
  piProvider,
  piSettings,
} from "../model/llm-gateway.ts";
import { PROXY_BASE_URL, proxyInstallFragment } from "../model/sprite-llm-proxy.ts";
import type {
  GitHubSetup,
  HarnessWiring,
  LLMGatewayConfig,
  ModelListing,
  ProviderCredential,
  RemoteTransport,
  RemoteVMRecord,
  VMProvider,
  VMProviderID,
} from "./types.ts";
import type { EnvVar } from "../config/env-var.ts";

/**
 * The harness config is the same shape as exe.dev's (env vars + Codex/pi files)
 * but pointed at the on-sprite proxy, which forwards through the OpenRouter
 * connector gateway. The catalogue is OpenRouter's public model list.
 */
const PROXY_GATEWAY: LLMGatewayConfig = {
  baseURL: PROXY_BASE_URL,
  providerName: "sprites-llm",
  catalogURL: "https://openrouter.ai/api/v1/models",
};

export class SpritesProvider implements VMProvider {
  readonly id: VMProviderID = "sprites";
  readonly displayName = "sprites.dev";
  readonly defaultBrowserURL = "https://sprites.dev";
  readonly supportsAutoNaming = false;
  readonly credential: ProviderCredential = { kind: "token", envVar: "SPRITE_TOKEN" };
  readonly reflectionNameCommand = null;

  private client: SpritesClient;

  constructor(private tokenProvider: () => string) {
    this.client = new SpritesClient(tokenProvider);
  }

  effectiveToken(): string {
    return this.tokenProvider();
  }

  checkAvailable(): Promise<boolean> {
    return Promise.resolve(this.effectiveToken() !== "");
  }

  // MARK: - LLM gateway

  async listModels(): Promise<ModelListing> {
    try {
      const response = await fetch(PROXY_GATEWAY.catalogURL);
      if (!response.ok) {
        return { models: [], error: `Couldn't load the model list (HTTP ${response.status}).` };
      }
      const catalog = await response.json() as { data?: Array<{ id?: unknown }> };
      const models: GatewayModel[] = [];
      for (const entry of catalog.data ?? []) {
        if (typeof entry.id === "string") models.push({ provider: "openrouter", model: entry.id });
      }
      return { models, error: null };
    } catch (error) {
      return { models: [], error: `Couldn't load the model list: ${describe(error)}` };
    }
  }

  /**
   * Same env/Codex/pi shape as exe.dev, but the base URL is the proxy and the
   * setup fragment installs and starts it before the harness reads its config.
   * All sprites models route over OpenAI Chat Completions (the gateway is
   * OpenRouter), so pi uses openai-completions for every model.
   */
  harnessWiring(model: GatewayModel): HarnessWiring {
    return {
      marker: PROXY_GATEWAY.providerName,
      setup: proxyInstallFragment(),
      hostEnvironment: gatewayEnvironment(model, PROXY_GATEWAY),
      codexConfig: codexConfig(model, PROXY_GATEWAY),
      piProvider: piProvider(model, PROXY_GATEWAY),
      piSettings: piSettings(model, PROXY_GATEWAY),
    };
  }

  // MARK: - Host environment

  /**
   * sprites.dev has no API to set host env, so the bootstrap writes the env
   * into a profile and sources it — the same fragment Namespace uses, for the
   * same reason.
   */
  hostEnvironmentSetup(environment: EnvVar[]): string {
    return profileEnvironmentSetup(environment);
  }

  // MARK: - VM lifecycle

  async listVMs(): Promise<RemoteVMRecord[]> {
    // The list endpoint returns names only, so GET each sprite for its URL and
    // status — the sidebar shows both, and a reopened session needs the URL.
    const names = await this.client.listNames();
    const records: RemoteVMRecord[] = [];
    for (const name of names) {
      try {
        records.push(recordFromSprite(await this.client.get(name)));
      } catch {
        // One unreadable sprite shouldn't empty the list.
      }
    }
    return records;
  }

  async createVM(
    name: string,
    _tags: string[],
    _environment: EnvVar[],
  ): Promise<RemoteVMRecord> {
    // Tags are exe.dev's integration-binding mechanism; sprites.dev's create
    // body has no labels in the documented API, so they're ignored. The
    // environment is injected by the bootstrap rather than set here.
    const created = await this.client.create(name);
    // Read back the URL and status the create response may have omitted.
    const current = await this.client.get(name).catch(() => created);
    return recordFromSprite(current);
  }

  deleteVM(name: string): Promise<void> {
    return this.client.delete(name);
  }

  // MARK: - GitHub

  /** The token every provider clones with, in the sprite's environment. */
  prepareGitHub(repos: string[]): Promise<GitHubSetup> {
    return tokenGitHubSetup(repos);
  }

  // MARK: - Auto-naming (not supported)

  generateRenameToken(): Promise<string> {
    // Unreachable: `supportsAutoNaming` is false, so the provisioner never
    // calls this. Rejecting rather than returning a token that could not work.
    return Promise.reject(new SpritesError("sprites.dev does not support auto-naming."));
  }

  // MARK: - Naming and reachability

  /** A sprite's transport handle is its name — `sprite exec -s <name>`. */
  destinationForVMName(name: string): string {
    return name;
  }

  /**
   * A sprite's URL carries an org id the name alone doesn't, so this returns
   * null; the session's web URL is stored from the VM record at creation.
   */
  webURLForDestination(_destination: string): string | null {
    return null;
  }

  parseReflectedName(_output: string): string | null {
    return null;
  }

  transportFor(destination: string): RemoteTransport {
    return new SpritesCLITransport(destination);
  }
}

export function recordFromSprite(sprite: Sprite): RemoteVMRecord {
  return {
    name: sprite.name,
    destination: sprite.name,
    webURL: sprite.url ?? null,
    status: sprite.status ?? null,
    provider: "sprites",
  };
}
