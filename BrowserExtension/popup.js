const statusLine = document.getElementById("status");
const capture = document.getElementById("capture");
const list = document.getElementById("media");
const empty = document.getElementById("empty");

function send(message) {
  return new Promise((resolve) => chrome.runtime.sendMessage(message, (response) => resolve(response || {})));
}

function formatSize(bytes) {
  if (!bytes) return "";
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
  return `${value.toFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}`;
}

const VIDEO = /^(mp4|m4v|webm|mkv|mov|avi|flv|wmv|ts)$/;
const AUDIO = /^(mp3|m4a|aac|ogg|oga|opus|wav|flac)$/;

function extensionOf(name) {
  const match = (name || "").match(/\.([a-z0-9]{1,5})$/i);
  return match ? match[1].toLowerCase() : "";
}

// "MKV" and "Video" rather than the server's MIME type, which is often just
// application/octet-stream ("some bytes").
function describe(item, fileName) {
  if (item.type === "hls") return { tag: "HLS", kind: "Video stream" };
  const ext = extensionOf(fileName);
  const mime = item.type || "";
  const kind = VIDEO.test(ext) || mime.startsWith("video/") ? "Video" : AUDIO.test(ext) || mime.startsWith("audio/") ? "Audio" : "File";
  return { tag: (ext || kind).toUpperCase().slice(0, 5), kind };
}

function nameOf(url) {
  try {
    const path = new URL(url).pathname.split("/").filter(Boolean).pop();
    return decodeURIComponent(path || url);
  } catch {
    return url;
  }
}

// How a row's button reads for what Nidestream has: [label, style, clickable].
function control(item, status, supported) {
  switch (status?.state) {
    case "downloading": return [`Downloading ${Math.floor((status.progress || 0) * 100)}%`, "state", false];
    case "queued": return ["Queued", "state", false];
    case "paused": return ["Resume", "primary", true];
    case "failed": return ["Retry", "primary", true];
    case "completed": return ["Downloaded ✓", "state ok", false];
  }
  if (!supported && item.sent) return ["Sent", "state", false];
  return ["Download", "primary", true];
}

const AFTER_SEND = { added: "Sent", existing: "Already downloading", resumed: "Resumed", downloaded: "Downloaded ✓" };

async function render() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const status = await send({ type: "status" });
  statusLine.textContent = status.online ? "Connected to the app" : "Nidestream isn't running";
  statusLine.className = status.online ? "ok" : "bad";
  capture.checked = !!status.captureEnabled;

  const { items = [] } = tab ? await send({ type: "listMedia", tabId: tab.id }) : {};
  list.replaceChildren();
  empty.hidden = items.length > 0;
  const rows = [];
  for (const item of items) {
    const row = document.createElement("li");
    const tag = document.createElement("span");
    tag.className = "tag";
    const info = document.createElement("div");
    info.className = "info";
    const name = document.createElement("div");
    name.className = "name";
    name.title = item.url;
    const meta = document.createElement("div");
    meta.className = "meta";
    const label = (fileName) => {
      const { tag: short, kind } = describe(item, fileName);
      tag.textContent = short;
      name.textContent = fileName;
      meta.textContent = [kind, formatSize(item.size)].filter(Boolean).join(" · ");
    };
    label(nameOf(item.url));
    info.append(name, meta);
    const button = document.createElement("button");
    button.className = "primary";
    button.textContent = "Download";
    button.disabled = !status.online;
    button.addEventListener("click", async () => {
      button.disabled = true;
      const result = await send({ type: "downloadItem", tabId: tab.id, item });
      button.textContent = result.error ? "Failed" : (AFTER_SEND[result.status] || "Sent");
      button.className = "state";
      if (result.error) statusLine.textContent = result.error;
      item.sent = !result.error;
      setTimeout(update, 800);
    });
    row.append(tag, info, button);
    list.append(row);
    rows.push({ item, label, button });
  }

  // Ask Nidestream what it already has, and keep the progress current while the popup is open.
  async function update() {
    if (!status.online || !rows.length) return;
    const { supported, items: known = {} } = await send({ type: "mediaStatus", urls: rows.map((r) => r.item.url) });
    let active = false;
    for (const { item, label, button } of rows) {
      const state = known[item.url];
      const [text, style, clickable] = control(item, state, supported);
      button.textContent = text;
      button.className = style;
      button.disabled = !clickable;
      if (state?.fileName) label(state.fileName);
      active ||= state?.state === "downloading" || state?.state === "queued";
    }
    clearTimeout(update.timer);
    if (active) update.timer = setTimeout(update, 1000);
  }
  await update();

  document.getElementById("allLinks").disabled = !status.online || !tab;
  document.getElementById("allLinks").onclick = async () => {
    const result = await send({ type: "allLinks", tabId: tab.id });
    if (result.error) statusLine.textContent = result.error; else window.close();
  };
}

capture.addEventListener("change", () => send({ type: "setCapture", value: capture.checked }));
render();
