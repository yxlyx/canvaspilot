// Live M3 progressive enhancement. Secrets are sent only in same-origin JSON
// request bodies and are never written to URLs, logs, HTML, or storage.
(function () {
  "use strict";
  const endpoint = "/api/m3";
  const numeric = new Set(["question_number", "awarded_marks", "available_marks", "confidence"]);
  function status(form, message, error) {
    const node = form.querySelector(".cp-form-status") || form.closest(".cp-provider-action-stack")?.querySelector(".cp-form-status") || form.closest("article")?.querySelector(".cp-form-status");
    if (node) {
      node.textContent = message;
      node.classList.toggle("cp-error", !!error);
      node.setAttribute("role", error ? "alert" : "status");
      node.setAttribute("aria-live", error ? "assertive" : "polite");
      if (error) { if (!node.hasAttribute("tabindex")) node.tabIndex = -1; node.focus({ preventScroll: false }); }
    }
  }
  function errorMessage(value, fallback) {
    function text(item) {
      if (typeof item === "string") return item;
      if (Array.isArray(item)) return item.map(text).filter(Boolean).join("; ");
      if (!item || typeof item !== "object") return "";
      const message = text(item.message) || text(item.msg) || text(item.detail) || text(item.error) || text(item.errors);
      if (!message) return "";
      const location = Array.isArray(item.loc) ? item.loc.filter((part) => part !== "body").join(" → ") : "";
      return location ? location + ": " + message : message;
    }
    return text(value?.detail) || text(value?.error) || text(value) || fallback;
  }
  function lock(form) {
    if (form.dataset.inFlight === "true") return null;
    form.dataset.inFlight = "true";
    const controls = Array.from(form.querySelectorAll("button,input,select,textarea"));
    const enabled = controls.map((control) => !control.disabled);
    controls.forEach((control) => { control.disabled = true; });
    return () => { controls.forEach((control, index) => { if (enabled[index]) control.disabled = false; }); delete form.dataset.inFlight; };
  }
  function idempotencyKey() {
    if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
    const bytes = new Uint8Array(16); globalThis.crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    return Array.from(bytes, (value, index) => ([4, 6, 8, 10].includes(index) ? "-" : "") + value.toString(16).padStart(2, "0")).join("");
  }
  function envelope(form) {
    const data = new FormData(form); const action = String(data.get("action") || "");
    const result = { action }; const payload = {};
    ["id", "child_id", "slug"].forEach((key) => { const value = data.get(key); if (value) result[key] = String(value); });
    for (const [key, raw] of data.entries()) {
      if (["action", "id", "child_id", "slug"].includes(key) || raw instanceof File) continue;
      const value = key === "topic" ? String(raw).trim() : String(raw);
      if (value === "") continue;
      payload[key] = numeric.has(key) ? Number(value) : value;
    }
    form.querySelectorAll('input[type="checkbox"]').forEach((box) => { if (box.name !== "page_ids") payload[box.name] = box.checked; });
    if (action === "output.create") {
      const scope = payload.scope_type; delete payload.scope_type;
      ["source_ids", "wiki_page_id", "topic"].forEach((key) => { if (key !== scope) delete payload[key]; });
      if (scope === "source_ids" && payload.source_ids) payload.source_ids = [payload.source_ids];
    }
    if (action === "provider.save") {
      if (["codegraff", "openai", "google_gemini"].includes(payload.provider)) delete payload.endpoint;
      else if (!payload.endpoint) payload.endpoint = null;
    }
    if (action === "paper.updateQuestion") ["awarded_marks", "available_marks"].forEach((key) => { if (!data.get(key)) payload[key] = null; });
    if (Object.keys(payload).length) result.payload = payload;
    return result;
  }
  async function request(form, body, release) {
    const readOnly = body.action === "wiki.export" || body.action === "page.download";
    if (!readOnly) {
      form.dataset.idempotencyKey ||= idempotencyKey();
      body.idempotency_key ||= form.dataset.idempotencyKey;
    }
    const response = await fetch(endpoint, { method: "POST", headers: { "Content-Type": "application/json" }, credentials: "same-origin", body: JSON.stringify(body) });
    if (response.status < 500 && response.status !== 429) delete form.dataset.idempotencyKey;
    if (response.status === 401) { release?.(); window.location.assign("/login"); throw new Error("Your session expired. Sign in again."); }
    return response;
  }
  function updateScope(form) {
    const select = form.querySelector("[data-scope-select]");
    if (!select) return;
    form.querySelectorAll("[data-scope-field]").forEach((field) => {
      const active = field.dataset.scopeField === select.value;
      field.hidden = !active;
      field.querySelectorAll("input,select,textarea").forEach((control) => {
        control.disabled = !active;
        control.required = active;
      });
    });
  }
  function valid(form, body) {
    if (body.action !== "output.create") return true;
    const scope = form.querySelector("[data-scope-select]")?.value;
    if (scope === "topic" && !body.payload?.topic) {
      status(form, "Enter a topic that is not blank.", true);
      form.querySelector('[name="topic"]')?.focus();
      return false;
    }
    return true;
  }
  async function submit(form, body) {
    if (!valid(form, body)) return;
    const release = lock(form); if (!release) return;
    if (form.dataset.confirm && !window.confirm(form.dataset.confirm)) { release(); return; }
    let approvalWindow = null;
    if (body.action === "provider.auth.start" && body.id === "codegraff" && form.hasAttribute("data-codegraff-auth-start")) {
      approvalWindow = window.open(form.dataset.approvalBootstrap, "wikibase-codegraff-" + Date.now());
    }
    status(form, "Working…", false);
    let completionMessage = "Saved.";
    try {
      const response = await request(form, body, release);
      if (!response.ok) { let message = "Request failed (" + response.status + ")."; try { message = errorMessage(await response.json(), message); } catch (_) {} throw new Error(message); }
      if (body.action === "provider.auth.start") {
        const result = await response.json();
        if (result.provider === "codegraff" && result.id) {
          const approvalUrl = result.verification_uri_complete || result.verification_uri;
          if (!approvalUrl) throw new Error("Codegraff did not return an approval page.");
          if (approvalWindow && !approvalWindow.closed) approvalWindow.location.href = approvalUrl;
          else window.open(approvalUrl, "_blank", "noopener,noreferrer");
          status(form, "Approval page opened. Authorize the matching device on Codegraff…", false);
          window.location.assign("/settings/providers?provider=codegraff&session=" + encodeURIComponent(result.id));
          return;
        }
        if (!result.authorization_url) throw new Error("The provider did not return a sign-in URL.");
        status(form, "Opening secure browser sign-in…", false);
        window.location.assign(result.authorization_url);
        return;
      }
      if (body.action === "provider.auth.poll") {
        const result = await response.json();
        if (result.status === "pending") {
          status(form, "Still waiting for Codegraff authorization.", false);
          release();
          return;
        }
        if (result.status !== "completed") throw new Error(result.error_message || "Codegraff authorization was not completed.");
        status(form, "Codegraff authorized. Loading model choices…", false);
        release();
        window.location.assign("/settings/providers?provider=codegraff#choose-model");
        return;
      }
      if (body.action === "provider.save" && form.hasAttribute("data-provider-save")) {
        status(form, "Configuration saved. Testing the connection…", false);
        const tested = await request(form, { action: "provider.test", id: body.payload.provider, idempotency_key: idempotencyKey() }, release);
        if (!tested.ok) { let message = "The connection test failed (" + tested.status + ")."; try { message = errorMessage(await tested.json(), message); } catch (_) {} throw new Error(message); }
        const result = await tested.json();
        if (result.status !== "connected") throw new Error(result.last_error || "The provider rejected the key, endpoint, or model.");
        if (form.hasAttribute("data-provider-activate")) {
          status(form, "Connection tested. Making it the answer provider…", false);
          const activated = await request(form, { action: "provider.activate", id: body.payload.provider, idempotency_key: idempotencyKey() }, release);
          if (!activated.ok) { let message = "The provider could not be selected (" + activated.status + ")."; try { message = errorMessage(await activated.json(), message); } catch (_) {} throw new Error(message); }
          const activeResult = await activated.json();
          if (!activeResult.active_for_generation) throw new Error("The connection tested successfully but was not selected. Use the separate ‘Use for answers’ action to retry.");
          completionMessage = "Codegraff is ready for cited answers.";
        } else {
          completionMessage = "Connection test passed.";
        }
      }
      if (body.action === "provider.test") {
        const result = await response.json();
        if (result.status !== "connected") throw new Error(result.last_error || "The connection test failed.");
        completionMessage = "Connection test passed.";
      }
      if (body.action === "provider.activate") {
        const result = await response.json();
        if (!result.active_for_generation) throw new Error("The provider is connected but was not selected for answers.");
        completionMessage = "This provider is now used for answers.";
      }
      status(form, completionMessage, false);
      const target = form.dataset.success;
      if (target !== undefined) { release(); window.location.assign(target || window.location.href); } else release();
    } catch (error) {
      if (approvalWindow && !approvalWindow.closed) approvalWindow.close();
      status(form, error.message || "Request failed.", true);
      release();
    }
  }
  document.querySelectorAll("[data-m3-form]").forEach((form) => {
    const scope = form.querySelector("[data-scope-select]");
    if (scope) { scope.addEventListener("change", () => updateScope(form)); updateScope(form); }
    form.addEventListener("submit", (event) => { event.preventDefault(); if (form.dataset.inFlight !== "true") submit(form, envelope(form)); });
  });

  document.querySelectorAll("[data-copy-code]").forEach((button) => {
    button.addEventListener("click", async () => {
      const code = button.closest("[data-device-session]")?.querySelector("[data-user-code]")?.textContent?.trim();
      if (!code) return;
      try { await navigator.clipboard.writeText(code); button.textContent = "Copied"; }
      catch (_) { button.closest("[data-device-session]")?.querySelector("[data-user-code]")?.focus(); }
    });
  });

  const deviceSession = document.querySelector("[data-device-session][data-session-status='pending']");
  if (deviceSession) {
    const id = deviceSession.dataset.deviceSession;
    const interval = Math.max(2, Number(deviceSession.dataset.pollInterval || 5)) * 1000;
    const expiresAt = Date.parse(deviceSession.dataset.sessionExpires || "");
    const pollStatus = deviceSession.querySelector("[data-device-poll-status]");
    let transientFailures = 0;
    const stop = (message) => {
      if (!pollStatus) return;
      pollStatus.textContent = message;
      pollStatus.classList.add("cp-error");
      pollStatus.setAttribute("role", "alert");
    };
    const retry = (delay) => {
      if (Number.isFinite(expiresAt) && Date.now() >= expiresAt) return stop("This one-time code expired. Start the connection again.");
      window.setTimeout(poll, delay);
    };
    const retryTransient = () => {
      transientFailures += 1;
      if (transientFailures > 5) return stop("Automatic checking stopped after repeated connection errors. Use Check connection to try again.");
      retry(Math.min(interval * (2 ** transientFailures), 30000));
    };
    const poll = async () => {
      try {
        const response = await fetch(endpoint, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "same-origin",
          body: JSON.stringify({ action: "provider.auth.poll", id, idempotency_key: idempotencyKey() }),
        });
        if (response.status === 401) return window.location.assign("/login");
        if (!response.ok) {
          if (response.status === 429 || response.status >= 500) return retryTransient();
          let message = "Authorization can no longer be checked. Start the connection again.";
          try { message = errorMessage(await response.json(), message); } catch (_) {}
          return stop(message);
        }
        const result = await response.json();
        transientFailures = 0;
        if (result.status === "pending") return retry(Math.max(2, Number(result.poll_interval_seconds || interval / 1000)) * 1000);
        window.location.reload();
      } catch (_) { retryTransient(); }
    };
    retry(interval);
  }

  const upload = document.querySelector("[data-paper-upload]");
  if (upload) upload.addEventListener("submit", async (event) => {
    event.preventDefault(); if (upload.dataset.inFlight === "true") return;
    const file = upload.elements.paper.files[0];
    if (!file) return status(upload, "Choose a file.", true);
    const allowed = { "application/pdf": true, "text/plain": true, "text/markdown": true };
    const fallback = file.name.toLowerCase().endsWith(".md") ? "text/markdown" : file.name.toLowerCase().endsWith(".txt") ? "text/plain" : file.type;
    if (!allowed[fallback] || file.size > 10 * 1024 * 1024) return status(upload, "Choose a PDF, Markdown, or text file no larger than 10 MiB.", true);
    const release = lock(upload); if (!release) return;
    status(upload, "Reading and uploading privately…", false);
    try {
      const bytes = new Uint8Array(await file.arrayBuffer()); let binary = "";
      for (let offset = 0; offset < bytes.length; offset += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(offset, offset + 0x8000));
      const body = { action: "paper.upload", payload: { filename: file.name, content_type: fallback, content_base64: btoa(binary) } };
      const response = await request(upload, body, release);
      if (!response.ok) { let message = "Upload failed (" + response.status + ")."; try { message = errorMessage(await response.json(), message); } catch (_) {} throw new Error(message); }
      status(upload, "Saved.", false); release(); window.location.assign(upload.dataset.success || window.location.href);
    } catch (error) { status(upload, error.message || "Upload failed.", true); release(); }
  });

  async function download(form, body, fallbackName, expectedType) {
    const release = lock(form); if (!release) return; status(form, "Preparing download…", false);
    try {
      const response = await request(form, body, release);
      if (!response.ok) throw new Error("Export failed (" + response.status + ").");
      const type = (response.headers.get("content-type") || "").split(";")[0];
      if (type !== expectedType) throw new Error("The export returned an unexpected file type.");
      const blob = await response.blob(); if (!blob.size || blob.size > 10 * 1024 * 1024) throw new Error("The export was empty or too large.");
      const disposition = response.headers.get("content-disposition") || "";
      const match = /filename="([A-Za-z0-9._-]+)"/.exec(disposition); const name = match ? match[1] : fallbackName;
      const url = URL.createObjectURL(blob); const link = document.createElement("a"); link.href = url; link.download = name; link.rel = "noopener"; document.body.appendChild(link); link.click(); link.remove(); URL.revokeObjectURL(url);
      status(form, "Download ready.", false);
    } catch (error) { status(form, error.message || "Export failed.", true); } finally { release(); }
  }
  document.querySelectorAll("[data-page-download]").forEach((form) => form.addEventListener("submit", (event) => { event.preventDefault(); const slug = form.dataset.slug; download(form, { action: "page.download", slug }, slug + ".md", "text/markdown"); }));
  document.querySelectorAll("[data-wiki-export]").forEach((form) => form.addEventListener("submit", (event) => {
    event.preventDefault(); if (form.dataset.inFlight === "true") return;
    const all = event.submitter?.value === "all"; const ids = Array.from(form.querySelectorAll('input[name="page_ids"]:checked')).map((node) => node.value);
    if (!all && !ids.length) return status(form, "Select at least one page.", true);
    download(form, all ? { action: "wiki.export" } : { action: "wiki.export", payload: { page_ids: ids } }, "workspace-wiki.zip", "application/zip");
  }));
})();
