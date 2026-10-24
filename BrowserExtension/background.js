// Nidestream browser integration: hands downloads, links and detected media to the Nidestream app,
// which listens on 127.0.0.1:51515. Runs as a service worker (Chromium) or event page (Firefox).

const APP = "http://127.0.0.1:51515";
const DEFAULT_EXTENSIONS = ["zip", "rar", "7z", "dmg", "pkg", "iso", "exe", "msi", "mp4", "mkv", "mov", "mp3", "pdf"];
const MEDIA_URL = /\.(mp4|m4v|webm|mkv|mov|flv|m3u8|mp3|m4a|aac|ogg|oga|opus|wav|flac)(\?|#|$)/i;
const SEGMENT_URL = /\.(ts|m4s|m4f|cmfv|cmfa)(\?|#|$)/i;
const BINARY_MIME = /^(application\/(octet-stream|zip|x-zip|x-7z|x-rar|vnd\.rar|x-apple-diskimage|x-msdownload|x-iso9660|gzip|x-gzip|x-tar|x-bzip2|x-xz|pdf)|video\/|audio\/)/i;

let config = { capture: true, extensions: DEFAULT_EXTENSIONS, minSizeKB: 0 };
let lastCheck = 0;
let online = false;
let captureEnabled = true;
const bypass = new Set();

chrome.storage.local.get({ captureEnabled: true }).then((stored) => { captureEnabled = stored.captureEnabled; });

// ---------------------------------------------------------------------------
// Talking to the app

async function call(path, body) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3000);
  try {
    const options = body
      ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), signal: controller.signal }
      : { signal: controller.signal };
    const response = await fetch(APP + path, options);
    if (!response.ok) throw new Error("Nidestream answered " + response.status);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

async function refresh(force = false) {
  if (!force && Date.now() - lastCheck < 5000) return online;
  lastCheck = Date.now();
  try {
    config = { ...config, ...(await call("/config")) };
    online = true;
  } catch {
    online = false;
  }
  return online;
}

async function cookieHeader(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch {
    return "";
  }
}

async function cookiesByHost(urls) {
  const origins = [...new Set(urls.map((u) => { try { return new URL(u).origin; } catch { return null; } }).filter(Boolean))].slice(0, 25);
  const result = {};
  for (const origin of origins) {
    const header = await cookieHeader(origin + "/");
    if (header) result[new URL(origin).host] = header;
  }
  return result;
}

async function sendDownload({ url, referrer, fileName, fileSize, mime, pageTitle, kind }) {
  if (!(await refresh(true))) throw new Error("offline");
  return call("/add", {
    url,
    referrer: referrer || null,
    fileName: fileName || null,
    fileSize: fileSize > 0 ? fileSize : null,
    mime: mime || null,
    pageTitle: pageTitle || null,
    kind: kind || null,
    cookies: await cookieHeader(url),
    userAgent: navigator.userAgent,
  });
}

async function sendLinks(links, tab, source) {
  if (!(await refresh(true))) throw new Error("offline");
  return call("/links", {
    links,
    referrer: tab?.url || null,
    cookies: await cookiesByHost(links.map((l) => l.url)),
    userAgent: navigator.userAgent,
    pageTitle: tab?.title || null,
    source,
  });
}

function toast(tabId, text) {
  if (tabId == null || tabId < 0) return;
  chrome.tabs.sendMessage(tabId, { type: "nidestream-toast", text }).catch(() => {});
}

function explain(error) {
  if (String(error?.message || error) === "offline") return "Nidestream isn't running. Open the app and try again.";
  if (String(error?.message || error) === "no-media") return "No downloadable stream found yet. Play the video for a moment, then try again.";
  return "Couldn't send this to Nidestream.";
}

// ---------------------------------------------------------------------------
// Taking over browser downloads

function extensionOf(url, filename) {
  let name = filename || "";
  if (!name) { try { name = new URL(url).pathname; } catch { name = url; } }
  const match = name.split(/[\\/]/).pop().match(/\.([a-z0-9]{1,8})$/i);
  return match ? match[1].toLowerCase() : "";
}

