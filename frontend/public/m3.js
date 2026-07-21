// Live M3 progressive enhancement. Secrets are sent only in same-origin JSON
// request bodies and are never written to URLs, logs, HTML, or storage.
(function () {
  "use strict";
  const endpoint = "/api/m3";
  const numeric = new Set(["question_number", "awarded_marks", "available_marks", "confidence"]);
  function status(form, message, error) {
    const node = form.querySelector(".cp-form-status") || form.closest("article")?.querySelector(".cp-form-status");
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
      if (["openai", "google_gemini"].includes(payload.provider)) delete payload.endpoint;
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
    status(form, "Working…", false);
    try {
      const response = await request(form, body, release);
      if (!response.ok) { let message = "Request failed (" + response.status + ")."; try { message = errorMessage(await response.json(), message); } catch (_) {} throw new Error(message); }
      status(form, "Saved.", false);
      const target = form.dataset.success;
      if (target !== undefined) window.location.assign(target || window.location.href); else release();
    } catch (error) { status(form, error.message || "Request failed.", true); release(); }
  }
  document.querySelectorAll("[data-m3-form]").forEach((form) => {
    const scope = form.querySelector("[data-scope-select]");
    if (scope) { scope.addEventListener("change", () => updateScope(form)); updateScope(form); }
    form.addEventListener("submit", (event) => { event.preventDefault(); if (form.dataset.inFlight !== "true") submit(form, envelope(form)); });
  });

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
      status(upload, "Saved.", false); window.location.assign(upload.dataset.success || window.location.href);
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
