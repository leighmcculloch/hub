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

const el = (id) => document.getElementById(id);
const encoder = new TextEncoder();

/** The last state the server described, so handlers don't have to re-fetch. */
let state = { sessions: [], vms: [], providers: [], errors: [], provisioning: { active: false } };
/** The pane socket for whichever session is open. */
let attached = null;
/** Which repo the diff panel is showing, per session. */
const diffRepo = new Map();

// MARK: - Terminal

const terminal = new Terminal({
  fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
  fontSize: 13,
  cursorBlink: true,
  theme: { background: "#101014", foreground: "#d8d8e0", cursor: "#7aa2f7" },
});
terminal.open(el("terminal"));
terminal.onData((data) => sendBytes(encoder.encode(data)));

function sendBytes(bytes) {
  if (attached?.socket.readyState === WebSocket.OPEN) attached.socket.send(bytes);
}

function send(message) {
  if (attached?.socket.readyState === WebSocket.OPEN) {
    attached.socket.send(JSON.stringify(message));
  }
}

/**
 * Size the terminal to its box, in whole cells.
 *
 * xterm renders at a fixed cell size, so the number of columns and rows is the
 * box divided by one cell — and tmux has to be told, or the far end wraps at a
 * width the near end isn't showing.
 */
function fitTerminal() {
  const box = el("terminal").getBoundingClientRect();
  const cell = terminal._core?._renderService?.dimensions?.css?.cell;
  if (!cell?.width || !cell?.height) return;
  const cols = Math.max(20, Math.floor(box.width / cell.width));
  const rows = Math.max(5, Math.floor(box.height / cell.height));
  if (cols !== terminal.cols || rows !== terminal.rows) terminal.resize(cols, rows);
  send({ type: "resize", cols: terminal.cols, rows: terminal.rows });
}

/** Point the terminal at a session, dropping whatever it was showing. */
function attach(id) {
  if (attached?.id === id) return;
  attached?.socket.close();
  terminal.reset();
  const socket = new WebSocket(`ws://${location.host}/api/session/${id}`);
  socket.binaryType = "arraybuffer";
  socket.onmessage = (event) => {
    if (typeof event.data !== "string") terminal.write(new Uint8Array(event.data));
  };
  socket.onopen = () => fitTerminal();
  attached = { id, socket };
  post(`/api/sessions/${id}/select`);
  terminal.focus();
}

// MARK: - Server

async function get(path) {
  const response = await fetch(path);
  return response.ok ? await response.json() : null;
}

async function post(path, body) {
  await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });
}

async function refresh() {
  const next = await get("/api/state");
  if (!next) return;
  state = next;
  draw();
  if (state.selectedSessionID) attach(state.selectedSessionID);
  if (attached && !state.sessions.some((one) => one.id === attached.id)) {
    attached.socket.close();
    attached = null;
    terminal.reset();
  }
}

// MARK: - Drawing

function draw() {
  drawSessions();
  drawMachines();
  drawTabs();
  drawProvisioning();
  const open = currentSession();
  el("where").textContent = open ? (open.destination ?? "local") : "no session";
  el("close-session").disabled = !open;
  if (!el("diff").hidden) void loadDiff();
}

function currentSession() {
  return state.sessions.find((one) => one.id === state.selectedSessionID) ?? null;
}

function drawSessions() {
  el("sessions").replaceChildren(...state.sessions.map((session) => {
    const item = document.createElement("li");
    item.className = session.id === state.selectedSessionID ? "selected" : "";
    if (session.hasUnseenOutput) item.classList.add("busy");

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = session.title;
    name.onclick = () => attach(session.id);
    // A session is renamed where its name is, rather than in a dialog about it.
    name.ondblclick = () => {
      const title = prompt("Rename session", session.title);
      if (title !== null) post(`/api/sessions/${session.id}/rename`, { title });
    };

    const where = document.createElement("span");
    where.className = "sub";
    where.textContent = session.provider;

    item.append(name, where);
    return item;
  }));
}

