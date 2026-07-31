/**
 * A provider's LLM gateway: the model catalogue, and the configuration a
 * selected model needs on the VM. Parameterised by `LLMGatewayConfig` so the
 * same logic serves exe.dev and sprites.dev — only the base URL, provider name
 * and catalogue URL differ.
 *
 * Claude Code is configured through environment variables set on the VM host;
 * Codex and pi through files written during bootstrap. Nothing here is
 * harness-specific beyond those three.
 */

import type { EnvVar } from "../config/env-var.ts";
import type { HarnessWiring, LLMGatewayConfig, ModelListing } from "../providers/types.ts";

/** A model offered by a provider's LLM gateway. */
export interface GatewayModel {
  /** The gateway's provider, e.g. `anthropic` or `fireworks`. */
  provider: string;
  /** The id the gateway routes on. Passed to the harnesses verbatim. */
  model: string;
}

export function modelID(model: GatewayModel): string {
  return `${model.provider}/${model.model}`;
}

/**
 * What the picker shows. The provider qualifies models whose id doesn't name
 * it, and only the last path component is kept, so
 * `accounts/fireworks/models/glm-5p2` reads as `fireworks/glm-5p2`.
 */
export function modelLabel(model: GatewayModel): string {
  const tail = model.model.split("/").pop() ?? model.model;
  return `${model.provider}/${tail}`;
}

/**
 * Variables set on the VM host, so every process sees them.
 *
 * Claude Code insists on an API key even where the gateway needs none, so it
 * gets a placeholder; the OAuth token is blanked so a token set by the session
 * environment can't win over the gateway.
 */
export function gatewayEnvironment(model: GatewayModel, config: LLMGatewayConfig): EnvVar[] {
  return [
    { key: "ANTHROPIC_API_KEY", value: "implicit" },
    { key: "CLAUDE_CODE_OAUTH_TOKEN", value: "" },
    { key: "ANTHROPIC_BASE_URL", value: config.baseURL },
    { key: "ANTHROPIC_MODEL", value: model.model },
  ];
}

/**
 * `~/.codex/config.toml`: the gateway as a model provider, selected, with
 * approvals and the sandbox turned off — the same "just run it" stance Claude
 * Code gets via `permissions.defaultMode: bypassPermissions`.
 */
export function codexConfig(model: GatewayModel, config: LLMGatewayConfig): string {
  return [
    `model = ${tomlString(model.model)}`,
    `model_provider = ${tomlString(config.providerName)}`,
    `approval_policy = "never"`,
    `sandbox_mode = "danger-full-access"`,
    ``,
    `[model_providers.${config.providerName}]`,
    `name = ${tomlString(config.providerName)}`,
    `base_url = ${tomlString(`${config.baseURL}/v1`)}`,
    `requires_openai_auth = false`,
  ].join("\n");
}

/**
 * The `providers` entry merged into `~/.pi/agent/models.json`.
 *
 * Anthropic models are reached over the Messages API and everything else over
 * Chat Completions, matching how the gateway routes them. The api key is the
 * same placeholder Claude Code gets: pi hides models it believes have no
 * credentials, and the gateway needs none.
 */
export function piProvider(model: GatewayModel, config: LLMGatewayConfig): string {
  return sortedJSON({
    [config.providerName]: {
      baseUrl: `${config.baseURL}/v1`,
      api: model.provider === "anthropic" ? "anthropic-messages" : "openai-completions",
      apiKey: "implicit",
      models: [{ id: model.model }],
    },
  });
}

/**
 * The keys merged into `~/.pi/agent/settings.json`, so pi starts on the chosen
 * model rather than only offering it under `/model`.
 */
export function piSettings(model: GatewayModel, config: LLMGatewayConfig): string {
  return sortedJSON({ defaultProvider: config.providerName, defaultModel: model.model });
}

/** Bundle the env vars and Codex/pi config into a `HarnessWiring`. */
export function gatewayWiring(model: GatewayModel, config: LLMGatewayConfig): HarnessWiring {
  return {
    marker: config.providerName,
    setup: "",
    hostEnvironment: gatewayEnvironment(model, config),
    codexConfig: codexConfig(model, config),
    piProvider: piProvider(model, config),
    piSettings: piSettings(model, config),
  };
}

// MARK: - Catalogue

/** The models on offer, or a readable reason there are none. */
export async function listGatewayModels(config: LLMGatewayConfig): Promise<ModelListing> {
  try {
    const response = await fetch(config.catalogURL);
    if (!response.ok) {
      return { models: [], error: `Couldn't load the model list (HTTP ${response.status}).` };
    }
    return { models: modelsFromCatalog(await response.json()), error: null };
  } catch (error) {
    return { models: [], error: `Couldn't load the model list: ${describe(error)}` };
  }
}

/**
 * Chat models only. The catalogue also lists embedding and reranker models,
 * which no harness can be pointed at; they're told apart by their output type
 * rather than by guessing from the name.
 */
export function modelsFromCatalog(raw: unknown): GatewayModel[] {
  if (typeof raw !== "object" || raw === null) return [];
  const providers = (raw as Record<string, unknown>).providers;
  if (!Array.isArray(providers)) return [];

  const models: GatewayModel[] = [];
  for (const entry of providers) {
    if (typeof entry !== "object" || entry === null) continue;
    const provider = entry as Record<string, unknown>;
    if (typeof provider.id !== "string" || !Array.isArray(provider.models)) continue;
    for (const candidate of provider.models) {
      if (typeof candidate !== "object" || candidate === null) continue;
      const model = candidate as Record<string, unknown>;
      if (typeof model.id !== "string") continue;
      const output = model.output;
      // Absent output means the catalogue didn't say; assume it's a chat model.
      if (Array.isArray(output) && !output.includes("text")) continue;
      models.push({ provider: provider.id, model: model.id });
    }
  }
  return models;
}

export function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Sorted so the files written on the VM don't churn between runs. */
function sortedJSON(value: unknown): string {
  return JSON.stringify(sortKeys(value), null, 2);
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (typeof value !== "object" || value === null) return value;
  const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) =>
    a < b ? -1 : a > b ? 1 : 0
  );
  return Object.fromEntries(entries.map(([key, entry]) => [key, sortKeys(entry)]));
}

/**
 * A TOML basic string. Model ids arrive from a remote catalogue, so they are
 * escaped rather than trusted to be quote-free.
 */
function tomlString(value: string): string {
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}
