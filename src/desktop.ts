/**
 * hub as a desktop application.
 *
 * `deno desktop` bundles the runtime and a web engine into one binary, and
 * renders whatever a local `Deno.serve()` answers with. So this is the whole of
 * the desktop layer: start the server, open a window, point it at the port.
 *
 * The server is the app. Nothing about it knows it is being rendered in a
 * window rather than a browser tab, which is what keeps `deno task start`
 * honest as a way to run hub headless.
 */

import { HubServer, serve } from "./server/api.ts";

const CLIENT_ROOT = new URL("./client/", import.meta.url);

const server = new HubServer(CLIENT_ROOT);
await server.start();

// A window navigates to whatever port was bound, so a taken one costs
// nothing here — but failing to start over it would cost the whole app.
const listening = serve(server.handler);

// A window only exists under `deno desktop`; a plain `deno run` of this file is
// the headless case rather than a failure.
if ("BrowserWindow" in Deno) {
  const port = listening.addr.transport === "tcp" ? listening.addr.port : 0;
  const window = new (Deno as unknown as {
    BrowserWindow: new (options: Record<string, unknown>) => { navigate(url: string): void };
  }).BrowserWindow({
    title: "hub",
    width: 1200,
    height: 800,
  });
  window.navigate(`http://127.0.0.1:${port}`);
}