function drawMachines() {
  const items = state.vms.map((vm) => {
    const item = document.createElement("li");
    item.title = `${vm.provider} · ${vm.status ?? "unknown"}`;
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = vm.name;
    const sub = document.createElement("span");
    sub.className = "sub";
    sub.textContent = vm.provider;
    item.append(name, sub);
    item.onclick = () => post("/api/sessions/open", { name: vm.name, provider: vm.provider });
    return item;
  });
  for (const error of state.errors) {
    const item = document.createElement("li");
    item.className = "error";
    item.textContent = `${error.provider}: ${error.reason}`;
    items.push(item);
  }
  el("vms").replaceChildren(...items);
}

function drawTabs() {
  const open = currentSession();
  const tabs = (open?.tabs ?? []).map((tab) => {
    const button = document.createElement("button");
    button.textContent = tab.title || tab.paneID;
    button.className = tab.paneID === open.selectedTabID ? "selected" : "";
    button.onclick = () => {
      send({ type: "selectTab", paneID: tab.paneID });
      terminal.focus();
    };
    return button;
  });
  if (open) {
    const add = document.createElement("button");
    add.textContent = "+";
    add.title = "New tab";
    add.onclick = () => send({ type: "newTab" });
    tabs.push(add);
  }
  el("tabs").replaceChildren(...tabs);
}

function drawProvisioning() {
  const panel = el("provisioning");
  const run = state.provisioning;
  panel.hidden = !run.active;
  if (!run.active) return;
  el("provisioning-lines").textContent = run.lines.join("\n");
  el("provisioning-error").textContent = run.error ?? "";
  el("provisioning-error").hidden = !run.error;
  el("provisioning-dismiss").hidden = !run.error;
}

// MARK: - Diff

async function loadDiff() {
  const open = currentSession();
  if (!open) return;
  const repo = diffRepo.get(open.id);
  const view = await get(
    `/api/sessions/${open.id}/diff${repo ? `?repo=${encodeURIComponent(repo)}` : ""}`,
  );
  if (!view) return;
  el("diff-repos").replaceChildren(...view.repos.map((name) => {
    const option = document.createElement("option");
    option.value = name;
    option.textContent = name;
    option.selected = name === view.repo;
    return option;
  }));
  el("diff-status").textContent = view.status.join("\n") || "clean";
  el("diff-body").textContent = view.diff || "no changes";
}

el("diff-repos").onchange = (event) => {
  const open = currentSession();
  if (open) diffRepo.set(open.id, event.target.value);
  void loadDiff();
};

// MARK: - New session

const modal = el("new-session-modal");

async function openNewSession() {
  el("new-name").value = "";
  el("new-provider").replaceChildren(...state.providers.map((provider) => {
    const option = document.createElement("option");
    option.value = provider.id;
    option.textContent = provider.configured ? provider.label : `${provider.label} (not ready)`;
    option.disabled = !provider.configured;
    return option;
  }));
  el("new-repos").replaceChildren();
  modal.showModal();
  el("new-name").focus();

  // The repo list is a network round trip, so the dialog opens without it and
  // fills in — a picker you can't type a name into yet is worse than a wait.
  const listing = await get("/api/repos");
  if (!listing) return;
  el("new-repos").replaceChildren(...listing.repos.map((name) => {
    const label = document.createElement("label");
    const box = document.createElement("input");
    box.type = "checkbox";
    box.value = name;
    label.append(box, document.createTextNode(` ${name}`));
    return label;
  }));
  el("new-repos-error").textContent = listing.error ?? "";
  el("new-repos-error").hidden = !listing.error;
}

el("new-session").onclick = openNewSession;
el("new-local").onclick = () => post("/api/sessions/local");
el("new-cancel").onclick = () => modal.close();
el("new-create").onclick = () => {
  const repos = [...el("new-repos").querySelectorAll("input:checked")].map((one) => one.value);
  post("/api/sessions", {
    provider: el("new-provider").value,
    name: el("new-name").value,
    repos,
  });
  modal.close();
};
el("new-search").oninput = (event) => {
  const needle = event.target.value.toLowerCase();
  for (const label of el("new-repos").children) {
    label.hidden = !label.textContent.toLowerCase().includes(needle);
  }
};

el("provisioning-dismiss").onclick = () => post("/api/provisioning/dismiss");

el("close-session").onclick = () => {
  const open = currentSession();
  if (open) post(`/api/sessions/${open.id}/close`);
};

// MARK: - Settings

const settings = el("settings-modal");

