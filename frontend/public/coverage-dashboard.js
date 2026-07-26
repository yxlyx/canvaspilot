(function () {
  "use strict";
  const root = document.querySelector("[data-coverage-dashboard]");
  if (!root) return;
  const enrollmentId = root.dataset.enrollmentId;
  const demo = root.dataset.demo === "true";
  const table = root.querySelector("[data-topic-table]");
  const candidatesNode = root.querySelector("[data-candidate-list]");
  const statusNode = root.querySelector("[data-coverage-status]");
  const warningNode = root.querySelector("[data-coverage-warning]");
  const metricNode = root.querySelector("[data-coverage-metric]");
  const percentageNode = root.querySelector("[data-coverage-percentage]");
  const recompute = root.querySelector("[data-recompute]");
  const manualForm = root.querySelector("[data-manual-association]");
  const evidenceNode = manualForm.querySelector("[data-evidence-options]");
  const manualButton = manualForm.querySelector('button[type="submit"]');
  const recallPanel = root.querySelector("[data-recall-panel]");
  const recallNode = root.querySelector("[data-recall-content]");
  const activityPanel = root.querySelector("[data-activity-panel]");
  const activityNode = root.querySelector("[data-activity-content]");
  const methodologyNode = root.querySelector("[data-methodology-content]");
  let dashboard = null;
  let candidates = [];
  let candidateReady = false;
  let chunkRequest = 0;

  const fixture = {
    enrollment_id: enrollmentId, disclosure: "source_coverage_not_mastery", numerator: 1, denominator: 3, percentage: 33.33, provisional: false, warning: null,
    topics: [
      { topic_id: "223e4567-e89b-12d3-a456-426614174000", position: 0, title: "Balanced search trees", state: "covered", reason_codes: [], guidance: { recommended_source_kinds: ["pdf", "markdown"], source_intake_url: "/sources/intake?enrollment_id=" + enrollmentId + "&topic_id=223e4567-e89b-12d3-a456-426614174000&mock=1" }, confirmed_sources: [{ id: "423e4567-e89b-12d3-a456-426614174000", source_id: "323e4567-e89b-12d3-a456-426614174000", source_title: "Synthetic lecture notes", source_status: "ready", status: "confirmed", method: "deterministic", evidence_strength: 1, reason_code: "user_confirmed", stale: false, stale_reason: null, evidence: [{ chunk_id: "523e4567-e89b-12d3-a456-426614174000", citation: "Synthetic notes §2", location: "page 4", excerpt: "Balanced search trees maintain a bounded height." }] }], proposed_sources: [] },
      { topic_id: "623e4567-e89b-12d3-a456-426614174000", position: 1, title: "Graph traversal", state: "review", reason_codes: ["proposal_requires_review"], guidance: { recommended_source_kinds: ["pdf"], source_intake_url: "/sources/intake?enrollment_id=" + enrollmentId + "&topic_id=623e4567-e89b-12d3-a456-426614174000&mock=1" }, confirmed_sources: [], proposed_sources: [{ id: "723e4567-e89b-12d3-a456-426614174000", source_id: "323e4567-e89b-12d3-a456-426614174000", source_title: "Synthetic lecture notes", source_status: "ready", status: "proposed", method: "deterministic", evidence_strength: 0.75, reason_code: "meaningful_title_overlap", stale: false, stale_reason: null, evidence: [{ chunk_id: "823e4567-e89b-12d3-a456-426614174000", citation: "Synthetic notes §5", location: "page 11", excerpt: "Graph traversal uses a frontier to visit vertices." }] }] },
      { topic_id: "923e4567-e89b-12d3-a456-426614174000", position: 2, title: "Dynamic programming", state: "missing", reason_codes: ["no_matching_evidence"], guidance: { recommended_source_kinds: ["pdf", "markdown", "plain_text"], source_intake_url: "/sources/intake?enrollment_id=" + enrollmentId + "&topic_id=923e4567-e89b-12d3-a456-426614174000&mock=1" }, confirmed_sources: [], proposed_sources: [] }
    ]
  };
  const metricsFixture = {
    enrollment_id: enrollmentId,
    source_coverage: { authoritative: true, numerator: 1, denominator: 3, percentage: 33.33, reason_code: null, warning: null, covered_topics: [{ topic_id: fixture.topics[0].topic_id, position: 0, title: fixture.topics[0].title, state: "covered", reason_codes: [], evidence_links: fixture.topics[0].confirmed_sources.map(function (item) { return { association_id: item.id, source_id: item.source_id, source_title: item.source_title, status: item.status, stale: item.stale, stale_reason: item.stale_reason, evidence: item.evidence }; }) }], review_topics: [{ topic_id: fixture.topics[1].topic_id, position: 1, title: fixture.topics[1].title, state: "review", reason_codes: fixture.topics[1].reason_codes, evidence_links: fixture.topics[1].proposed_sources.map(function (item) { return { association_id: item.id, source_id: item.source_id, source_title: item.source_title, status: item.status, stale: item.stale, stale_reason: item.stale_reason, evidence: item.evidence }; }) }], missing_topics: [{ topic_id: fixture.topics[2].topic_id, position: 2, title: fixture.topics[2].title, state: "missing", reason_codes: fixture.topics[2].reason_codes, evidence_links: [] }], stale_topics: [] },
    recall: { correct_attempts: 4, attempt_count: 6, percentage: 66.67, last_evidence_at: "2025-07-24T12:00:00Z", reason_code: null, warning: null, topics: [{ topic_id: fixture.topics[0].topic_id, position: 0, title: fixture.topics[0].title, correct_attempts: 3, attempt_count: 4, percentage: 75, last_evidence_at: "2025-07-24T12:00:00Z", reason_code: null, warning: null }, { topic_id: fixture.topics[1].topic_id, position: 1, title: fixture.topics[1].title, correct_attempts: 1, attempt_count: 2, percentage: null, last_evidence_at: "2025-07-20T12:00:00Z", reason_code: "insufficient_attempts", warning: "At least 3 recent attempts are required for a recall percentage." }, { topic_id: fixture.topics[2].topic_id, position: 2, title: fixture.topics[2].title, correct_attempts: 0, attempt_count: 0, percentage: null, last_evidence_at: null, reason_code: "no_attempts", warning: "No approved-card recall evidence is available." }] },
    activity: { attempt_count: 7, cards_reviewed: 4, session_count: null, source_uploads: 2, source_changes: 1 },
    methodology: { coverage_formula: "non-stale confirmed topics / displayed active topics; proposals never count", recall_formula: "unique correct approved-card attempts / unique approved-card attempts in the rolling UTC window; overall is weighted by attempts", activity_formula: "independent event counts in the same rolling UTC window", window_start: "2025-06-25T12:00:00Z", window_end: "2025-07-25T12:00:00Z", rolling_window_days: 30, minimum_attempts_per_topic: 3, minimum_attempts_overall: 5, freshness_cutoff: "2025-06-25T12:00:00Z", rating_semantics: { Again: false, Hard: true, Good: true, Easy: true }, exclusions: ["draft and unapproved-card attempts", "stale and proposed source evidence"], disclosures: ["source_coverage_not_mastery", "self_reported_recall_not_mastery"] }
  };
  const fixtureCandidates = [{ id: "323e4567-e89b-12d3-a456-426614174000", title: "Synthetic lecture notes", source_type: "pdf", state: "ready", import_error: null, attachment: "enrollment", eligible: true }];
  const fixtureChunks = [{ chunk_id: "523e4567-e89b-12d3-a456-426614174000", citation: "Synthetic notes §2", location: "page 4", excerpt: "Balanced search trees maintain a bounded height.", relevance: 1, rank: 1 }];
  const reasonText = {
    proposal_requires_review: "A possible source match needs your review before it can count.", meaningful_title_overlap: "The topic title meaningfully overlaps this cited source excerpt.", user_confirmed: "You confirmed this source evidence.", manual_source_review: "You explicitly selected and confirmed this source evidence.", no_attached_sources: "No sources are attached to this module.", no_matching_evidence: "Attached sources do not contain matching evidence for this topic.", source_processing: "A source is still being processed; it cannot count yet.", source_failed: "A source failed to process and cannot count.", source_archived: "The supporting source was archived.", source_missing: "The supporting source is no longer available.", source_not_owned: "The supporting source is no longer in your workspace.", source_scope_changed: "The source is attached to a different module and was not reassigned.", source_chunks_changed: "The source content changed; recompute and review the evidence again.", stored_evidence_changed: "The cited excerpt changed; recompute and review it again.", topic_revised: "The curriculum topic changed; recompute and review the evidence again.", proposal_rule_changed: "The matching rule changed; recompute and review the evidence again.", evidence_no_longer_matches: "The source no longer matches this topic.", scope_or_archive_changed: "The source or topic scope changed.", association_stale: "This evidence is out of date.", enrollment_archived: "This module enrollment is archived.", topic_archived_or_missing: "This topic is archived or unavailable."
  };

  function el(name, className, text) {
    const node = document.createElement(name);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function setStatus(message, error, retry) {
    statusNode.replaceChildren(document.createTextNode(message));
    if (retry) {
      const button = el("button", "cp-btn cp-btn-ghost", "Retry refresh");
      button.type = "button";
      button.addEventListener("click", retry);
      statusNode.append(" ", button);
    }
    statusNode.classList.toggle("is-error", Boolean(error));
    if (error) statusNode.focus();
  }
  function errorMessage(status, body) {
    if (status === 401) return "Your session has expired. Sign in and try again.";
    if (status === 403) return "This action is not permitted for your account.";
    if (status === 404) return "This module or evidence is no longer available.";
    if (status === 409) return (body && (body.message || body.detail)) || "The evidence changed. Reload before trying again.";
    if (status === 400 || status === 422) return (body && (body.message || body.detail)) || "Review the selected evidence and try again.";
    return "The coverage service is unavailable. Your existing decisions were not changed.";
  }
  async function api(action, options) {
    const payload = Object.assign({ action, enrollment_id: enrollmentId }, options || {});
    const response = await fetch("/api/curriculum", { method: "POST", headers: { Accept: "application/json", "Content-Type": "application/json" }, credentials: "same-origin", body: JSON.stringify(payload) });
    let body = null;
    try { body = await response.json(); } catch (_) {}
    if (!response.ok) { const error = new Error(errorMessage(response.status, body)); error.status = response.status; throw error; }
    return body;
  }
  function evidenceCard(association, proposed) {
    const card = el("article", "coverage-evidence" + (association.stale ? " is-stale" : ""));
    card.appendChild(el("h4", "", association.source_title || "Untitled source"));
    card.appendChild(el("p", "coverage-evidence-meta", "Source status: " + String(association.source_status || "unknown") + " · Evidence strength: " + String(association.evidence_strength) + " · Method: " + String(association.method)));
    if (association.stale) card.appendChild(el("p", "coverage-stale", "Stale evidence: " + (reasonText[association.stale_reason] || String(association.stale_reason || "review required"))));
    (association.evidence || []).forEach(function (item) {
      const quote = el("blockquote", "coverage-excerpt");
      quote.append(el("p", "", item.excerpt), el("cite", "", item.citation + (item.location ? " · " + item.location : "")));
      card.appendChild(quote);
    });
    card.appendChild(el("p", "coverage-reason", reasonText[association.reason_code] || String(association.reason_code || "Evidence recorded")));
    if (!demo && proposed) {
      const controls = el("div", "coverage-review-controls");
      const confirmButton = el("button", "cp-btn cp-btn-primary", "Confirm evidence");
      confirmButton.type = "button"; confirmButton.disabled = Boolean(association.stale);
      confirmButton.addEventListener("click", function () { mutate("association.decide", { association_id: association.id, payload: { decision: "confirm" } }, "Confirming proposal…", "Evidence confirmed.", confirmButton); });
      const rejectButton = el("button", "cp-btn cp-btn-ghost", "Reject proposal");
      rejectButton.type = "button";
      rejectButton.addEventListener("click", function () { mutate("association.decide", { association_id: association.id, payload: { decision: "reject" } }, "Rejecting proposal…", "Proposal rejected.", rejectButton); });
      controls.append(confirmButton, rejectButton); card.appendChild(controls);
    } else if (!demo && !proposed) {
      const remove = el("button", "cp-btn cp-btn-ghost", "Remove confirmed evidence"); remove.type = "button";
      remove.addEventListener("click", function () {
        if (window.confirm("Remove confirmed evidence from “" + association.source_title + "”? The topic may become missing.")) mutate("association.remove", { association_id: association.id }, "Removing confirmed evidence…", "Confirmed evidence removed.", remove);
      });
      card.appendChild(remove);
    }
    return card;
  }
  function metricReason(metric) {
    if (metric.warning) return metric.warning;
    const labels = { no_attempts: "No evidence", insufficient_attempts: "Insufficient evidence", stale_attempts: "Stale evidence", enrollment_archived: "Enrollment archived", provisional_curriculum: "Curriculum is provisional", no_topics: "No canonical topics" };
    return labels[metric.reason_code] || (metric.reason_code ? String(metric.reason_code).replaceAll("_", " ") : "Percentage unavailable");
  }
  function utc(value) {
    if (!value) return "No evidence";
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? String(value) : date.toISOString().replace(".000Z", "Z") + " (UTC)";
  }
  function renderMetricSource(source) {
    metricNode.textContent = Number.isInteger(source.numerator) && Number.isInteger(source.denominator) ? source.numerator + " / " + source.denominator + " topics" : source.denominator === null ? "Denominator unavailable" : "Unavailable";
    percentageNode.textContent = source.authoritative && typeof source.percentage === "number" ? source.percentage + "%" : "";
    const warning = source.warning || (!source.authoritative ? "The curriculum denominator is provisional; no authoritative source-coverage percentage is shown." : source.denominator === 0 ? "No active canonical topics are available; no source-coverage percentage is shown." : "");
    warningNode.hidden = !warning; warningNode.textContent = warning;
    const topics = [].concat(source.covered_topics || [], source.missing_topics || [], source.review_topics || [], source.stale_topics || []).sort(function (a, b) { return a.position - b.position || String(a.topic_id).localeCompare(String(b.topic_id)); });
    const list = el("ol", "coverage-topic-list");
    topics.forEach(function (topic) {
      const item = el("li", "coverage-topic-row state-" + topic.state);
      const header = el("header", "coverage-topic-header");
      const identity = el("div"); identity.append(el("span", "coverage-position", "Topic " + (topic.position + 1)), el("h3", "", topic.title));
      const states = { covered: "Covered by confirmed evidence", missing: "Missing source evidence", review: "Review proposed evidence", stale: "Stale evidence" };
      header.append(identity, el("strong", "coverage-state", states[topic.state] || topic.state)); item.appendChild(header);
      (topic.reason_codes || []).forEach(function (reason) { item.appendChild(el("p", "coverage-reason", reasonText[reason] || String(reason).replaceAll("_", " "))); });
      (topic.evidence_links || []).forEach(function (link) {
        const card = el("article", "coverage-evidence" + (link.stale ? " is-stale" : ""));
        const title = el("h4"); const sourceLink = el("a", "", link.source_title || "Untitled source"); sourceLink.href = "/sources?source=" + encodeURIComponent(link.source_id); title.appendChild(sourceLink); card.appendChild(title);
        card.appendChild(el("p", "coverage-evidence-meta", "Association: " + String(link.status) + (link.stale ? " · Stale" : " · Current")));
        if (link.stale) card.appendChild(el("p", "coverage-stale", "Stale evidence: " + (reasonText[link.stale_reason] || String(link.stale_reason || "review required"))));
        (link.evidence || []).forEach(function (evidence) { const quote = el("blockquote", "coverage-excerpt"); quote.append(el("p", "", evidence.excerpt), el("cite", "", evidence.citation + (evidence.location ? " · " + evidence.location : ""))); card.appendChild(quote); });
        item.appendChild(card);
      });
      list.appendChild(item);
    });
    if (!topics.length) list.appendChild(el("li", "coverage-topic-row", "No active topics are returned for this enrollment."));
    table.replaceChildren(list); table.setAttribute("aria-busy", "false");
  }
  function renderRecall(recall, methodology) {
    const summary = el("div", "learning-metric-summary");
    summary.append(el("strong", "", recall.correct_attempts + " correct / " + recall.attempt_count + " attempts"));
    summary.appendChild(typeof recall.percentage === "number" ? el("span", "learning-metric-value", recall.percentage + "% weighted overall") : el("span", "learning-metric-unavailable", metricReason(recall) + " — no percentage"));
    summary.appendChild(el("span", "", "Last evidence: " + utc(recall.last_evidence_at)));
    const list = el("ol", "recall-topic-list");
    (recall.topics || []).forEach(function (topic) {
      const item = el("li", "recall-topic-row");
      item.append(el("h3", "", topic.title), el("span", "", topic.correct_attempts + " correct / " + topic.attempt_count + " attempts"));
      item.appendChild(typeof topic.percentage === "number" ? el("strong", "", topic.percentage + "%") : el("strong", "learning-metric-unavailable", metricReason(topic) + " — no percentage"));
      item.appendChild(el("span", "", "Last evidence: " + utc(topic.last_evidence_at))); list.appendChild(item);
    });
    recallNode.replaceChildren(el("p", "coverage-reason", methodology.rolling_window_days + "-day rolling UTC window; overall is weighted by confirmed attempts."), summary, list);
    recallPanel.setAttribute("aria-busy", "false");
  }
  function renderActivity(activity, methodology) {
    const facts = el("dl", "activity-facts");
    [["Attempts", activity.attempt_count], ["Distinct cards reviewed", activity.cards_reviewed], ["Persisted sessions", activity.session_count], ["Sources uploaded", activity.source_uploads], ["Source changes", activity.source_changes]].forEach(function (fact) {
      const row = el("div"); row.append(el("dt", "", fact[0]), el("dd", "", fact[1] === null || fact[1] === undefined ? (fact[0] === "Persisted sessions" ? "Not persisted" : "Not returned by API") : String(fact[1]))); facts.appendChild(row);
    });
    activityNode.replaceChildren(el("p", "coverage-reason", utc(methodology.window_start) + " to " + utc(methodology.window_end)), facts);
    activityPanel.setAttribute("aria-busy", "false");
  }
  function renderMethodology(methodology) {
    const box = el("div", "methodology-grid");
    [["Source coverage formula", methodology.coverage_formula], ["Recall formula", methodology.recall_formula], ["Activity formula", methodology.activity_formula], ["UTC window", utc(methodology.window_start) + " to " + utc(methodology.window_end)], ["Recall thresholds", methodology.minimum_attempts_per_topic + " attempts per topic; " + methodology.minimum_attempts_overall + " attempts overall"], ["Freshness cutoff", utc(methodology.freshness_cutoff)]].forEach(function (fact) { const row = el("div"); row.append(el("dt", "", fact[0]), el("dd", "", String(fact[1]))); box.appendChild(row); });
    const ratings = el("ul"); Object.keys(methodology.rating_semantics || {}).forEach(function (rating) { ratings.appendChild(el("li", "", rating + ": " + (methodology.rating_semantics[rating] ? "recalled" : "not recalled"))); });
    const exclusions = el("ul"); (methodology.exclusions || []).forEach(function (item) { exclusions.appendChild(el("li", "", item)); });
    const ratingSection = el("section"); ratingSection.append(el("h3", "", "Persisted rating semantics"), ratings);
    const exclusionSection = el("section"); exclusionSection.append(el("h3", "", "Freshness and exclusions"), exclusions);
    methodologyNode.replaceChildren(box, ratingSection, exclusionSection);
  }
  function renderMetrics(data) {
    renderRecall(data.recall, data.methodology);
    renderActivity(data.activity, data.methodology);
    renderMethodology(data.methodology);
  }
  function metricsError(error) {
    recallPanel.setAttribute("aria-busy", "false"); activityPanel.setAttribute("aria-busy", "false");
    const box = el("div", "coverage-candidate-error"); box.appendChild(el("p", "coverage-reason", "Learning metrics are unavailable. The source evidence dashboard remains visible."));
    const retry = el("button", "cp-btn cp-btn-ghost", "Retry learning metrics"); retry.type = "button"; retry.addEventListener("click", loadMetrics); box.appendChild(retry); recallNode.replaceChildren(box);
    activityNode.replaceChildren(el("p", "learning-metric-unavailable", "Activity volume unavailable: " + error.message));
    methodologyNode.replaceChildren(el("p", "learning-metric-unavailable", "Methodology unavailable until this panel is retried."));
  }
  async function loadMetrics() {
    recallPanel.setAttribute("aria-busy", "true"); activityPanel.setAttribute("aria-busy", "true");
    try { renderMetrics(demo ? metricsFixture : await api("metrics.get")); return { ok: true }; }
    catch (error) { metricsError(error); return { ok: false, error }; }
  }
  function renderDashboard(data) {
    dashboard = data;
    metricNode.textContent = Number.isInteger(data.numerator) && Number.isInteger(data.denominator) ? data.numerator + " / " + data.denominator + " topics" : "Unavailable";
    percentageNode.textContent = typeof data.percentage === "number" && !data.provisional && data.denominator > 0 ? data.percentage + "%" : "";
    const warning = data.warning || (data.provisional ? "The topic denominator is provisional; no coverage percentage is shown." : data.denominator === 0 ? "No active canonical topics are available; no coverage percentage is shown." : "");
    warningNode.hidden = !warning; warningNode.textContent = warning;
    const list = el("ol", "coverage-topic-list");
    (data.topics || []).forEach(function (topic) {
      const item = el("li", "coverage-topic-row state-" + topic.state);
      const header = el("header", "coverage-topic-header");
      const identity = el("div"); identity.append(el("span", "coverage-position", "Topic " + (topic.position + 1)), el("h3", "", topic.title));
      header.append(identity, el("strong", "coverage-state", topic.state === "covered" ? "Covered" : topic.state === "review" ? "Review proposed evidence" : "Missing")); item.appendChild(header);
      (topic.reason_codes || []).forEach(function (reason) { item.appendChild(el("p", "coverage-reason", reasonText[reason] || String(reason).replaceAll("_", " "))); });
      (topic.confirmed_sources || []).forEach(function (source) { item.appendChild(evidenceCard(source, false)); });
      (topic.proposed_sources || []).forEach(function (source) { item.appendChild(evidenceCard(source, true)); });
      if (topic.state === "missing") {
        const guidance = el("div", "coverage-guidance");
        guidance.appendChild(el("p", "", "Recommended source kinds: " + ((topic.guidance && topic.guidance.recommended_source_kinds) || []).join(", ")));
        const add = el("a", "cp-btn cp-btn-primary", "Add source for this topic"); add.href = topic.guidance.source_intake_url; guidance.appendChild(add); item.appendChild(guidance);
      }
      list.appendChild(item);
    });
    table.replaceChildren(list); table.setAttribute("aria-busy", "false"); populateTopics();
  }
  function populateTopics() {
    const select = manualForm.elements.topic_id; const selected = new URLSearchParams(location.search).get("topic_id");
    while (select.options.length > 1) select.remove(1);
    (dashboard ? dashboard.topics : []).forEach(function (topic) { const option = new Option(topic.title, topic.topic_id); option.selected = topic.topic_id === selected; select.add(option); });
    select.disabled = demo || !dashboard;
    selectionChanged();
  }
  function populateSources() {
    const select = manualForm.elements.source_id; const selected = new URLSearchParams(location.search).get("review_source");
    while (select.options.length > 1) select.remove(1);
    candidates.filter(function (source) { return source.state === "ready" && source.eligible; }).forEach(function (source) { const option = new Option(source.title, source.id); option.selected = source.id === selected; select.add(option); });
    select.disabled = demo || !candidateReady;
    selectionChanged();
  }
  function renderCandidates(items) {
    candidates = items; candidateReady = true;
    const list = el("ul", "coverage-candidate-list");
    items.forEach(function (source) {
      const item = el("li", "coverage-candidate");
      const label = el("label"); const checkbox = document.createElement("input"); checkbox.type = "checkbox"; checkbox.value = source.id; checkbox.dataset.candidateSource = ""; checkbox.disabled = demo || source.state !== "ready" || !source.eligible;
      label.append(checkbox, el("strong", "", source.title));
      item.append(label, el("span", "coverage-candidate-state", "Status: " + source.state + " · Scope: " + source.attachment + " · Type: " + source.source_type));
      if (source.import_error) item.appendChild(el("p", "coverage-reason", "Processing error: " + source.import_error));
      list.appendChild(item);
    });
    if (!items.length) list.appendChild(el("li", "coverage-candidate", "No owned sources are available."));
    candidatesNode.replaceChildren(list); candidatesNode.setAttribute("aria-busy", "false"); recompute.disabled = demo || !dashboard; populateSources();
  }
  function candidateError(error) {
    candidateReady = false; recompute.disabled = true; manualForm.elements.source_id.disabled = true; manualButton.disabled = true;
    const box = el("div", "coverage-candidate-error");
    box.appendChild(el("p", "coverage-reason", error.message));
    const retry = el("button", "cp-btn cp-btn-ghost", "Retry candidate sources"); retry.type = "button"; retry.addEventListener("click", loadCandidates); box.appendChild(retry);
    candidatesNode.replaceChildren(box); candidatesNode.setAttribute("aria-busy", "false");
  }
  async function loadCoverage() {
    try { renderDashboard(demo ? fixture : await api("coverage.get")); return { ok: true }; }
    catch (error) { table.setAttribute("aria-busy", "false"); if (!dashboard) table.replaceChildren(el("p", "coverage-reason", error.message)); return { ok: false, error }; }
  }
  async function loadCandidates() {
    candidatesNode.setAttribute("aria-busy", "true");
    try { renderCandidates(demo ? fixtureCandidates : await api("candidates.list")); return { ok: true }; }
    catch (error) { candidateError(error); return { ok: false, error }; }
  }
  async function refresh(committedMessage) {
    table.setAttribute("aria-busy", "true");
    const coveragePromise = loadCoverage();
    const candidatesPromise = loadCandidates();
    const coverageResult = await coveragePromise;
    const candidateResult = await candidatesPromise;
    recompute.disabled = demo || !coverageResult.ok || !candidateResult.ok;
    if (coverageResult.ok && candidateResult.ok) {
      setStatus(committedMessage || (demo ? "Synthetic fixture. Review controls are disabled." : "Coverage evidence is current."), false);
      return true;
    }
    if (committedMessage) setStatus(committedMessage + " Saved, but the latest dashboard could not reload.", true, function () { refresh(committedMessage); });
    else if (!coverageResult.ok) setStatus(coverageResult.error.message, true, function () { refresh(); });
    else setStatus("Coverage evidence is current. Candidate sources could not reload; use the retry in that panel.", false);
    return false;
  }
  async function mutate(action, options, pending, committedMessage, button) {
    button.disabled = true; setStatus(pending, false);
    let response;
    try { response = await api(action, options); }
    catch (error) { button.disabled = false; setStatus(error.message, true); return null; }
    await refresh(committedMessage);
    return response || true;
  }
  function updateManualButton() {
    const selected = evidenceNode.querySelectorAll('input[type="checkbox"]:checked').length;
    manualButton.disabled = demo || !candidateReady || !manualForm.elements.topic_id.value || !manualForm.elements.source_id.value || selected < 1 || selected > 20;
  }
  function renderChunks(chunks) {
    if (!chunks.length) { evidenceNode.replaceChildren(el("p", "coverage-reason", "No selectable evidence chunks are available for this topic and source.")); updateManualButton(); return; }
    const list = el("ul", "coverage-candidate-list");
    chunks.forEach(function (chunk) {
      const item = el("li", "coverage-candidate"); const label = el("label"); const checkbox = document.createElement("input"); checkbox.type = "checkbox"; checkbox.value = chunk.chunk_id; checkbox.name = "selected_chunk";
      const detail = el("span"); detail.append(el("strong", "", chunk.citation + (chunk.location ? " · " + chunk.location : "")), el("span", "coverage-candidate-state", chunk.excerpt));
      checkbox.addEventListener("change", function () {
        if (evidenceNode.querySelectorAll('input[type="checkbox"]:checked').length > 20) { checkbox.checked = false; evidenceNode.appendChild(el("p", "coverage-reason", "Select no more than 20 excerpts.")); }
        updateManualButton();
      });
      label.append(checkbox, detail); item.appendChild(label); list.appendChild(item);
    });
    evidenceNode.replaceChildren(list); updateManualButton();
  }
  async function loadChunks() {
    const topicId = manualForm.elements.topic_id.value; const sourceId = manualForm.elements.source_id.value; const request = ++chunkRequest;
    manualButton.disabled = true;
    if (!topicId || !sourceId) { evidenceNode.textContent = "Select a topic and ready source to load evidence."; return; }
    evidenceNode.textContent = "Loading evidence excerpts…"; evidenceNode.setAttribute("aria-busy", "true");
    try {
      const chunks = demo ? fixtureChunks : await api("chunks.list", { source_id: sourceId, topic_id: topicId });
      if (request !== chunkRequest) return;
      evidenceNode.setAttribute("aria-busy", "false"); renderChunks(chunks);
    } catch (error) {
      if (request !== chunkRequest) return;
      evidenceNode.setAttribute("aria-busy", "false"); const retry = el("button", "cp-btn cp-btn-ghost", "Retry evidence excerpts"); retry.type = "button"; retry.addEventListener("click", loadChunks); evidenceNode.replaceChildren(el("p", "coverage-reason", error.message), retry);
    }
  }
  function selectionChanged() { loadChunks(); }

  recompute.disabled = true;
  recompute.addEventListener("click", async function () {
    const sourceIds = Array.from(root.querySelectorAll("[data-candidate-source]:checked")).map(function (input) { return input.value; });
    const result = await mutate("coverage.recompute", { payload: { source_ids: sourceIds } }, "Recomputing deterministic proposals… Existing confirmations will remain unchanged.", "Recompute committed; proposals still require review.", recompute);
    if (result && !statusNode.querySelector("button")) setStatus("Recompute committed: " + result.created + " created, " + result.updated + " updated, and " + result.protected_decisions + " reviewed decisions protected. Proposals still require review.", false);
  });
  manualForm.elements.topic_id.addEventListener("change", selectionChanged);
  manualForm.elements.source_id.addEventListener("change", selectionChanged);
  if (demo) manualForm.querySelector("fieldset").disabled = true;
  manualForm.addEventListener("submit", async function (event) {
    event.preventDefault();
    const chunks = Array.from(evidenceNode.querySelectorAll('input[type="checkbox"]:checked')).map(function (input) { return input.value; });
    if (chunks.length < 1 || chunks.length > 20) { setStatus("Select 1–20 evidence excerpts.", true); evidenceNode.focus(); return; }
    const result = await mutate("association.manual", { payload: { topic_id: manualForm.elements.topic_id.value, source_id: manualForm.elements.source_id.value, chunk_ids: chunks, reason_code: "manual_source_review" } }, "Confirming selected manual evidence…", "Manual evidence confirmed.", manualButton);
    if (result) renderChunks([]);
  });
  loadMetrics();
  refresh();
}());
