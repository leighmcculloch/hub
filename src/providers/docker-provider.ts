/**
 * Docker as a `VMProvider`: containers on this machine instead of VMs on
 * someone's service.
 *
 * This is the provider the other three made possible. Once GitHub access is a
 * token in the environment, the harness is installed by the bootstrap, and the
 * transport is "run this command over there", a provider is only four commands
 * — `run`, `ps`, `rm`, `exec` — and everything else already applies. So the
 * image is plain `ubuntu`: no agents, no tmux, not even curl. The bootstrap
 * installs what it needs, which is the same thing it does everywhere else.
 *
 * There is no login. Docker is either reachable or it isn't, and `docker info`
 * is the question.
 */

import { join } from "@std/path";
import { runCommand } from "./process.ts";
import { DockerTransport } from "./docker-transport.ts";
import { dockerfile, imageSetupScript, imageTag } from "./docker-image.ts";
import { tokenGitHubSetup } from "./github-setup.ts";
import { condense } from "../model/message-text.ts";
import type { GatewayModel } from "../model/llm-gateway.ts";
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

export const DOCKER_BINARY = "docker";

/**
 * Stamped on every container this app starts, so listing finds its own and
 * leaves the rest of the machine's containers alone.
 */
export const CONTAINER_LABEL = "dev.hub.session";

/**
 * PID 1 for a container that exists to be `exec`ed into. Without it the
 * container runs `bash`, finds no terminal, and exits before anything connects.
 */
const IDLE_COMMAND = ["sleep", "infinity"];

export class DockerError extends Error {
  readonly credentialFailure: boolean;

  constructor(message: string, credentialFailure = false) {
    super(message);
    this.name = "DockerError";
    this.credentialFailure = credentialFailure;
  }
}

export class DockerProvider implements VMProvider {
  readonly id: VMProviderID = "docker";
  readonly displayName = "docker";
  readonly defaultBrowserURL = "https://docs.docker.com/";
  readonly supportsAutoNaming = false;
  /**
   * Not a login — there is no account — but the same shape as one: a binary
   * that has to be there and working, and a command that says whether it is.
   */
  readonly credential: ProviderCredential = {
    kind: "cli",
    binary: DOCKER_BINARY,
    loginCommand: "docker info",
  };
  readonly reflectionNameCommand = null;

  /** Nothing to hold: reachability is the whole of it. */
  effectiveToken(): string {
    return "";
  }

  async checkAvailable(): Promise<boolean> {
    try {
      const result = await this.run(["info", "--format", "{{.ServerVersion}}"]);
      return result.code === 0;
    } catch {
      return false;
    }
  }

  // MARK: - LLM gateway (none)

  listModels(): Promise<ModelListing> {
    return Promise.resolve({
      models: [],
      error: "Docker has no model gateway — the agent in the container uses its own login.",
    });
  }

  harnessWiring(_model: GatewayModel): HarnessWiring | null {
    return null;
  }

  // MARK: - Host environment

  /** `docker run -e` sets it at create time, so nothing to inject later. */
  hostEnvironmentSetup(_environment: EnvVar[]): string {
    return "";
  }

  // MARK: - VM lifecycle

  /**
   * Build the session image, if this machine doesn't already have it. Called
   * before the container is created, so the wait happens somewhere the UI can
   * explain rather than inside `docker run`.
   */
  async prepare(log: (line: string) => void): Promise<void> {
    await this.ensureImage(log);
  }

  async listVMs(): Promise<RemoteVMRecord[]> {
    const output = await this.expect([
      "ps",
      "--all",
      "--filter",
      `label=${CONTAINER_LABEL}`,
      "--format",
      "{{.Names}}\t{{.State}}",
    ], "list containers");
    return parseContainers(output).map((container) => ({
      name: container.name,
      destination: container.name,
      webURL: null,
      status: container.status,
      provider: this.id,
    }));
  }