function shouldCapture(item) {
  if (!captureEnabled || !config.capture) return false;
  const url = item.finalUrl || item.url;
  if (!/^https?:/i.test(url)) return false; // blob:, data: and file: stay with the browser
  if (item.byExtensionId && item.byExtensionId === chrome.runtime.id) return false;
  const size = item.totalBytes || item.fileSize || 0;
  if (size > 0 && size < (config.minSizeKB || 0) * 1024) return false;
  const ext = extensionOf(url, item.filename);
  if (ext && (config.extensions || []).includes(ext)) return true;
  return !ext && BINARY_MIME.test(item.mime || "");
}

chrome.downloads.onCreated.addListener(async (item) => {
  const url = item.finalUrl || item.url;
  if (bypass.has(url)) { bypass.delete(url); return; }
  // Load the app's file-type list before deciding (the worker may have just started).
  if (!(await refresh()) || !shouldCapture(item)) return;
  try { await chrome.downloads.cancel(item.id); } catch {}
  try { await chrome.downloads.erase({ id: item.id }); } catch {}
  try {
    await sendDownload({
      url,
      referrer: item.referrer,
      fileName: item.filename ? item.filename.split(/[\\/]/).pop() : null,
      fileSize: item.totalBytes || item.fileSize,
      mime: item.mime,
    });
  } catch {
    // Hand it back to the browser rather than losing the download.
    bypass.add(url);
    chrome.downloads.download({ url });
  }
});

// ---------------------------------------------------------------------------
// Context menus

function createMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "nidestream-link", title: "Download with Nidestream", contexts: ["link"] });
    chrome.contextMenus.create({ id: "nidestream-media", title: "Download media with Nidestream", contexts: ["video", "audio"] });
    chrome.contextMenus.create({ id: "nidestream-selection", title: "Download selected links with Nidestream", contexts: ["selection"] });
    chrome.contextMenus.create({ id: "nidestream-page", title: "Download all links with Nidestream", contexts: ["page"] });
  });
}
chrome.runtime.onInstalled.addListener(createMenus);
chrome.runtime.onStartup.addListener(createMenus);

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    switch (info.menuItemId) {
      case "nidestream-link":
        await sendDownload({ url: info.linkUrl, referrer: info.pageUrl, pageTitle: tab?.title });
        break;
      case "nidestream-media":
        await downloadMedia(tab, info.srcUrl);
        break;
      case "nidestream-selection":
      case "nidestream-page":
        await sendPageLinks(tab, info.menuItemId === "nidestream-selection", info.frameId);
        break;
    }
  } catch (error) {
    toast(tab?.id, explain(error));
  }
});

// Runs inside the page.
function collectLinks(selectionOnly) {
  const found = new Map();
  const add = (href, text) => {
    try {
      const url = new URL(href, document.baseURI);
      if (!/^https?:$/.test(url.protocol)) return;
      url.hash = "";
      if (!found.has(url.href)) found.set(url.href, { url: url.href, text: (text || "").trim().replace(/\s+/g, " ").slice(0, 200) });
    } catch {}
  };
  const selection = window.getSelection();
  const included = (el) => !selectionOnly || (selection && selection.rangeCount > 0 && selection.containsNode(el, true));
  document.querySelectorAll("a[href]").forEach((a) => { if (included(a)) add(a.href, a.textContent || a.title); });
  if (!selectionOnly) {
    document.querySelectorAll("video[src], audio[src], source[src], embed[src], img[src]").forEach((el) => add(el.src, el.alt || el.title));
  }
  return [...found.values()].slice(0, 5000);
}

async function sendPageLinks(tab, selectionOnly, frameId) {
  if (!tab?.id) return;
  const results = await chrome.scripting.executeScript({
    target: { tabId: tab.id, frameIds: [frameId || 0] },
    func: collectLinks,
    args: [selectionOnly],
  });
  const links = results?.[0]?.result || [];
  if (!links.length) { toast(tab.id, "No links found."); return; }
  await sendLinks(links, tab, selectionOnly ? "selection" : "page");
}

// ---------------------------------------------------------------------------
// Video grabber: watch network traffic for media files and HLS playlists, per tab

const media = new Map(); // tabId -> Map(key -> item)

chrome.storage.session?.get?.("media").then((stored) => {
  for (const [tabId, items] of Object.entries(stored?.media || {})) media.set(Number(tabId), new Map(items));
}).catch(() => {});

let saveTimer = null;
function persistMedia() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    const plain = {};
    for (const [tabId, items] of media) plain[tabId] = [...items.entries()];
    chrome.storage.session?.set?.({ media: plain }).catch(() => {});
  }, 500);
}

