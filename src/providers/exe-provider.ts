/**
 * exe.dev as a `VMProvider`: the HTTPS `/exec` API for VM lifecycle and GitHub
 * integrations, the `llm.int.exe.xyz` gateway, SSH against `<name>.exe.xyz`,
 * and the reflection endpoint that lets a VM name itself.
 */

import { ExeClient } from "./exe-client.ts";
import { ExeService, type ExeVM } from "./exe-service.ts";
import { SSHTransport } from "./ssh-transport.ts";
import { tokenGitHubSetup } from "./github-setup.ts";
import { type GatewayModel, gatewayWiring, listGatewayModels } from "../model/llm-gateway.ts";
import {
  EXE_GATEWAY,
  type GitHubSetup,
  type HarnessWiring,
  type ModelListing,
  type ProviderCredential,
  type RemoteTransport,
  type RemoteVMRecord,
  type VMProvider,
  type VMProviderID,
} from "./types.ts";
import type { EnvVar } from "../config/env-var.ts";

export class ExeProvider implements VMProvider {
  readonly id: VMProviderID = "exe";
  readonly displayName = "exe.dev";
  readonly defaultBrowserURL = "https://exe.dev";
  readonly supportsAutoNaming = true;
  readonly credential: ProviderCredential = { kind: "token", envVar: "EXE_DEV_TOKEN" };

  /**
   * The reflection integration — attached to every VM on an account by default
   * — publishes the VM's current name at the top level of its index.
   */
  readonly reflectionNameCommand = "curl -fsS --max-time 5 https://reflection.int.exe.xyz/";

  private service: ExeService;

  constructor(private tokenProvider: () => string) {
    this.service = new ExeService(new ExeClient(tokenProvider));
  }

  effectiveToken(): string {
    return this.tokenProvider();
  }

  checkAvailable(): Promise<boolean> {
    return Promise.resolve(this.effectiveToken() !== "");
  }

  // MARK: - LLM gateway

  listModels(): Promise<ModelListing> {
    return listGatewayModels(EXE_GATEWAY);
  }

  harnessWiring(model: GatewayModel): HarnessWiring {
    return gatewayWiring(model, EXE_GATEWAY);
  }

  // MARK: - VM lifecycle

  async listVMs(): Promise<RemoteVMRecord[]> {
    return (await this.service.listVMs()).map(recordFromExeVM);
  }

  async createVM(name: string, tags: string[], environment: EnvVar[]): Promise<RemoteVMRecord> {
    return recordFromExeVM(await this.service.createVM(name, tags, environment));
  }

  deleteVM(name: string): Promise<void> {
    return this.service.deleteVM(name);
  }

  // MARK: - GitHub

  /**
   * The same token every other provider clones with, rather than exe.dev's own
   * GitHub integrations: one setup path, and nothing for a user to have
   * authorized per repo before a session will start.
   */
  prepareGitHub(repos: string[]): Promise<GitHubSetup> {
    return tokenGitHubSetup(repos);
  }

  // MARK: - Auto-naming

  generateRenameToken(): Promise<string> {
    return this.service.generateRenameToken();
  }

  // MARK: - Naming and reachability

  destinationForVMName(name: string): string {
    return `${name}.exe.xyz`;
  }

  webURLForDestination(destination: string): string | null {
    return `https://${destination}`;
  }

  parseReflectedName(output: string): string | null {
    try {
      const parsed = JSON.parse(output) as unknown;
      if (typeof parsed !== "object" || parsed === null) return null;
      const name = (parsed as Record<string, unknown>).name;
      return typeof name === "string" && name ? name : null;
    } catch {
      return null;
    }
  }

  // MARK: - Transport

  transportFor(destination: string): RemoteTransport {
    return new SSHTransport(destination);
  }

  hostEnvironmentSetup(_environment: EnvVar[]): string {
    // exe.dev sets host env via `new --env`, so the bootstrap injects nothing.
    return "";
  }
}

/**
 * An `ExeVM` as the app-agnostic `RemoteVMRecord`. `ssh_dest` is the transport
 * handle; the web URL is the SSH host over HTTPS.
 */
export function recordFromExeVM(vm: ExeVM): RemoteVMRecord {
  const name = vm.vm_name ?? vm.ssh_dest ?? "unknown";
  const destination = vm.ssh_dest ?? (vm.vm_name ? `${vm.vm_name}.exe.xyz` : "unknown");
  return {
    name,
    destination,
    webURL: `https://${destination}`,
    status: vm.status ?? null,
    provider: "exe",
  };
}
