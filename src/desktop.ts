/**
 * hub as a desktop application.
 *
 * `deno desktop` bundles the runtime and a web engine into one binary, and
 * renders whatever a local `Deno.serve()` answers with. So this is the whole of
 * the desktop layer: start the server, open a window, point it at the port.
 *
 * The server is the app. Nothing about it knows it is being rendered in a
 * window rather than a browser tab, which is what keeps `deno task serve`
 * honest as a way to run hub headless.
 */

import { HubServer } from "./server/api.ts";

const CLIENT_ROOT = new URL("./client/", import.meta.url);

const server = new HubServer(CLIENT_ROOT);
await server.start();

Deno.serve(server.handler);

// `deno desktop` sets this to the address it bound `Deno.serve` to; running
// under a plain `deno run` there is no window to open, which is the headless
// case rather than a failure.
const address = Deno.env.get("DENO_SERVE_ADDRESS");
if (address && "BrowserWindow" in Deno) {
  const port = address.split(":").pop();
  const window = new (Deno as unknown as {
    BrowserWindow: new (options: Record<string, unknown>) => { navigate(url: string): void };
  }).BrowserWindow({
    title: "hub",
    width: 1200,
    height: 800,
  });
  window.navigate(`http://127.0.0.1:${port}`);
}
