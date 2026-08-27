(() => {
  "use strict";

  const root = document.querySelector("[data-topic-manager]");
  if (!root || root.dataset.demo === "true") return;

  const enrollmentId = root.dataset.enrollmentId;
  const reviewButton = root.querySelector("[data-review-topics]");
  const editor = root.querySelector("[data-topic-editor]");

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  function setBusy(button, busy, label) {
    button.disabled = busy;
    button.setAttribute("aria-busy", String(busy));
    if (!button.dataset.label) button.dataset.label = button.textContent;
    button.textContent = busy ? label : button.dataset.label;
  }

  function errorText(response, data) {
    if (response.status === 401) return "Your session expired. Sign in, then retry. Existing topics were not changed.";
    if (response.status === 409) return "The topic map changed in another view. Reload it before saving; nothing was overwritten.";
    const detail = data && (data.detail || data.error);
    if (Array.isArray(detail)) return detail.map((item) => item.msg || "Invalid value").join(" ");
    return typeof detail === "string" ? detail : "The topic service is unavailable. Existing topics were not changed.";
  }

  async function api(action, ids = {}, payload = {}) {
    let response;
    try {
      response = await fetch("/api/curriculum", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify(Object.assign({ action, enrollment_id: enrollmentId, payload }, ids)),
      });
    } catch (_) {
      throw new Error("The topic service could not be reached. Existing topics were not changed.");
    }
    let data = null;
    try { data = await response.json(); } catch (_) {}
    if (!response.ok) throw new Error(errorText(response, data));
    return data;
  }

  function topicRow(topic) {
    const row = el("li", "module-topic-row");
    row.dataset.id = topic.id || "";
    const position = el("span", "module-topic-position", "");
    const input = document.createElement("input");
    input.value = topic.title || "";
    input.maxLength = 300;
    input.required = true;
    input.setAttribute("aria-label", "Topic title");
    const controls = el("div", "module-topic-row-actions");
    const up = el("button", "cp-btn cp-btn-ghost", "Move up");
    up.type = "button";
    up.dataset.move = "up";
    const down = el("button", "cp-btn cp-btn-ghost", "Move down");
    down.type = "button";
    down.dataset.move = "down";
    const archiveLabel = el("label", "module-topic-archive");
    const archived = document.createElement("input");
    archived.type = "checkbox";
    archived.checked = Boolean(topic.archived);
    archived.dataset.archived = "";
    archiveLabel.append(archived, document.createTextNode(" Archived"));
    controls.append(up, down, archiveLabel);
    row.append(position, input, controls);
    if (topic.provenance) row.appendChild(el("small", "", `${topic.state} · ${topic.provenance} · evidence ${topic.source_sha256 || "unavailable"}`));
    return row;
  }

  function refreshPositions(list) {
    [...list.children].forEach((row, index) => {
      const position = index + 1;
      const title = row.querySelector('input[aria-label="Topic title"]').value.trim() || `topic ${position}`;
      const up = row.querySelector('[data-move="up"]');
      const down = row.querySelector('[data-move="down"]');
      const archived = row.querySelector("[data-archived]");
      row.querySelector(".module-topic-position").textContent = String(position).padStart(2, "0");
      up.disabled = index === 0;
      down.disabled = index === list.children.length - 1;
      up.setAttribute("aria-label", `Move ${title} up`);
      down.setAttribute("aria-label", `Move ${title} down`);
      archived.setAttribute("aria-label", `Archive ${title}`);
    });
  }

  function renderTopics(topics, message = "") {
    editor.replaceChildren();
    editor.hidden = false;
    const notice = el("div", "module-topic-notice");
    notice.append(el("strong", "", "Review the complete topic map."), document.createTextNode(" Provisional topics are suggestions until you save this ordered list."));
    editor.appendChild(notice);

    const list = el("ol", "module-topic-list");
    topics.forEach((topic) => list.appendChild(topicRow(topic)));
    editor.appendChild(list);
    refreshPositions(list);

    const actions = el("div", "module-topic-actions");
    const add = el("button", "cp-btn cp-btn-ghost", "Add topic");
    add.type = "button";
    add.dataset.addTopic = "";
    const save = el("button", "cp-btn cp-btn-primary", "Save canonical topic map");
    save.type = "button";
    save.dataset.saveTopics = "";
    actions.append(add, save);
    editor.appendChild(actions);

    const refinement = el("details", "module-topic-refinement");
    const summary = el("summary", "", "Propose topics from a processed syllabus source");
    const body = el("div", "module-topic-refinement-body");
    const sourceLabel = el("label", "cp-field");
    sourceLabel.appendChild(el("span", "", "Ready syllabus source UUID"));
    const source = document.createElement("input");
    source.name = "source_id";
    source.placeholder = "123e4567-e89b-12d3-a456-426614174000";
    sourceLabel.appendChild(source);
    const preview = el("button", "cp-btn cp-btn-ghost", "Preview syllabus proposal");
    preview.type = "button";
    preview.dataset.previewRevision = "";
    body.append(sourceLabel, preview, el("div", "module-revision-preview"));
    refinement.append(summary, body);
    editor.appendChild(refinement);

    const status = el("p", "cp-form-status", message);
    status.setAttribute("role", "status");
    status.tabIndex = -1;
    editor.appendChild(status);
  }

  async function loadTopics() {
    setBusy(reviewButton, true, "Loading topics…");
    editor.hidden = false;
    editor.replaceChildren(el("p", "module-topic-loading", "Loading the current topic map…"));
    try {
      renderTopics(await api("topics.list"));
      reviewButton.textContent = "Reload topics";
      reviewButton.dataset.label = "Reload topics";
    } catch (error) {
      editor.replaceChildren(el("div", "cp-inline-error", error.message));
    } finally {
      setBusy(reviewButton, false, "");
    }
  }

  reviewButton.addEventListener("click", loadTopics);
  editor.addEventListener("input", (event) => {
    if (event.target.matches('input[aria-label="Topic title"]')) refreshPositions(editor.querySelector(".module-topic-list"));
  });

  editor.addEventListener("click", async (event) => {
    const list = editor.querySelector(".module-topic-list");
    const status = editor.querySelector(".cp-form-status");
    const row = event.target.closest(".module-topic-row");

    if (event.target.closest("[data-add-topic]")) {
      const added = topicRow({ title: "", archived: false });
      list.appendChild(added);
      refreshPositions(list);
      added.querySelector('input[aria-label="Topic title"]').focus();
      return;
    }

    const move = event.target.closest("[data-move]");
    if (row && move) {
      const sibling = move.dataset.move === "up" ? row.previousElementSibling : row.nextElementSibling;
      if (sibling) list.insertBefore(move.dataset.move === "up" ? row : sibling, move.dataset.move === "up" ? sibling : row);
      refreshPositions(list);
      move.focus();
      return;
    }

    const save = event.target.closest("[data-save-topics]");
    if (save) {
      const topics = [...list.children].map((item) => ({
        id: item.dataset.id || null,
        title: item.querySelector('input[aria-label="Topic title"]').value.trim(),
        archived: item.querySelector("[data-archived]").checked,
      }));
      if (!topics.length || topics.some((topic) => !topic.title)) {
        status.textContent = "Every topic needs a title. Archive a topic instead of leaving it blank.";
        status.focus();
        return;
      }
      setBusy(save, true, "Saving topic map…");
      try {
        renderTopics(await api("topics.save", {}, { topics }), "Canonical topic map saved with stable topic identities.");
        editor.querySelector(".cp-form-status").focus();
      } catch (error) {
        status.textContent = error.message;
        status.focus();
        setBusy(save, false, "");
      }
      return;
    }

    const proposal = event.target.closest("[data-preview-revision]");
    if (proposal) {
      const sourceId = editor.querySelector('[name="source_id"]').value.trim();
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(sourceId)) {
        status.textContent = "Enter the UUID of a source that has finished processing.";
        status.focus();
        return;
      }
      setBusy(proposal, true, "Building proposal…");
      try {
        const revision = await api("revision.preview", {}, { source_id: sourceId });
        const box = editor.querySelector(".module-revision-preview");
        box.replaceChildren(el("p", "", `Revision ${revision.id} · ${revision.algorithm} · not applied`));
        const diff = el("pre", "", JSON.stringify({ before: revision.base_topics, proposed: revision.proposed_topics, mapping: revision.mapping }, null, 2));
        diff.tabIndex = 0;
        box.appendChild(diff);
        ["accept", "reject"].forEach((decision) => {
          const button = el("button", `cp-btn ${decision === "accept" ? "cp-btn-primary" : "cp-btn-ghost"}`, decision === "accept" ? "Accept proposal" : "Reject proposal");
          button.type = "button";
          button.dataset.revisionDecision = decision;
          button.dataset.revisionId = revision.id;
          box.appendChild(button);
        });
        status.textContent = "Proposal ready. Your canonical topic map has not changed.";
      } catch (error) {
        status.textContent = error.message;
        status.focus();
      } finally {
        setBusy(proposal, false, "");
      }
      return;
    }

    const decision = event.target.closest("[data-revision-decision]");
    if (decision) {
      setBusy(decision, true, "Saving decision…");
      try {
        const revision = await api("revision.decide", { revision_id: decision.dataset.revisionId }, { decision: decision.dataset.revisionDecision });
        editor.querySelector(".module-revision-preview").replaceChildren(el("p", "", `Revision ${revision.status}.`));
        status.textContent = revision.status === "accepted" ? "Proposal accepted. Reload topics to review the updated canonical map." : "Proposal rejected. The canonical topic map was not changed.";
      } catch (error) {
        status.textContent = error.message;
        status.focus();
        setBusy(decision, false, "");
      }
    }
  });
})();
