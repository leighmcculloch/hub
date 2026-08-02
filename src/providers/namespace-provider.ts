/**
 * Namespace dev boxes as a `VMProvider`: the `devbox` CLI for the whole
 * lifecycle, `devbox ssh` for running commands, and GitHub cloning with a token
 * in the box's environment.
 *
 * Namespace differs from the other two providers in three ways worth naming:
 *
 * - There is no token. `devbox login` opens a browser and the credential lives
 *   in the CLI, so "configured" means the CLI is installed and logged in —
 *   which `checkAvailable` asks it directly.
 * - There is no model gateway, so `harnessWiring` is null and the agents on the
 *   box authenticate themselves. The default image ships them already
 *   installed, which is the point of using it.
 * - There is no rename API, so `supportsAutoNaming` is false and an unnamed
 *   session keeps the name it was created with.
 *
 * A stopped dev box is still openable: `devbox ssh` resumes one, so a box that
 * idled out needs nothing beyond connecting to it.
 */

import { NamespaceCLI, NamespaceError } from "./namespace-cli.ts";
import { DEVBOX_LOGIN } from "./namespace-cli.ts";
import { NamespaceCLITransport } from "./namespace-cli-transport.ts";
import { profileEnvironmentSetup, tokenCloneConfig } from "../model/bootstrap.ts";
import type { GatewayModel } from "../model/llm-gateway.ts";
import { currentGitHubToken } from "../github/repos.ts";
import type {
  GitHubSetup,
  HarnessWiring,
  ModelListing,
  ProviderCredential,
  RemoteTransport,
  RemoteVMRecord,
  VMProvider,
  VMProviderID,
} from "./types.ts";
import type { EnvVar } from "../config/env-var.ts";

/**
 * The image new dev boxes are created from. Namespace's built-in agent image
 * carries Claude Code, Codex and friends already installed, which is what every
 * session here goes on to run; without `--image` the CLI would stop to ask.
 */
export const DEFAULT_IMAGE = "builtin:agents";

/** The machine size new dev boxes are created at: s, m, l or xl. */
export const DEFAULT_SIZE = "m";

/** The dashboard, which is as close to a per-box URL as Namespace offers. */
const DASHBOARD_URL = "https://cloud.namespace.so/workspace/devboxes";

export class NamespaceProvider implements VMProvider {
  readonly id: VMProviderID = "namespace";
  readonly displayName = "namespace.so";
  readonly defaultBrowserURL = DASHBOARD_URL;
  readonly supportsAutoNaming = false;
  readonly credential: ProviderCredential = {
    kind: "cli",
    binary: "devbox",
    loginCommand: DEVBOX_LOGIN,
  };
  readonly reflectionNameCommand = null;

  constructor(private cli = new NamespaceCLI()) {}

  /** No token to hold: the login lives in the CLI. */
  effectiveToken(): string {
    return "";
  }

  checkAvailable(): Promise<boolean> {
    return this.cli.loggedIn();
  }

  // MARK: - LLM gateway (none)

  /**
   * Namespace brokers no models. Said plainly rather than left as an empty
   * list, because "no models" and "the catalogue didn't load" are different
   * problems and the picker shows this line under the model dropdown.
   */
  listModels(): Promise<ModelListing> {
    return Promise.resolve({
      models: [],
      error: "Namespace has no model gateway — agents on the dev box use their own logins.",
    });
  }

  /** No gateway to point a harness at, so a model chosen elsewhere is ignored. */
  harnessWiring(_model: GatewayModel): HarnessWiring | null {
    return null;
  }

  // MARK: - Host environment

  /** No API to set host env at create time, so the bootstrap writes a profile. */
  hostEnvironmentSetup(environment: EnvVar[]): string {
    return profileEnvironmentSetup(environment);
  }

  // MARK: - VM lifecycle

  async listVMs(): Promise<RemoteVMRecord[]> {
    return (await this.cli.list()).map((box) => ({
      name: box.name,
      destination: box.name,
      webURL: null,
      status: box.status,
      provider: this.id,
    }));
  }

  async createVM(
    name: string,
    _tags: string[],
    _environment: EnvVar[],
  ): Promise<RemoteVMRecord> {
    // Tags are exe.dev's integration-binding mechanism, and the environment is
    // injected by the bootstrap: neither has a `devbox create` flag.
    const box = await this.cli.create({
      name,
      image: DEFAULT_IMAGE,
      size: DEFAULT_SIZE,
      purpose: "hub session",
    });
    return {
      name: box.name,
      destination: box.name,
      webURL: null,
      status: box.status,
      provider: this.id,
    };
  }

  deleteVM(name: string): Promise<void> {
    return this.cli.expire(name);
  }

  // MARK: - GitHub

  /**
   * No integration step: dev boxes clone from github.com with a token in the
   * box's environment. The token the app already discovered for the repo picker
   * is reused, so every provider shares one GitHub credential.
   */
  async prepareGitHub(repos: string[]): Promise<GitHubSetup> {
    if (repos.length === 0) return { tags: [], cloneEnvironment: [], clone: namespaceClone(null) };
    const token = await currentGitHubToken();
    return {
      tags: [],
      cloneEnvironment: token ? [{ key: "GITHUB_TOKEN", value: token }] : [],
      clone: namespaceClone(token),
    };
  }

  // MARK: - Auto-naming (not supported)

  generateRenameToken(): Promise<string> {
    // Unreachable: `supportsAutoNaming` is false, so the provisioner never
    // calls this. Rejecting rather than returning a token that could not work.
    return Promise.reject(new NamespaceError("Namespace does not support auto-naming."));
  }

  // MARK: - Naming and reachability

  /** A dev box's transport handle is its name — `devbox ssh <name>`. */
  destinationForVMName(name: string): string {
    return name;
  }

  /** Namespace publishes no per-box URL; Alt+O falls back to the dashboard. */
  webURLForDestination(_destination: string): string | null {
    return null;
  }

  parseReflectedName(_output: string): string | null {
    return null;
  }

  transportFor(destination: string): RemoteTransport {
    return new NamespaceCLITransport(destination);
  }
}

/** The clone config for Namespace: github.com, with `$GITHUB_TOKEN` if there is one. */
export function namespaceClone(token: string | null) {
  return tokenCloneConfig(
    token,
    "check the GITHUB_TOKEN in the dev box's environment, then clone again.",
  );
}
