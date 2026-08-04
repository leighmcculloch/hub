/**
 * hub — a workspace for VM-backed coding sessions.
 *
 * Sessions on the left, the active terminal in the middle, the worktree diff on
 * the right. Everything runs against a VM provider — Docker containers on this
 * machine, exe.dev, sprites.dev, or Namespace dev boxes — over tmux's control
 * protocol.
 *
 * This is the headless half: the server, and a browser pointed at it. For the
 * desktop application — the same server, in a window of its own — see
 * `desktop.ts`, which is what `deno task desktop` builds.
 */

import { HubServer } from "./server/api.ts";

if (import.meta.main) {
  const server = new HubServer(new URL("./client/", import.meta.url));
  await server.start();
  Deno.serve(server.handler);
}
