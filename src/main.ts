/**
 * hub — a terminal workspace for VM-backed coding sessions.
 *
 * Sessions on the left, the active terminal in the middle, the worktree diff on
 * the right. Everything runs against a VM provider (exe.dev or sprites.dev) over
 * tmux's control protocol.
 */

import { App } from "./ui/app.ts";

if (import.meta.main) {
  const app = new App();
  await app.run();
}