function updateBadge(tabId) {
  const count = media.get(tabId)?.size || 0;
  chrome.action.setBadgeBackgroundColor({ tabId, color: "#1A7FD6" }).catch(() => {});
  chrome.action.setBadgeText({ tabId, text: count ? String(count) : "" }).catch(() => {});
}

chrome.webRequest.onBeforeRequest.addListener((details) => {
  if (details.tabId >= 0 && media.has(details.tabId)) {
    media.delete(details.tabId);
    updateBadge(details.tabId);
    persistMedia();
  }
}, { urls: ["<all_urls>"], types: ["main_frame"] });

chrome.webRequest.onHeadersReceived.addListener((details) => {
  if (details.tabId < 0 || details.statusCode >= 400) return;
  const headers = {};
  for (const header of details.responseHeaders || []) headers[header.name.toLowerCase()] = header.value || "";
  const type = (headers["content-type"] || "").split(";")[0].trim().toLowerCase();
  const url = details.url;
  const isHLS = type.includes("mpegurl") || /\.m3u8(\?|#|$)/i.test(url);
  if (!isHLS) {
    if (type === "video/mp2t" || SEGMENT_URL.test(url)) return; // pieces of a stream, not the stream
    if (!(type.startsWith("video/") || type.startsWith("audio/") || MEDIA_URL.test(url))) return;
  }
  let size = parseInt(headers["content-length"] || "0", 10);
  const range = (headers["content-range"] || "").match(/\/(\d+)\s*$/);
  if (range) size = parseInt(range[1], 10);
  if (!isHLS && size > 0 && size < 300 * 1024) return; // UI sounds and tiny clips

  let key = url;
  if (!isHLS) {
    // Players fetch the same file in many ranged requests; count it once.
    try { const u = new URL(url); ["range", "rn", "rbuf"].forEach((p) => u.searchParams.delete(p)); key = u.href; } catch {}
  }
  const items = media.get(details.tabId) || new Map();
  if (items.has(key)) return;
  items.set(key, { url, type: isHLS ? "hls" : (type || "media"), size: size || null, time: Date.now() });
  media.set(details.tabId, items);
  updateBadge(details.tabId);
  persistMedia();
}, { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "object", "other", "main_frame", "sub_frame"] }, ["responseHeaders"]);

chrome.tabs.onRemoved.addListener((tabId) => {
  media.delete(tabId);
  persistMedia();
});

function mediaFor(tabId) {
  return [...(media.get(tabId)?.values() || [])];
}

async function downloadMedia(tab, src, title) {
  const pageTitle = title || tab?.title;
  const direct = src && /^https?:/i.test(src) ? src : null;
  const candidates = mediaFor(tab?.id);
  if (direct && !candidates.some((c) => c.url === direct)) candidates.unshift({ url: direct, type: /\.m3u8/i.test(direct) ? "hls" : "video", size: null });
  if (!candidates.length) throw new Error("no-media");
  if (candidates.length === 1) {
    const only = candidates[0];
    return sendDownload({ url: only.url, referrer: tab?.url, pageTitle, kind: only.type === "hls" ? "hls" : null, fileSize: only.size });
  }
  return sendLinks(candidates.map((c) => ({ url: c.url, text: pageTitle, type: c.type, size: c.size })), tab, "media");
}

// ---------------------------------------------------------------------------
// Messages from the popup and the in-page video button

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  (async () => {
    switch (message.type) {
      case "status":
        return { online: await refresh(true), captureEnabled };
      case "setCapture":
        captureEnabled = !!message.value;
        await chrome.storage.local.set({ captureEnabled });
        return { ok: true };
      case "listMedia":
        return { items: mediaFor(message.tabId) };
      case "downloadItem": {
        const tab = await chrome.tabs.get(message.tabId);
        await sendDownload({ url: message.item.url, referrer: tab.url, pageTitle: tab.title, kind: message.item.type === "hls" ? "hls" : null, fileSize: message.item.size });
        return { ok: true };
      }
      case "allLinks": {
        const tab = await chrome.tabs.get(message.tabId);
        await sendPageLinks(tab, false, 0);
        return { ok: true };
      }
      case "videoButton":
        await downloadMedia(sender.tab, message.src, message.title);
        return { ok: true };
      default:
        return { error: "unknown" };
    }
  })().then(reply, (error) => reply({ error: explain(error) }));
  return true;
});
