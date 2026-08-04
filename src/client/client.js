/**
 * hub's client: the window.
 *
 * It owns no state worth persisting. The server holds the workspace and says
 * "changed"; this asks what the world looks like now and draws it. Pane bytes
 * arrive on a socket of their own and go straight into a terminal emulator,
 * which is the one thing here that is genuinely stateful — and it is state
 * about pixels, not about sessions.
 */

// xterm ships a UMD bundle, loaded by a plain script tag ahead of this module,
// so it arrives as a global rather than an import.
const { Terminal } = globalThis;

const sessionsList = document.getElementById("sessions");
const vmsList = document.getElementById("vms");
const errorsList = document.getElementById("errors");
const tabsBar = document.getElementById("tabs");
const where = document.getElementById("where");

/** The pane socket and emulator for whichever session is open. */
let attached = null;

const terminal = new Terminal({
  fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
  fontSize: 13,
  theme: { background: "#101014", foreground: "#d8d8e0" },
  convertEol: false,
});
terminal.open(document.getElementById("terminal"));

// Keystrokes go to the pane as the bytes the terminal produced, which is what
// tmux's `send-keys -H` on the far end is expecting.
const encoder = new TextEncoder();
terminal.onData((data) => {
  if (attached?.socket.readyState === WebSocket.OPEN) {
    attached.socket.send(encoder.encode(data));
  }
});

async function refresh() {
  const state = await fetch("/api/state").then((response) => response.json());
  draw(state);
  if (state.selectedSessionID && attached?.id !== state.selectedSessionID) {
    attach(state.selectedSessionID);
  }
}

function draw(state) {
  sessionsList.replaceChildren(...state.sessions.map((session) => {
    const item = document.createElement("li");
    item.textContent = session.title;
    item.className = session.id === state.selectedSessionID ? "selected" : "";
    if (session.hasUnseenOutput) item.classList.add("busy");
    item.onclick = () => attach(session.id);
    return item;
  }));

  vmsList.replaceChildren(...state.vms.map((vm) => {
    const item = document.createElement("li");
    item.textContent = `${vm.name} · ${vm.provider}`;
    item.title = vm.status ?? "unknown";
    return item;
  }));

  errorsList.replaceChildren(...state.errors.map((error) => {
    const item = document.createElement("li");
    item.className = "error";
    item.textContent = `${error.provider}: ${error.reason}`;
    return item;
  }));

  const open = state.sessions.find((one) => one.id === state.selectedSessionID);
  where.textContent = open ? (open.destination ?? "local") : "no session";
  tabsBar.replaceChildren(...(open?.tabs ?? []).map((tab) => {
    const button = document.createElement("button");
    button.textContent = tab.title || tab.paneID;
    button.className = tab.paneID === open.selectedTabID ? "selected" : "";
    button.onclick = () => send({ type: "selectTab", paneID: tab.paneID });
    return button;
  }));
}

function send(message) {
  if (attached?.socket.readyState === WebSocket.OPEN) {
    attached.socket.send(JSON.stringify(message));
  }
}

/** Point the terminal at a session, dropping whatever it was showing. */
function attach(id) {
  attached?.socket.close();
  terminal.reset();
  const socket = new WebSocket(`ws://${location.host}/api/session/${id}`);
  socket.binaryType = "arraybuffer";
  socket.onmessage = (event) => {
    if (typeof event.data === "string") return;
    terminal.write(new Uint8Array(event.data));
  };
  socket.onopen = () => send({ type: "resize", cols: terminal.cols, rows: terminal.rows });
  attached = { id, socket };
}

// The server never sends state, only word that it moved: one description of the
// world, asked for again, rather than a stream of patches to keep in step.
const watch = new WebSocket(`ws://${location.host}/api/watch`);
watch.onmessage = () => refresh();

globalThis.addEventListener("resize", () => {
  send({ type: "resize", cols: terminal.cols, rows: terminal.rows });
});

document.getElementById("new-session").onclick = () => {
  // Creating a machine is the server's job and wants a form the sidebar hasn't
  // grown yet; until it does, this opens a session on the default provider.
  fetch("/api/sessions", { method: "POST" }).then(refresh);
};

refresh();
