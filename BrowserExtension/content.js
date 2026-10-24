// Floating "Download video" button over large videos, plus toasts from the background script.
(() => {
  if (window.__nidestreamLoaded) return;
  window.__nidestreamLoaded = true;

  let host = null;
  let button = null;
  let toastBox = null;
  let current = null;
  let hideTimer = null;

  function ensureUI() {
    if (host) return;
    host = document.createElement("nidestream-overlay");
    host.style.cssText = "all: initial; position: fixed; inset: 0 auto auto 0; width: 0; height: 0; z-index: 2147483647;";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `
      <style>
        button {
          position: fixed; display: none; align-items: center; gap: 6px; padding: 6px 11px 6px 9px;
          font: 600 12px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #fff;
          background: rgba(26, 127, 214, 0.94); border: 1px solid rgba(255,255,255,0.25); border-radius: 999px;
          box-shadow: 0 2px 10px rgba(0,0,0,0.35); cursor: pointer; backdrop-filter: blur(6px);
        }
        button:hover { background: rgba(21, 101, 192, 0.98); }
        svg { width: 14px; height: 14px; }
        .toast {
          position: fixed; right: 18px; bottom: 18px; max-width: 340px; padding: 10px 14px; border-radius: 10px;
          font: 13px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #fff;
          background: rgba(28, 28, 30, 0.94); box-shadow: 0 4px 18px rgba(0,0,0,0.35);
          opacity: 0; transform: translateY(8px); transition: opacity .2s, transform .2s; pointer-events: none;
        }
        .toast.show { opacity: 1; transform: none; }
      </style>
      <button type="button" title="Download with Nidestream">
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M8 2v8M4.5 6.5 8 10l3.5-3.5M3 13h10"/>
        </svg>
        Download video
      </button>
      <div class="toast"></div>`;
    button = root.querySelector("button");
    toastBox = root.querySelector(".toast");
    button.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    button.addEventListener("mouseleave", scheduleHide);
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      const video = current;
      if (!video) return;
      chrome.runtime.sendMessage({ type: "videoButton", src: video.currentSrc || video.src || "", title: document.title }, (response) => {
        if (chrome.runtime.lastError) return;
        showToast(response?.error || "Sent to Nidestream");
      });
    });
    (document.body || document.documentElement).appendChild(host);
  }

  function showToast(text) {
    ensureUI();
    toastBox.textContent = text;
    toastBox.classList.add("show");
    clearTimeout(toastBox._timer);
    toastBox._timer = setTimeout(() => toastBox.classList.remove("show"), 3200);
  }

  function place(video) {
    const rect = video.getBoundingClientRect();
    button.style.display = "inline-flex";
    button.style.top = `${Math.max(rect.top + 10, 6)}px`;
    button.style.left = `${Math.max(rect.right - button.offsetWidth - 10, 6)}px`;
  }

  function scheduleHide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (button) button.style.display = "none";
      current = null;
    }, 1200);
  }

  function videoAt(x, y) {
    for (const video of document.querySelectorAll("video")) {
      const r = video.getBoundingClientRect();
      if (r.width >= 240 && r.height >= 135 && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return video;
    }
    return null;
  }

  let pending = false;
  document.addEventListener("mousemove", (event) => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      const video = videoAt(event.clientX, event.clientY);
      if (video) {
        ensureUI();
        clearTimeout(hideTimer);
        current = video;
        place(video);
      } else if (current) {
        scheduleHide();
      }
    });
  }, { passive: true, capture: true });

  window.addEventListener("scroll", () => { if (current && button) place(current); }, { passive: true, capture: true });

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === "nidestream-toast") showToast(message.text);
  });
})();
