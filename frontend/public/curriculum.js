(() => {
  "use strict";

  const form = document.querySelector("[data-module-import]");
  const previewRegion = document.querySelector("[data-import-preview]");
  if (!form || !previewRegion || form.querySelector("fieldset:disabled")) return;

  const endpoint = "/api/curriculum";
  const status = form.querySelector("[data-import-status]");
  const submitButton = form.querySelector('button[type="submit"]');
  const steps = [...document.querySelectorAll(".cp-import-steps li")];
  let previewId = null;

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  function setStatus(message, state = "") {
    status.textContent = message;
    status.dataset.state = state;
  }

  function setStep(activeIndex) {
    steps.forEach((step, index) => {
      step.toggleAttribute("data-complete", index < activeIndex);
      if (index === activeIndex) step.setAttribute("aria-current", "step");
      else step.removeAttribute("aria-current");
    });
  }

  function errorText(response, data, fallback, action) {
    if (response.status === 401) return "Your session expired. Sign in, then retry. No modules were changed.";
    if (response.status === 409) return "This import preview expired or was already used. Start a fresh import; your existing modules are unchanged.";
    if (action === "import.commit" && response.status >= 500) return "The import result could not be confirmed. Open the dashboard and check your modules before retrying.";
    const detail = data && (data.detail || data.error);
    if (Array.isArray(detail)) return `${detail.map((item) => item.msg || "Invalid value").join(" ")} No modules were changed.`;
    return typeof detail === "string" ? `${detail} No modules were changed.` : fallback;
  }

  async function call(action, ids, payload) {
    let response;
    try {
      response = await fetch(endpoint, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify(Object.assign({ action, payload: payload || {} }, ids || {})),
      });
    } catch (_) {
      if (action === "import.commit") throw new Error("The connection ended before the import result was confirmed. Open the dashboard and check your modules before retrying.");
      throw new Error("NUSMods could not be reached. Check your connection and retry. No modules were changed.");
    }
    let data = null;
    try { data = await response.json(); } catch (_) {}
    if (!response.ok) {
      throw new Error(errorText(response, data, "The module import could not be completed. Retry; no existing modules were changed.", action));
    }
    return data;
  }

  function setBusy(button, busy, label) {
    button.disabled = busy;
    button.setAttribute("aria-busy", String(busy));
    if (!button.dataset.label) button.dataset.label = button.textContent;
    button.textContent = busy ? label : button.dataset.label;
  }

  function setImportMethod(method) {
    const manual = method === "manual_codes";
    const shareField = form.querySelector("[data-share-field]");
    const codesField = form.querySelector("[data-codes-field]");
    const semesterField = form.querySelector("[data-semester-field]");
    const semester = semesterField.querySelector("select");
    shareField.hidden = manual;
    codesField.hidden = !manual;
    semesterField.hidden = !manual;
    shareField.querySelector("input").required = !manual;
    codesField.querySelector("input").required = manual;
    semester.required = manual;
    semester.disabled = !manual;
  }

  form.addEventListener("change", (event) => {
    if (event.target.name === "import_method") setImportMethod(event.target.value);
  });
  setImportMethod(form.elements.import_method.value);

  function provenance(item) {
    const details = el("details", "cp-provenance");
    details.appendChild(el("summary", "", "Provider snapshot details"));
    const list = el("dl");
    [
      ["Version", item.provider_version],
      ["Fetched", item.fetched_at],
      ["Payload SHA-256", item.payload_sha256],
      ["Source URL", item.source_url],
    ].forEach(([key, value]) => {
      const row = el("div");
      row.append(el("dt", "", key), el("dd", "", value || "Unavailable"));
      list.appendChild(row);
    });
    details.appendChild(list);
    return details;
  }

  function updateConfirmLabel() {
    const button = previewRegion.querySelector("[data-commit-import]");
    if (!button) return;
    const selected = previewRegion.querySelectorAll('input[name="selected_codes"]:checked').length;
    const archived = previewRegion.querySelectorAll('input[name="archive_codes"]:checked').length;
    button.classList.toggle("cp-btn-primary", archived === 0);
    button.classList.toggle("cp-btn-danger", archived > 0);
    if (selected && archived) button.textContent = `Import ${selected} module${selected === 1 ? "" : "s"} and archive ${archived} module${archived === 1 ? "" : "s"}`;
    else if (archived) button.textContent = `Archive ${archived} module${archived === 1 ? "" : "s"}`;
    else if (selected) button.textContent = `Import ${selected} module${selected === 1 ? "" : "s"}`;
    else button.textContent = "Choose modules to import";
  }

  function renderPreview(data) {
    previewId = data.id;
    previewRegion.replaceChildren();
    previewRegion.hidden = false;
    previewRegion.removeAttribute("aria-busy");

    const availableItems = (data.items || []).filter((item) => item.available && !["unavailable", "not_found"].includes(item.disposition));
    const header = el("header", "cp-import-preview-header");
    const heading = el("div");
    const title = el("h3", "", `${availableItems.length} module${availableItems.length === 1 ? "" : "s"} ready`);
    title.tabIndex = -1;
    heading.append(
      el("p", "eyebrow", "Review import"),
      title,
      el("p", "", `${data.academic_year} · Semester ${data.semester} · ${data.import_method.replaceAll("_", " ")}`),
    );
    header.append(heading, el("span", "cp-import-review-state", "Nothing saved yet"));
    previewRegion.appendChild(header);

    const reconciliation = el("dl", "cp-reconciliation");
    [
      ["New", data.reconciliation.added],
      ["Already added", data.reconciliation.unchanged],
      ["Not in this import", data.reconciliation.removed],
      ["Needs attention", data.reconciliation.ambiguous],
    ].forEach(([label, values]) => {
      const group = el("div");
      group.append(el("dt", "", label), el("dd", "", (values || []).join(", ") || "None"));
      reconciliation.appendChild(group);
    });
    previewRegion.appendChild(reconciliation);

    const itemList = el("div", "cp-preview-list");
    (data.items || []).forEach((item) => {
      const row = el("article", "cp-preview-card");
      const available = item.available && !["unavailable", "not_found"].includes(item.disposition);
      const label = el("label", "cp-preview-choice");
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.name = "selected_codes";
      checkbox.value = item.code;
      checkbox.checked = available && item.disposition !== "already_enrolled";
      checkbox.disabled = !available;
      const identity = el("span");
      identity.append(el("strong", "", item.code), el("small", "", item.title));
      label.append(checkbox, identity);
      const state = el("span", `cp-state${available ? "" : " is-error"}`, available ? (item.disposition === "already_enrolled" ? "Already added" : "Ready") : "Unavailable");
      row.append(label, state, provenance(item));
      itemList.appendChild(row);
    });
    previewRegion.appendChild(itemList);

    if ((data.reconciliation.removed || []).length) {
      const archive = el("fieldset", "cp-archive-decisions");
      archive.append(el("legend", "", "Optional archive decisions"), el("p", "", "Modules not included above stay in your workspace unless you explicitly archive them."));
      data.reconciliation.removed.forEach((code) => {
        const label = el("label");
        const input = document.createElement("input");
        input.type = "checkbox";
        input.name = "archive_codes";
        input.value = code;
        label.append(input, document.createTextNode(` Archive ${code}`));
        archive.appendChild(label);
      });
      previewRegion.appendChild(archive);
    }

    const actions = el("footer", "cp-import-review-actions");
    const confirm = el("button", "cp-btn cp-btn-primary", "Import selected modules");
    confirm.type = "button";
    confirm.dataset.commitImport = "";
    const revise = el("button", "cp-btn cp-btn-ghost", "Change import details");
    revise.type = "button";
    revise.dataset.cancelImport = "";
    actions.append(confirm, revise);
    previewRegion.appendChild(actions);
    updateConfirmLabel();
    setStep(1);
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const method = data.get("import_method");
    const year = String(data.get("academic_year") || "").trim();
    const semester = Number(data.get("semester"));
    const consecutive = /^(\d{4})-(\d{4})$/.exec(year);
    if (!consecutive || Number(consecutive[2]) !== Number(consecutive[1]) + 1) {
      setStatus("Choose a valid consecutive academic year.", "error");
      status.focus();
      return;
    }

    const payload = { academic_year: year };
    if (method === "share_url") {
      const value = String(data.get("share_url") || "").trim();
      try {
        const url = new URL(value);
        if (url.protocol !== "https:" || !["nusmods.com", "www.nusmods.com"].includes(url.hostname.toLowerCase()) || !/^\/timetable\/sem-[1-4]\/share\/?$/.test(url.pathname)) throw new Error();
      } catch (_) {
        setStatus("Paste a complete HTTPS NUSMods timetable share URL, or choose module codes.", "error");
        status.focus();
        return;
      }
      payload.share_url = value;
    } else {
      payload.semester = semester;
      const codes = String(data.get("module_codes") || "").toUpperCase().split(/[\s,]+/).filter(Boolean);
      if (!codes.length || codes.length > 30 || codes.some((code) => !/^[A-Z0-9]{2,16}$/.test(code))) {
        setStatus("Enter 1–30 module codes using letters and numbers only.", "error");
        status.focus();
        return;
      }
      payload.module_codes = [...new Set(codes)];
    }

    previewRegion.hidden = true;
    previewRegion.replaceChildren();
    previewRegion.setAttribute("aria-busy", "true");
    setStep(0);
    setBusy(submitButton, true, "Checking NUSMods…");
    setStatus("Contacting NUSMods and validating current module data…", "loading");
    try {
      const preview = await call("import.preview", {}, payload);
      renderPreview(preview);
      setStatus(`${(preview.items || []).length} module${(preview.items || []).length === 1 ? "" : "s"} checked. Review the selection below before importing.`, "success");
      previewRegion.scrollIntoView({ behavior: "smooth", block: "start" });
      previewRegion.querySelector("h3").focus({ preventScroll: true });
    } catch (error) {
      previewRegion.removeAttribute("aria-busy");
      setStatus(error.message, "error");
      status.focus();
    } finally {
      setBusy(submitButton, false, "");
    }
  });

  previewRegion.addEventListener("change", updateConfirmLabel);
  previewRegion.addEventListener("click", async (event) => {
    const cancel = event.target.closest("[data-cancel-import]");
    if (cancel) {
      previewId = null;
      previewRegion.hidden = true;
      previewRegion.replaceChildren();
      setStep(0);
      setStatus("Import review closed. Update the details and try again when ready.");
      form.querySelector("input:not([type=radio]), select").focus();
      return;
    }

    const button = event.target.closest("[data-commit-import]");
    if (!button) return;
    const selected_codes = [...previewRegion.querySelectorAll('input[name="selected_codes"]:checked')].map((input) => input.value);
    const archive_codes = [...previewRegion.querySelectorAll('input[name="archive_codes"]:checked')].map((input) => input.value);
    if (!selected_codes.length && !archive_codes.length) {
      setStatus("Choose at least one available module or an explicit archive decision.", "error");
      status.focus();
      return;
    }
    if (selected_codes.length + archive_codes.length > 30) {
      setStatus("Choose no more than 30 combined imports and archive decisions.", "error");
      status.focus();
      return;
    }

    setBusy(button, true, archive_codes.length ? "Applying confirmed changes…" : "Importing modules…");
    setStatus("Saving your confirmed modules to the workspace…", "loading");
    try {
      const result = await call("import.commit", { preview_id: previewId }, { selected_codes, archive_codes });
      const failures = (result.items || []).filter((item) => ["failed", "unavailable", "not_found"].includes(item.status));
      const outcome = failures.length ? "partial" : "success";
      setStep(2);
      setStatus(failures.length ? "Available modules were saved. Some modules still need attention. Opening your workspace…" : "Modules imported. Opening your updated workspace…", failures.length ? "warning" : "success");
      setTimeout(() => { window.location.assign(`/dashboard?import=${outcome}`); }, 500);
    } catch (error) {
      setStatus(error.message, "error");
      status.focus();
      setBusy(button, false, "");
      updateConfirmLabel();
    }
  });
})();