  async createVM(
    name: string,
    _tags: string[],
    environment: EnvVar[],
  ): Promise<RemoteVMRecord> {
    const image = await this.ensureImage();
    const args = ["run", "--detach", "--name", name, "--label", CONTAINER_LABEL];
    for (const variable of environment) {
      if (!variable.key) continue;
      args.push("--env", `${variable.key}=${variable.value}`);
    }
    args.push(image, ...IDLE_COMMAND);
    await this.expect(args, `create container ${name}`);
    return {
      name,
      destination: name,
      webURL: null,
      status: "running",
      provider: this.id,
    };
  }

  /** `--force` because a running container is still one the user asked to go. */
  async deleteVM(name: string): Promise<void> {
    await this.expect(["rm", "--force", name], `delete container ${name}`);
  }

  // MARK: - GitHub

  prepareGitHub(repos: string[]): Promise<GitHubSetup> {
    return tokenGitHubSetup(repos);
  }

  // MARK: - Auto-naming (not supported)

  generateRenameToken(): Promise<string> {
    return Promise.reject(new DockerError("Docker does not support auto-naming."));
  }

  // MARK: - Naming and reachability

  destinationForVMName(name: string): string {
    return name;
  }

  webURLForDestination(_destination: string): string | null {
    return null;
  }

  parseReflectedName(_output: string): string | null {
    return null;
  }

  transportFor(destination: string): RemoteTransport {
    return new DockerTransport(destination);
  }

  // MARK: - The session image

  /**
   * The tag to run, building it first if this machine doesn't have it.
   *
   * The build is what makes the *first* session on a given setup slow and every
   * one after it immediate: `docker image inspect` is the whole of the cache
   * check, because the tag already encodes what the image contains. `log` is
   * only called when there is actually a build to wait for.
   */
  private async ensureImage(log?: (line: string) => void): Promise<string> {
    const file = dockerfile();
    const setup = imageSetupScript();
    const tag = await imageTag(file, setup);
    if (await this.hasImage(tag)) return tag;

    log?.(`Building the session image ${tag} — first run on this setup, a few minutes…`);
    const context = await Deno.makeTempDir({ prefix: "hub-image-" });
    try {
      await Deno.writeTextFile(join(context, "Dockerfile"), file);
      await Deno.writeTextFile(join(context, "setup.sh"), setup);
      await this.expect(["build", "--tag", tag, context], `build the session image ${tag}`);
    } finally {
      await Deno.remove(context, { recursive: true }).catch(() => {});
    }
    return tag;
  }

  private async hasImage(tag: string): Promise<boolean> {
    try {
      return (await this.run(["image", "inspect", tag])).code === 0;
    } catch {
      return false;
    }
  }

  // MARK: - Running the CLI

  private async expect(args: string[], what: string): Promise<string> {
    let result;
    try {
      result = await this.run(args);
    } catch (error) {
      throw failure(what, String(error));
    }
    if (result.code !== 0) throw failure(what, result.stderr || result.stdout);
    return result.stdout;
  }

  private run(args: string[]) {
    return runCommand({ executable: "/usr/bin/env", arguments: [DOCKER_BINARY, ...args] });
  }
}

/**
 * A stopped daemon is the failure worth naming: every docker command says the
 * same thing about it, and none of them is the user's fault.
 */
function failure(what: string, reason: string): DockerError {
  const last = lastLine(reason);
  const unreachable = last !== null && /cannot connect to the docker daemon|is the docker daemon/i
    .test(last);
  if (last === null) {
    return new DockerError(`Docker couldn't ${what}: \`${DOCKER_BINARY}\` printed nothing.`);
  }
  const hint = unreachable ? " Start Docker, then try again." : "";
  return new DockerError(`Docker couldn't ${what}: ${last}.${hint}`, unreachable);
}

function lastLine(text: string): string | null {
  const lines = text.split(/[\r\n]/).map((line) => line.trim()).filter((line) => line.length > 0);
  return lines.length === 0 ? null : condense(lines[lines.length - 1]);
}

/** A container, from one `{{.Names}}\t{{.State}}` line each. */
export function parseContainers(text: string): Array<{ name: string; status: string | null }> {
  const containers: Array<{ name: string; status: string | null }> = [];
  for (const line of text.split(/[\r\n]+/)) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    const [name, state] = trimmed.split("\t");
    if (!name) continue;
    containers.push({ name, status: state ? state.trim().toLowerCase() : null });
  }
  return containers;
}
