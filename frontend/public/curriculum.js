(() => {
  "use strict";
  const form = document.querySelector("[data-module-import]");
  if (!form || form.querySelector("fieldset:disabled")) return;
  const endpoint = "/api/curriculum";
  const previewRegion = document.querySelector("[data-import-preview]");
  const status = form.querySelector(".cp-form-status");
  let previewId = null;

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const errorText = (response, data, fallback) => {
    if (response.status === 401) return "Your session expired. Sign in, then retry; no existing enrollment was deleted.";
    if (response.status === 409) return "This revision is stale or conflicts with a newer change. Reload topics before deciding. Nothing was overwritten.";
    const detail = data && (data.detail || data.error);
    if (Array.isArray(detail)) return detail.map((item) => item.msg || "Invalid value").join(" ");
    return typeof detail === "string" ? detail : fallback;
  };
  async function call(action, ids, payload) {
    const response = await fetch(endpoint, {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify(Object.assign({ action, payload: payload || {} }, ids || {})),
    });
    let data = null;
    try { data = await response.json(); } catch (_) {}
    if (!response.ok) throw new Error(errorText(response, data, "The provider or network request failed. Retry; no existing enrollment was deleted."));
    return data;
  }
  function setBusy(button, busy, label) {
    button.disabled = busy;
    if (!button.dataset.label) button.dataset.label = button.textContent;
    button.textContent = busy ? label : button.dataset.label;
  }

  form.addEventListener("change", (event) => {
    if (event.target.name !== "import_method") return;
    const manual = event.target.value === "manual_codes";
    form.querySelector("[data-share-field]").hidden = manual;
    form.querySelector("[data-codes-field]").hidden = !manual;
  });

  function provenance(item) {
    const details = el("details", "cp-provenance");
    details.appendChild(el("summary", "", "Exact provider snapshot"));
    const list = el("dl");
    [["Version", item.provider_version], ["Fetched", item.fetched_at], ["Payload SHA-256", item.payload_sha256], ["Source URL", item.source_url]].forEach(([key, value]) => {
      const row = el("div"); row.append(el("dt", "", key), el("dd", "", value || "Unavailable")); list.appendChild(row);
    });
    details.appendChild(list); return details;
  }
  function renderPreview(data) {
    previewId = data.id;
    previewRegion.replaceChildren(); previewRegion.hidden = false;
    const header = el("header");
    header.append(el("div", "", `${data.academic_year} · Semester ${data.semester} · ${data.import_method.replaceAll("_", " ")}`), el("strong", "", "Review before confirmation"));
    previewRegion.appendChild(header);
    const reconciliation = el("div", "cp-reconciliation");
    ["added", "unchanged", "removed", "ambiguous"].forEach((kind) => {
      const group = el("div"); group.append(el("strong", "", kind[0].toUpperCase() + kind.slice(1)), el("span", "", (data.reconciliation[kind] || []).join(", ") || "None")); reconciliation.appendChild(group);
    });
    previewRegion.appendChild(reconciliation);
    const itemList = el("div", "cp-preview-list");
    (data.items || []).forEach((item) => {
      const card = el("article", "cp-preview-card");
      const available = item.available && !["unavailable", "not_found"].includes(item.disposition);
      const label = el("label");
      const checkbox = document.createElement("input"); checkbox.type = "checkbox"; checkbox.name = "selected_codes"; checkbox.value = item.code; checkbox.checked = available && item.disposition !== "already_enrolled"; checkbox.disabled = !available;
      label.append(checkbox, el("span", "", `${item.code} — ${item.title}`));
      const badge = el("span", `cp-state ${available ? "" : "is-error"}`, `${item.available ? "Available" : "Unavailable"} · ${item.disposition.replaceAll("_", " ")}`);
      card.append(label, badge, provenance(item)); itemList.appendChild(card);
    });
    previewRegion.appendChild(itemList);
    if ((data.reconciliation.removed || []).length) {
      const archive = el("fieldset", "cp-archive-decisions"); archive.appendChild(el("legend", "", "Explicit archive decisions"));
      archive.appendChild(el("p", "", "Unselected modules stay enrolled. Check only modules you intend to archive."));
      data.reconciliation.removed.forEach((code) => {
        const label = el("label"); const input = document.createElement("input"); input.type = "checkbox"; input.name = "archive_codes"; input.value = code; label.append(input, document.createTextNode(` Archive ${code}`)); archive.appendChild(label);
      });
      previewRegion.appendChild(archive);
    }
    const confirm = el("button", "cp-btn cp-btn-primary", "Confirm selected decisions"); confirm.type = "button"; confirm.dataset.commitImport = ""; previewRegion.appendChild(confirm);
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = form.querySelector('button[type="submit"]');
    const data = new FormData(form); const method = data.get("import_method");
    const year = String(data.get("academic_year") || "").trim(); const semester = Number(data.get("semester"));
    const consecutive = /^(\d{4})-(\d{4})$/.exec(year);
    if (!consecutive || Number(consecutive[2]) !== Number(consecutive[1]) + 1) { status.textContent = "Enter consecutive years in YYYY-YYYY form, such as 2025-2026."; status.focus(); return; }
    let payload = { academic_year: year, semester };
    if (method === "share_url") {
      const value = String(data.get("share_url") || "").trim();
      try { const url = new URL(value); if (url.protocol !== "https:" || !["nusmods.com", "www.nusmods.com"].includes(url.hostname.toLowerCase()) || !/^\/timetable\/sem-[1-4]\/share\/?$/.test(url.pathname)) throw new Error(); } catch (_) { status.textContent = "Enter a supported HTTPS nusmods.com timetable share URL, or choose manual module codes."; status.focus(); return; }
      payload.share_url = value;
    } else {
      const codes = String(data.get("module_codes") || "").toUpperCase().split(/[\s,]+/).filter(Boolean);
      if (!codes.length || codes.length > 30 || codes.some((code) => !/^[A-Z0-9]{2,16}$/.test(code))) { status.textContent = "Enter 1–30 alphanumeric module codes, each 2–16 characters."; status.focus(); return; }
      payload.module_codes = [...new Set(codes)];
    }
    setBusy(button, true, "Validating with NUSMods…"); status.textContent = "Loading a provider snapshot…";
    try { renderPreview(await call("import.preview", {}, payload)); status.textContent = "Preview ready. Review availability, selection, and archive decisions."; previewRegion.scrollIntoView({ behavior: "smooth", block: "start" }); }
    catch (error) { status.textContent = error.message; status.focus(); }
    finally { setBusy(button, false, ""); }
  });

  previewRegion.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-commit-import]"); if (!button) return;
    const selected_codes = [...previewRegion.querySelectorAll('input[name="selected_codes"]:checked')].map((input) => input.value);
    const archive_codes = [...previewRegion.querySelectorAll('input[name="archive_codes"]:checked')].map((input) => input.value);
    setBusy(button, true, "Confirming…");
    try {
      const result = await call("import.commit", { preview_id: previewId }, { selected_codes, archive_codes });
      const failures = (result.items || []).filter((item) => ["failed", "unavailable", "not_found"].includes(item.status));
      status.textContent = failures.length ? "Some modules were not changed. Existing enrollments were not deleted by these failures. Reloading your local enrollments…" : "Import confirmed. Reloading your local enrollments…";
      setTimeout(() => window.location.reload(), 600);
    } catch (error) { status.textContent = `${error.message} Existing enrollments remain unchanged unless an archive decision was confirmed.`; status.focus(); setBusy(button, false, ""); }
  });

  function topicRow(topic) {
    const row = el("li", "cp-topic-row"); row.dataset.id = topic.id || "";
    const input = document.createElement("input"); input.value = topic.title || ""; input.maxLength = 300; input.required = true; input.setAttribute("aria-label", "Topic title");
    const up = el("button", "cp-btn cp-btn-ghost", "Move up"); up.type = "button"; up.dataset.move = "up";
    const down = el("button", "cp-btn cp-btn-ghost", "Move down"); down.type = "button"; down.dataset.move = "down";
    const archiveLabel = el("label"); const archived = document.createElement("input"); archived.type = "checkbox"; archived.checked = Boolean(topic.archived); archived.dataset.archived = ""; archiveLabel.append(archived, document.createTextNode(" Archived"));
    row.append(input, up, down, archiveLabel);
    if (topic.provenance) row.appendChild(el("small", "", `${topic.state} · ${topic.provenance} · evidence ${topic.source_sha256 || "unavailable"}`));
    return row;
  }
  function renderTopics(region, topics) {
    region.replaceChildren(); region.hidden = false;
    region.append(el("div", "cp-provisional-warning", "Provisional topics are suggestions, not verified syllabus truth. Review the complete list before saving canonical topics."));
    const list = el("ol", "cp-topic-list"); topics.forEach((topic) => list.appendChild(topicRow(topic))); region.appendChild(list);
    const actions = el("div", "cp-topic-actions");
    const add = el("button", "cp-btn cp-btn-ghost", "Add topic"); add.type = "button"; add.dataset.addTopic = "";
    const save = el("button", "cp-btn cp-btn-primary", "Save complete topic list"); save.type = "button"; save.dataset.saveTopics = "";
    actions.append(add, save); region.appendChild(actions);
    const refine = el("div", "cp-refinement"); refine.appendChild(el("h4", "", "Refine from a READY syllabus source"));
    const sourceLabel = el("label", "cp-field"); sourceLabel.appendChild(el("span", "", "User-owned READY source UUID")); const source = document.createElement("input"); source.name = "source_id"; source.placeholder = "123e4567-e89b-12d3-a456-426614174000"; sourceLabel.appendChild(source); refine.appendChild(sourceLabel);
    const preview = el("button", "cp-btn cp-btn-ghost", "Preview syllabus proposal"); preview.type = "button"; preview.dataset.previewRevision = ""; refine.appendChild(preview); refine.appendChild(el("div", "cp-revision-preview")); region.appendChild(refine);
    region.appendChild(el("p", "cp-form-status", "")); region.lastChild.setAttribute("role", "status"); region.lastChild.tabIndex = -1;
  }

  document.addEventListener("click", async (event) => {
    const review = event.target.closest("[data-review-topics]");
    if (review) {
      const card = review.closest("[data-enrollment-id]"); const region = card.querySelector("[data-topic-review]"); setBusy(review, true, "Loading topics…");
      try { renderTopics(region, await call("topics.list", { enrollment_id: card.dataset.enrollmentId })); review.textContent = "Topics loaded"; }
      catch (error) { region.hidden = false; region.textContent = error.message; setBusy(review, false, ""); }
      return;
    }
    const region = event.target.closest("[data-topic-review]"); if (!region) return;
    const list = region.querySelector(".cp-topic-list"); const row = event.target.closest(".cp-topic-row");
    if (event.target.closest("[data-add-topic]")) { const added = topicRow({ title: "", archived: false }); list.appendChild(added); added.querySelector("input").focus(); return; }
    if (row && event.target.closest("[data-move]")) {
      const direction = event.target.closest("[data-move]").dataset.move; const sibling = direction === "up" ? row.previousElementSibling : row.nextElementSibling;
      if (sibling) list.insertBefore(direction === "up" ? row : sibling, direction === "up" ? sibling : row); event.target.focus(); return;
    }
    const card = region.closest("[data-enrollment-id]"); const regionStatus = region.querySelector(".cp-form-status");
    if (event.target.closest("[data-save-topics]")) {
      const button = event.target.closest("[data-save-topics]"); const topics = [...list.children].map((item) => ({ id: item.dataset.id || null, title: item.querySelector('input[aria-label="Topic title"]').value.trim(), archived: item.querySelector("[data-archived]").checked }));
      if (!topics.length || topics.some((topic) => !topic.title)) { regionStatus.textContent = "Every topic needs a title; archive a topic rather than submitting a blank title."; regionStatus.focus(); return; }
      setBusy(button, true, "Saving…"); try { renderTopics(region, await call("topics.save", { enrollment_id: card.dataset.enrollmentId }, { topics })); region.querySelector(".cp-form-status").textContent = "Canonical topic list saved with stable topic IDs."; } catch (error) { regionStatus.textContent = error.message; regionStatus.focus(); setBusy(button, false, ""); } return;
    }
    if (event.target.closest("[data-preview-revision]")) {
      const button = event.target.closest("[data-preview-revision]"); const sourceId = region.querySelector('[name="source_id"]').value.trim();
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(sourceId)) { regionStatus.textContent = "Enter the UUID of a user-owned source whose status is READY."; regionStatus.focus(); return; }
      setBusy(button, true, "Building deterministic proposal…");
      try {
        const revision = await call("revision.preview", { enrollment_id: card.dataset.enrollmentId }, { source_id: sourceId }); const box = region.querySelector(".cp-revision-preview"); box.replaceChildren();
        box.append(el("p", "", `Revision ${revision.id} · ${revision.algorithm} · pending`)); const diff = el("pre", "", JSON.stringify({ before: revision.base_topics, proposed: revision.proposed_topics, mapping: revision.mapping }, null, 2)); diff.tabIndex = 0; box.appendChild(diff);
        ["accept", "reject"].forEach((decision) => { const decisionButton = el("button", `cp-btn ${decision === "accept" ? "cp-btn-primary" : "cp-btn-ghost"}`, decision === "accept" ? "Accept proposal" : "Reject proposal"); decisionButton.type = "button"; decisionButton.dataset.revisionDecision = decision; decisionButton.dataset.revisionId = revision.id; box.appendChild(decisionButton); });
        regionStatus.textContent = "Proposal ready. It has not changed your canonical topics.";
      } catch (error) { regionStatus.textContent = error.message; regionStatus.focus(); } finally { setBusy(button, false, ""); } return;
    }
    const decisionButton = event.target.closest("[data-revision-decision]");
    if (decisionButton) {
      setBusy(decisionButton, true, "Saving decision…"); try { const revision = await call("revision.decide", { enrollment_id: card.dataset.enrollmentId, revision_id: decisionButton.dataset.revisionId }, { decision: decisionButton.dataset.revisionDecision }); region.querySelector(".cp-revision-preview").replaceChildren(el("p", "", `Revision ${revision.status}.`)); regionStatus.textContent = revision.status === "accepted" ? "Proposal accepted explicitly. Reload topics to review the canonical list." : "Proposal rejected. Canonical topics were not changed."; } catch (error) { regionStatus.textContent = error.message; regionStatus.focus(); setBusy(decisionButton, false, ""); }
    }
  });
})();