async function openSettings() {
  const config = await get("/api/config");
  if (!config) return;
  el("set-provider").replaceChildren(...state.providers.map((provider) => {
    const option = document.createElement("option");
    option.value = provider.id;
    option.textContent = provider.label;
    option.selected = provider.id === config.provider;
    return option;
  }));
  el("set-exe").value = config.exeToken;
  el("set-sprites").value = config.spritesToken;
  el("set-pi").value = config.piSettings;
  el("set-env").value = config.globalEnvironment
    .map((one) => `${one.key}=${one.value}`)
    .join("\n");
  el("set-environment").replaceChildren(...config.environments.map((environment) => {
    const option = document.createElement("option");
    option.value = environment.id;
    option.textContent = environment.name || "Untitled";
    option.selected = environment.id === config.selectedEnvironmentID;
    return option;
  }));
  const chosen = config.environments.find((one) => one.id === config.selectedEnvironmentID);
  el("set-start").value = chosen?.startCommand ?? "";
  el("set-setup").value = chosen?.setupScript ?? "";
  settings.dataset.environments = JSON.stringify(config.environments);
  settings.showModal();
}

el("settings").onclick = openSettings;
el("set-cancel").onclick = () => settings.close();
el("set-save").onclick = async () => {
  const environments = JSON.parse(settings.dataset.environments || "[]");
  const id = el("set-environment").value;
  const edited = environments.map((one) =>
    one.id === id
      ? { ...one, startCommand: el("set-start").value, setupScript: el("set-setup").value }
      : one
  );
  await fetch("/api/config", {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      provider: el("set-provider").value,
      exeToken: el("set-exe").value,
      spritesToken: el("set-sprites").value,
      piSettings: el("set-pi").value,
      selectedEnvironmentID: id,
      environments: edited,
      globalEnvironment: el("set-env").value.split("\n").filter((line) => line.includes("=")).map(
        (line) => ({
          key: line.slice(0, line.indexOf("=")),
          value: line.slice(line.indexOf("=") + 1),
        }),
      ),
    }),
  });
  settings.close();
  refresh();
};

// Switching environments in the dialog swaps the two fields under it, so the
// script you are looking at always belongs to the environment named above it.
el("set-environment").onchange = () => {
  const environments = JSON.parse(settings.dataset.environments || "[]");
  const chosen = environments.find((one) => one.id === el("set-environment").value);
  el("set-start").value = chosen?.startCommand ?? "";
  el("set-setup").value = chosen?.setupScript ?? "";
};

// MARK: - Keyboard

/**
 * The app's own keys, all under a modifier the terminal doesn't want.
 *
 * Everything else belongs to the program in the pane — a shell without Tab
 * completion is not a shell — so nothing here fires without Alt.
 */
globalThis.addEventListener("keydown", (event) => {
  if (!event.altKey || event.ctrlKey || event.metaKey) return;
  const key = event.key.toLowerCase();
  const handlers = {
    n: openNewSession,
    ",": openSettings,
    d: toggleDiff,
    b: () => el("sidebar").classList.toggle("hidden"),
    t: () => send({ type: "newTab" }),
    w: () => el("close-session").click(),
    j: () => step(1),
    k: () => step(-1),
  };
  const handler = handlers[key];
  if (!handler) return;
  event.preventDefault();
  handler();
});

function step(offset) {
  if (state.sessions.length === 0) return;
  const at = state.sessions.findIndex((one) => one.id === state.selectedSessionID);
  const next = (at + offset + state.sessions.length) % state.sessions.length;
  attach(state.sessions[next].id);
}

function toggleDiff() {
  const panel = el("diff");
  panel.hidden = !panel.hidden;
  if (!panel.hidden) void loadDiff();
  fitTerminal();
}

el("diff-close").onclick = toggleDiff;

// MARK: - Running

// The server never sends state, only word that it moved: one description of the
// world, asked for again, rather than a stream of patches to keep in step.
function watch() {
  const socket = new WebSocket(`ws://${location.host}/api/watch`);
  socket.onmessage = () => refresh();
  // A window left open across a server restart should come back on its own.
  socket.onclose = () => setTimeout(watch, 1000);
}

globalThis.addEventListener("resize", fitTerminal);
new ResizeObserver(fitTerminal).observe(el("terminal"));

watch();
refresh();
