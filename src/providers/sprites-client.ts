/**
 * Thin client for the sprites.dev REST API (`https://api.sprites.dev`).
 *
 * Unlike exe.dev's "POST a command string to `/exec`", sprites.dev is a typed
 * REST API: `POST/GET/DELETE /v1/sprites/{name}`. Auth is a bearer token.
 * sprites.dev has no API to set host environment, so env vars are injected by
 * the bootstrap script instead (see `SpritesProvider.hostEnvironmentSetup`).
 */

import { condense, tokenHint } from "../model/message-text.ts";

export class SpritesError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SpritesError";
  }
}

export interface Sprite {
  id?: string | null;
  name: string;
  url?: string | null;
  status?: string | null;
}

interface ListPage {
  sprites: Array<{ name: string }>;
  has_more: boolean;
  next_continuation_token?: string | null;
}

export class SpritesClient {
  private baseURL: string;

  constructor(private tokenProvider: () => string) {
    // `SPRITES_API_URL` overrides the default endpoint, mirroring the CLI.
    let base = Deno.env.get("SPRITES_API_URL") ?? "https://api.sprites.dev";
    // Strip trailing slashes so `base + "/v1/sprites"` doesn't double them;
    // built by concatenation so a query string on the path survives intact.
    while (base.endsWith("/")) base = base.slice(0, -1);
    this.baseURL = base;
  }

  create(name: string): Promise<Sprite> {
    return this.request<Sprite>("POST", "/v1/sprites", { name });
  }

  get(name: string): Promise<Sprite> {
    return this.request<Sprite>("GET", `/v1/sprites/${name}`);
  }

  async delete(name: string): Promise<void> {
    await this.send("DELETE", `/v1/sprites/${name}`);
  }

  /**
   * All sprites in the org, paginated. The list endpoint returns a reduced
   * shape (name only), so callers GET each one for its URL and status.
   */
  async listNames(): Promise<string[]> {
    const names: string[] = [];
    let token: string | null = null;
    do {
      let path = "/v1/sprites?max_results=50";
      if (token) path += `&continuation_token=${token}`;
      const page: ListPage = await this.request<ListPage>("GET", path);
      for (const entry of page.sprites ?? []) names.push(entry.name);
      token = page.has_more ? (page.next_continuation_token ?? null) : null;
    } while (token !== null);
    return names;
  }

  private async request<T>(
    method: string,
    path: string,
    body?: Record<string, unknown>,
  ): Promise<T> {
    const { text } = await this.send(method, path, body);
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new SpritesError(`Unexpected sprites.dev response: ${condense(text)}`);
    }
  }

  private async send(
    method: string,
    path: string,
    body?: Record<string, unknown>,
  ): Promise<{ text: string; status: number }> {
    const token = this.tokenProvider();
    if (!token) {
      throw new SpritesError(
        "No sprites.dev API token configured. Add one in Settings (Alt+,) or set SPRITE_TOKEN.",
      );
    }

    const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
    if (body) headers["Content-Type"] = "application/json";

    const response = await fetch(`${this.baseURL}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await response.text();
    if (!response.ok) {
      throw new SpritesError(
        `sprites.dev (HTTP ${response.status}): ${condense(text)}` +
          tokenHint(response.status, "your API token in Settings (Alt+,) or SPRITE_TOKEN"),
      );
    }
    return { text, status: response.status };
  }
}
