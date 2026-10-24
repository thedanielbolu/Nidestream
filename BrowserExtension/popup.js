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

function nameOf(url) {
  try {
    const path = new URL(url).pathname.split("/").filter(Boolean).pop();
    return decodeURIComponent(path || url);
  } catch {
    return url;
  }
}

async function render() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const status = await send({ type: "status" });
  statusLine.textContent = status.online ? "Connected to the app" : "Nidestream isn't running";
  statusLine.className = status.online ? "ok" : "bad";
  capture.checked = !!status.captureEnabled;

  const { items = [] } = tab ? await send({ type: "listMedia", tabId: tab.id }) : {};
  list.replaceChildren();
  empty.hidden = items.length > 0;
  for (const item of items) {
    const row = document.createElement("li");
    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = item.type === "hls" ? "HLS" : (item.type.split("/")[1] || "MEDIA").toUpperCase().slice(0, 5);
    const info = document.createElement("div");
    info.className = "info";
    const name = document.createElement("div");
    name.className = "name";
    name.textContent = nameOf(item.url);
    name.title = item.url;
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = [item.type === "hls" ? "Video stream" : item.type, formatSize(item.size)].filter(Boolean).join(" · ");
    info.append(name, meta);
    const button = document.createElement("button");
    button.className = "primary";
    button.textContent = "Download";
    button.disabled = !status.online;
    button.addEventListener("click", async () => {
      button.disabled = true;
      const result = await send({ type: "downloadItem", tabId: tab.id, item });
      button.textContent = result.error ? "Failed" : "Sent";
      if (result.error) statusLine.textContent = result.error;
    });
    row.append(tag, info, button);
    list.append(row);
  }

  document.getElementById("allLinks").disabled = !status.online || !tab;
  document.getElementById("allLinks").onclick = async () => {
    const result = await send({ type: "allLinks", tabId: tab.id });
    if (result.error) statusLine.textContent = result.error; else window.close();
  };
}

capture.addEventListener("change", () => send({ type: "setCapture", value: capture.checked }));
render();
