// public/app.js — chat enhancement script.
//
// Posts user messages to the merjs proxy at /api/chat, which forwards to the
// FastAPI backend's SSE endpoint, aggregates the streamed tokens + citations,
// and returns a single JSON {message, citations, grounded, confidence}.
//
// On failure we keep the user's text in the input so they can retry without
// retyping, surface the error inline, and add a one-click "Retry" button.

(function () {
  const form = document.getElementById("cp-chat-form");
  const log = document.getElementById("cp-chat-log");
  const input = document.getElementById("cp-chat-input");
  const sendBtn = document.getElementById("cp-chat-send");
  const moduleSel = document.getElementById("cp-chat-module");
  if (!form || !log || !input) return;

  const history = [];
  let lastFailedMessage = null;

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    }[c]));
  }

  function bubble(role) {
    const div = document.createElement("div");
    div.className = "cp-chat-msg cp-chat-msg-" + role;
    log.appendChild(div);
    log.scrollTop = log.scrollHeight;
    return div;
  }

  function renderCitations(parent, citations) {
    if (!Array.isArray(citations) || citations.length === 0) return;
    const cites = document.createElement("div");
    cites.className = "cp-chat-citations";
    cites.innerHTML = "<strong>Sources</strong><br>";
    citations.forEach((c) => {
      const a = document.createElement("a");
      a.className = "cp-chat-citation";
      a.href = c.url || "#";
      a.target = "_blank";
      a.rel = "noopener";
      a.textContent =
        (c.title || "Source") + (c.snippet ? " — " + c.snippet : "");
      cites.appendChild(a);
    });
    parent.appendChild(cites);
  }

  async function sendMessage(message) {
    lastFailedMessage = null;
    input.disabled = true;
    sendBtn.disabled = true;

    const userBubble = bubble("user");
    userBubble.textContent = message;
    history.push({ role: "user", content: message });

    const pending = bubble("reply");
    pending.textContent = "…thinking";

    try {
      const resp = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          message,
          module_id: moduleSel && moduleSel.value ? moduleSel.value : null,
          history,
        }),
      });
      if (!resp.ok) {
        throw new Error("HTTP " + resp.status);
      }
      const data = await resp.json();
      pending.textContent = data.message || "(no reply)";
      renderCitations(pending, data.citations);
      if (data.source === "mock") {
        const tag = document.createElement("div");
        tag.className = "cp-chat-citations";
        tag.style.color = "var(--cp-warning)";
        tag.textContent = "Demo answer — backend not connected.";
        pending.appendChild(tag);
      }
      input.value = "";
    } catch (err) {
      pending.classList.remove("cp-chat-msg-reply");
      pending.classList.add("cp-chat-msg-system");
      pending.textContent =
        "Couldn't reach CanvasPilot: " + err.message + ". ";
      const retry = document.createElement("button");
      retry.type = "button";
      retry.className = "cp-btn cp-btn-ghost";
      retry.style.marginLeft = "8px";
      retry.textContent = "Retry";
      retry.addEventListener("click", () => {
        pending.remove();
        sendMessage(message);
      });
      pending.appendChild(retry);
      lastFailedMessage = message;
      input.value = message;
    } finally {
      input.disabled = false;
      sendBtn.disabled = false;
      input.focus();
    }
  }

  form.addEventListener("submit", (ev) => {
    ev.preventDefault();
    const message = input.value.trim();
    if (!message) return;
    sendMessage(message);
  });

  // Surface a tiny hint if the user navigates back and forth and we still
  // have a queued failure.
  window.addEventListener("beforeunload", () => {
    if (lastFailedMessage) {
      sessionStorage.setItem("cp:last-failed", lastFailedMessage);
    }
  });
  const queued = sessionStorage.getItem("cp:last-failed");
  if (queued) {
    input.value = queued;
    sessionStorage.removeItem("cp:last-failed");
  }
})();
