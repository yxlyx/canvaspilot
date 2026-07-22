(function () {
  const themeButtons = document.querySelectorAll("[data-cp-theme-toggle]");

  function syncThemeButtons() {
    const dark = document.documentElement.dataset.theme === "dark";
    themeButtons.forEach(function (button) {
      const label = dark ? "Switch to light mode" : "Switch to dark mode";
      button.setAttribute("aria-label", label);
      button.setAttribute("title", label);
      button.innerHTML = dark
        ? '<svg aria-hidden="true" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/></svg>'
        : '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M12 3a6 6 0 1 0 9 9 9 9 0 1 1-9-9Z"/></svg>';
    });
  }

  themeButtons.forEach(function (button) {
    button.addEventListener("click", function () {
      const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
      document.documentElement.dataset.theme = next;
      try {
        localStorage.setItem("wikibase-theme", next);
      } catch (_) {}
      syncThemeButtons();
    });
  });
  syncThemeButtons();

  setupChat();
  setupFlashcards();
  setupDashboard();
  setupSources();
  setupWiki();
  setupArticle();

  function setupDashboard() {
    const mode = document.getElementById("cp-dashboard-mode");
    const label = document.getElementById("cp-dashboard-mode-label");
    const copy = document.getElementById("cp-dashboard-mode-copy");
    const notice = document.getElementById("cp-dashboard-notice");
    const sync = document.getElementById("cp-dashboard-sync");
    if (mode && label && copy && notice) {
      const states = {
        mock: {
          label: "Fixture preview",
          copy: "You are viewing the complete prototype with sample module data.",
          tone: "info",
        },
        live: {
          label: "Live preview",
          copy: "Everything is indexed and ready for study.",
          tone: "good",
        },
        fallback: {
          label: "Fallback preview",
          copy: "The latest saved workspace is available while the service reconnects.",
          tone: "warn",
        },
      };
      mode.addEventListener("change", function () {
        const state = states[mode.value] || states.mock;
        label.textContent = state.label;
        copy.textContent = state.copy;
        label.className = "status-pill status-" + state.tone;
        notice.className = "notice notice-" + state.tone;
      });
    }
    if (sync) {
      sync.addEventListener("click", function () {
        if (sync.disabled) return;
        sync.disabled = true;
        sync.textContent = "Syncing…";
        window.setTimeout(function () {
          sync.textContent = "Synced just now";
          window.setTimeout(function () {
            sync.disabled = false;
            sync.textContent = "Sync sources";
          }, 1600);
        }, 700);
      });
    }
  }

  function setupSources() {
    const grid = document.getElementById("cp-document-grid");
    const search = document.getElementById("cp-source-search");
    const format = document.getElementById("cp-source-format");
    const module = document.getElementById("cp-source-module");
    const count = document.getElementById("cp-source-count");
    const heading = document.getElementById("cp-source-heading");
    const empty = document.getElementById("cp-source-empty");
    const addModal = document.getElementById("cp-add-source-modal");
    const previewModal = document.getElementById("cp-source-preview-modal");
    if (!grid || !search || !format || !module) return;

    let status = "All";
    let lastTrigger = null;
    const initialParams = new URLSearchParams(window.location.search);
    const initialStatus = (initialParams.get("status") || "").toLowerCase();
    const initialType = (initialParams.get("type") || "").toLowerCase();
    if (initialStatus === "ready" || initialStatus === "indexed") status = "Ready";
    if (initialStatus === "pending" || initialStatus === "indexing" || initialStatus === "processing") status = "Importing";
    if (initialStatus === "failed" || initialStatus === "archived" || initialStatus === "review") status = "Needs attention";
    if (initialType === "url" || initialType === "web") format.value = "URL";
    if (initialType === "pdf" || initialType === "markdown" || initialType === "assignment" || initialType === "announcement") format.value = "PDF";

    function cards() {
      return Array.from(grid.querySelectorAll(".document-card"));
    }

    function applyFilters() {
      const query = search.value.trim().toLowerCase();
      let shown = 0;
      cards().forEach(function (card) {
        const haystack = [card.dataset.title, card.dataset.module, card.dataset.format, card.dataset.tags].join(" ").toLowerCase();
        const visible = (!query || haystack.indexOf(query) !== -1)
          && (status === "All" || card.dataset.status === status)
          && (format.value === "All" || card.dataset.format === format.value)
          && (module.value === "All" || card.dataset.module === module.value);
        card.hidden = !visible;
        if (visible) shown += 1;
      });
      if (count) count.textContent = String(shown);
      if (heading) heading.textContent = status === "All" ? "All documents" : status;
      if (empty) empty.hidden = shown !== 0;
      grid.hidden = shown === 0;
    }

    function closeModal(modal) {
      if (!modal) return;
      modal.hidden = true;
      document.body.classList.remove("modal-open");
      if (lastTrigger && document.contains(lastTrigger)) lastTrigger.focus();
    }

    function openModal(modal, trigger) {
      if (!modal) return;
      lastTrigger = trigger || document.activeElement;
      modal.hidden = false;
      document.body.classList.add("modal-open");
      const focusTarget = modal.querySelector("button, input, select, a");
      if (focusTarget) focusTarget.focus();
    }

    document.querySelectorAll("[data-source-status]").forEach(function (button) {
      const initiallySelected = button.dataset.sourceStatus === status;
      button.classList.toggle("active", initiallySelected);
      button.setAttribute("aria-pressed", String(initiallySelected));
      button.addEventListener("click", function () {
        status = button.dataset.sourceStatus || "All";
        document.querySelectorAll("[data-source-status]").forEach(function (item) {
          const selected = item === button;
          item.classList.toggle("active", selected);
          item.setAttribute("aria-pressed", String(selected));
        });
        applyFilters();
      });
    });
    document.querySelectorAll("[data-source-view]").forEach(function (button) {
      button.addEventListener("click", function () {
        const view = button.dataset.sourceView || "grid";
        grid.classList.toggle("grid", view === "grid");
        grid.classList.toggle("list", view === "list");
        document.querySelectorAll("[data-source-view]").forEach(function (item) {
          const selected = item === button;
          item.classList.toggle("active", selected);
          item.setAttribute("aria-pressed", String(selected));
        });
      });
    });
    search.addEventListener("input", applyFilters);
    format.addEventListener("change", applyFilters);
    module.addEventListener("change", applyFilters);

    const clear = document.getElementById("cp-clear-source-filters");
    if (clear) clear.addEventListener("click", function () {
      search.value = "";
      format.value = "All";
      module.value = "All";
      status = "All";
      const all = document.querySelector('[data-source-status="All"]');
      if (all) all.click();
      search.focus();
    });

    grid.addEventListener("click", function (event) {
      const trigger = event.target.closest("[data-source-preview]");
      if (!trigger) return;
      const card = trigger.closest(".document-card");
      if (!card) return;
      const title = card.dataset.title || "Source";
      const titleElement = document.getElementById("cp-preview-title");
      const paperTitle = document.getElementById("cp-preview-paper-title");
      const detail = document.getElementById("cp-preview-detail");
      const previewStatus = document.getElementById("cp-preview-status");
      if (titleElement) titleElement.textContent = title;
      if (paperTitle) paperTitle.textContent = title.replace(/^.*?—\s*/, "");
      if (detail) detail.textContent = [card.dataset.module, card.dataset.format, card.dataset.tags].filter(Boolean).join(" · ");
      if (previewStatus) {
        previewStatus.textContent = card.dataset.status || "Ready";
        previewStatus.className = "status-pill status-" + (card.dataset.status === "Ready" ? "good" : card.dataset.status === "Importing" ? "info" : "warn");
      }
      openModal(previewModal, trigger);
    });

    const add = document.getElementById("cp-add-source");
    if (add) add.addEventListener("click", function () { openModal(addModal, add); });
    document.querySelectorAll("[data-close-source-modal]").forEach(function (button) {
      button.addEventListener("click", function () { closeModal(button.closest(".modal-backdrop")); });
    });
    [addModal, previewModal].forEach(function (modal) {
      if (!modal) return;
      modal.addEventListener("click", function (event) {
        if (event.target === modal) closeModal(modal);
      });
    });
    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape") return;
      if (addModal && !addModal.hidden) closeModal(addModal);
      if (previewModal && !previewModal.hidden) closeModal(previewModal);
    });

    const addForm = document.getElementById("cp-add-source-form");
    if (addForm) addForm.addEventListener("submit", function (event) {
      event.preventDefault();
      const titleField = document.getElementById("cp-new-source-title");
      const moduleField = document.getElementById("cp-new-source-module");
      const title = titleField && titleField.value.trim() ? titleField.value.trim() : "New course source";
      const moduleCode = moduleField ? moduleField.value.split(" ")[0] : "CS2040S";
      const card = cards()[0].cloneNode(true);
      card.dataset.title = title;
      card.dataset.module = moduleCode;
      card.dataset.format = "URL";
      card.dataset.status = "Importing";
      card.dataset.tags = "New source";
      card.hidden = false;
      const cardTitle = card.querySelector("header h3");
      const cardMeta = card.querySelector("header p");
      const paperTitle = card.querySelector(".document-paper h3");
      const pill = card.querySelector(".status-pill");
      const tags = card.querySelector(".document-tags");
      if (cardTitle) cardTitle.textContent = title;
      if (cardMeta) cardMeta.textContent = moduleCode + " · Web page · Parsing sections";
      if (paperTitle) paperTitle.textContent = title;
      if (pill) { pill.textContent = "Importing"; pill.className = "status-pill status-info"; }
      if (tags) tags.textContent = "New source";
      card.querySelectorAll("[aria-label]").forEach(function (element) {
        if (element.hasAttribute("data-source-preview")) element.setAttribute("aria-label", "Preview " + title);
      });
      grid.insertBefore(card, grid.firstChild);
      addForm.reset();
      closeModal(addModal);
      applyFilters();
    });
    applyFilters();
  }

  function setupWiki() {
    const grid = document.getElementById("cp-wiki-grid");
    const search = document.getElementById("cp-wiki-search");
    const empty = document.getElementById("cp-wiki-empty");
    if (!grid || !search) return;
    let module = new URLSearchParams(window.location.search).get("module") || "All";

    function filter() {
      const query = search.value.trim().toLowerCase();
      let shown = 0;
      grid.querySelectorAll(".article-card").forEach(function (card) {
        const matches = (!query || (card.dataset.search || "").toLowerCase().indexOf(query) !== -1)
          && (module === "All" || card.dataset.module === module);
        card.hidden = !matches;
        if (matches) shown += 1;
      });
      grid.hidden = shown === 0;
      if (empty) empty.hidden = shown !== 0;
    }

    document.querySelectorAll("[data-wiki-module]").forEach(function (button) {
      const selected = button.dataset.wikiModule === module;
      button.classList.toggle("active", selected);
      button.setAttribute("aria-pressed", String(selected));
      button.addEventListener("click", function () {
        module = button.dataset.wikiModule || "All";
        document.querySelectorAll("[data-wiki-module]").forEach(function (item) {
          const active = item === button;
          item.classList.toggle("active", active);
          item.setAttribute("aria-pressed", String(active));
        });
        filter();
      });
    });
    search.addEventListener("input", filter);
    const clear = document.getElementById("cp-clear-wiki-search");
    if (clear) clear.addEventListener("click", function () {
      search.value = "";
      module = "All";
      const all = document.querySelector('[data-wiki-module="All"]');
      if (all) all.click();
      search.focus();
    });
    filter();
  }

  function setupArticle() {
    const save = document.getElementById("cp-save-article");
    const copy = document.getElementById("cp-copy-article");
    if (save) save.addEventListener("click", function () {
      const active = save.getAttribute("aria-pressed") !== "true";
      save.setAttribute("aria-pressed", String(active));
      const label = save.querySelector("span");
      if (label) label.textContent = active ? "Saved" : "Save article";
    });
    if (copy) copy.addEventListener("click", function () {
      const label = copy.querySelector("span");
      const reset = function () { if (label) label.textContent = "Copy link"; };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(window.location.href).then(function () {
          if (label) label.textContent = "Copied";
          window.setTimeout(reset, 1400);
        }).catch(function () {
          if (label) label.textContent = "Copy unavailable";
          window.setTimeout(reset, 1400);
        });
      }
    });
  }

  function setupChat() {
    const form = document.getElementById("cp-chat-form");
    const log = document.getElementById("cp-chat-log");
    const input = document.getElementById("cp-chat-input");
    const sendButton = document.getElementById("cp-chat-send");
    const moduleSelect = document.getElementById("cp-chat-module");
    const moduleCode = document.getElementById("cp-chat-module-code");
    const composerCode = document.getElementById("cp-chat-composer-code");
    const welcome = document.getElementById("cp-chat-welcome");
    const clearButton = document.getElementById("cp-chat-clear");
    if (!form || !log || !input || !sendButton) return;

    const history = [];
    let loading = false;
    let lastFailedMessage = null;

    function selectedCode() {
      if (!moduleSelect) return "CS2040S";
      const option = moduleSelect.options[moduleSelect.selectedIndex];
      return (option && (option.dataset.code || option.textContent || "CS2040S").trim().split(/\s|—/)[0]) || "CS2040S";
    }

    function syncModule() {
      const code = selectedCode();
      if (moduleCode) moduleCode.textContent = code;
      if (composerCode) composerCode.textContent = code;
      input.setAttribute("aria-label", "Ask from " + code);
    }

    function syncSend() {
      sendButton.disabled = loading || input.value.trim().length === 0;
    }

    function showConversation() {
      if (welcome) welcome.hidden = true;
      if (clearButton) clearButton.disabled = false;
    }

    function makeMark(kind) {
      const mark = document.createElement("div");
      mark.className = "answer-mark";
      mark.innerHTML = kind === "error"
        ? '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M10.3 2.9 1.8 17a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 2.9a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4M12 17h.01"/></svg>'
        : '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M20 13c0 5-3.5 7.5-8 9-4.5-1.5-8-4-8-9V5l8-3 8 3v8Z"/><path d="m9 12 2 2 4-4"/></svg>';
      return mark;
    }

    function appendStudent(message) {
      const article = document.createElement("article");
      article.className = "student-turn chat-dynamic";
      const profile = document.createElement("div");
      profile.className = "cp-profile-orb";
      profile.textContent = "PS";
      const content = document.createElement("div");
      const label = document.createElement("small");
      label.textContent = "You";
      const text = document.createElement("p");
      text.textContent = message;
      content.append(label, text);
      article.append(profile, content);
      log.appendChild(article);
      showConversation();
    }

    function appendLoading() {
      const article = document.createElement("article");
      article.className = "answer-turn loading-turn chat-dynamic";
      article.appendChild(makeMark("answer"));
      const content = document.createElement("div");
      const label = document.createElement("small");
      label.textContent = "Tracing the evidence";
      const dots = document.createElement("p");
      for (let index = 0; index < 3; index += 1) {
        const dot = document.createElement("span");
        dot.className = "typing-dot";
        dots.appendChild(dot);
      }
      content.append(label, dots);
      article.appendChild(content);
      log.appendChild(article);
      return article;
    }

    function safeCitationUrl(raw) {
      if (!raw) return "/sources";
      try {
        if (raw.startsWith("/")) return raw;
        const url = new URL(raw, window.location.origin);
        if (url.protocol === "http:" || url.protocol === "https:") return url.href;
      } catch (_) {}
      return "/sources";
    }

    function appendAnswer(message, citations) {
      const article = document.createElement("article");
      article.className = "answer-turn chat-dynamic";
      article.appendChild(makeMark("answer"));
      const content = document.createElement("div");
      const label = document.createElement("small");
      label.textContent = "Grounded answer";
      const text = document.createElement("p");
      text.textContent = message;
      content.append(label, text);

      const citationList = Array.isArray(citations) && citations.length ? citations : [
        { title: "Lecture 08, pp. 15–18", url: "/sources" },
        { title: "Tutorial 05, question 2", url: "/sources" },
      ];
      const citationRow = document.createElement("div");
      citationRow.className = "answer-citations";
      citationList.slice(0, 3).forEach(function (citation, index) {
        const link = document.createElement("a");
        link.className = "citation";
        link.href = safeCitationUrl(citation.url || "");
        const number = document.createElement("span");
        number.textContent = String(index + 1);
        link.append(number, document.createTextNode(citation.title || "Source"));
        citationRow.appendChild(link);
      });
      content.appendChild(citationRow);

      const footer = document.createElement("footer");
      const prompt = document.createElement("span");
      prompt.textContent = "Was this grounded enough?";
      const useful = document.createElement("button");
      useful.type = "button";
      useful.textContent = "Yes";
      useful.setAttribute("aria-label", "Answer was useful");
      const needsWork = document.createElement("button");
      needsWork.type = "button";
      needsWork.textContent = "Needs work";
      needsWork.setAttribute("aria-label", "Answer needs work");
      const wiki = document.createElement("a");
      wiki.href = "/wiki/balanced-search-trees";
      wiki.textContent = "Open related wiki →";
      footer.append(prompt, useful, needsWork, wiki);
      content.appendChild(footer);
      article.appendChild(content);
      log.appendChild(article);
    }

    function appendError(message, retryMessage) {
      const article = document.createElement("article");
      article.className = "answer-turn answer-error chat-dynamic";
      article.appendChild(makeMark("error"));
      const content = document.createElement("div");
      const label = document.createElement("small");
      label.textContent = "Retrieval interrupted";
      const text = document.createElement("p");
      text.textContent = message;
      const retry = document.createElement("button");
      retry.className = "cp-btn cp-btn-ghost";
      retry.type = "button";
      retry.textContent = "Retry";
      retry.addEventListener("click", function () {
        article.remove();
        sendMessage(retryMessage, false);
      });
      content.append(label, text, retry);
      article.appendChild(content);
      log.appendChild(article);
    }

    async function sendMessage(message, addStudent) {
      loading = true;
      lastFailedMessage = null;
      input.disabled = true;
      syncSend();
      const priorHistory = history.slice();
      if (addStudent !== false) appendStudent(message);
      history.push({ role: "user", content: message });
      const pending = appendLoading();
      log.scrollTop = log.scrollHeight;

      try {
        const response = await fetch("/api/chat", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            message: message,
            module_id: moduleSelect && moduleSelect.value ? moduleSelect.value : null,
            history: priorHistory,
          }),
        });
        if (!response.ok) throw new Error("HTTP " + response.status);
        const data = await response.json();
        pending.remove();
        const reply = data.message || "No grounded answer was returned.";
        appendAnswer(reply, data.citations);
        history.push({ role: "assistant", content: reply });
        input.value = "";
      } catch (error) {
        pending.remove();
        history.length = 0;
        history.push.apply(history, priorHistory);
        appendError("The retrieval step could not complete. Your question is still here, so you can retry safely.", message);
        lastFailedMessage = message;
        input.value = message;
      } finally {
        loading = false;
        input.disabled = false;
        syncSend();
        input.focus();
        log.scrollTop = log.scrollHeight;
      }
    }

    document.querySelectorAll(".suggestion-list [data-prompt]").forEach(function (button) {
      button.addEventListener("click", function () {
        input.value = button.dataset.prompt || "";
        syncSend();
        input.focus();
      });
    });

    input.addEventListener("input", syncSend);
    if (moduleSelect) moduleSelect.addEventListener("change", syncModule);
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      const message = input.value.trim();
      if (!message || loading) return;
      sendMessage(message, true);
    });
    if (clearButton) {
      clearButton.addEventListener("click", function () {
        log.querySelectorAll(".chat-dynamic").forEach(function (turn) { turn.remove(); });
        history.length = 0;
        if (welcome) welcome.hidden = false;
        clearButton.disabled = true;
      });
    }

    window.addEventListener("beforeunload", function () {
      if (lastFailedMessage) sessionStorage.setItem("cp:last-failed", lastFailedMessage);
    });
    const queued = sessionStorage.getItem("cp:last-failed");
    if (queued) {
      input.value = queued;
      sessionStorage.removeItem("cp:last-failed");
    }
    syncModule();
    syncSend();
  }

  function setupFlashcards() {
    const review = document.getElementById("cp-flash-review");
    const flashcard = document.getElementById("cp-flashcard");
    const revealButton = document.getElementById("cp-reveal-card");
    const answer = document.getElementById("cp-card-answer");
    const ratingPanel = document.getElementById("cp-rating-panel");
    const hint = document.getElementById("cp-review-hint");
    if (!review || !flashcard || !revealButton || !answer || !ratingPanel) return;

    const cards = Array.from(document.querySelectorAll("#cp-flash-data [data-card-id]"));
    let index = 0;
    let reviewed = Number((document.getElementById("cp-reviewed-count") || {}).textContent || 0);
    let revealed = false;

    document.querySelectorAll("[data-deck-url]").forEach(function (button) {
      button.addEventListener("click", function () {
        window.location.href = button.dataset.deckUrl;
      });
    });

    function setRevealed(next) {
      revealed = next;
      flashcard.classList.toggle("revealed", next);
      answer.hidden = !next;
      revealButton.hidden = next;
      ratingPanel.hidden = !next;
      if (hint) hint.hidden = next;
    }

    function renderCurrent() {
      if (!cards.length) return;
      const card = cards[index % cards.length];
      document.getElementById("cp-card-number").textContent = String((index % cards.length) + 1);
      document.getElementById("cp-card-question").textContent = card.dataset.question || "";
      document.getElementById("cp-card-answer-text").textContent = card.dataset.answer || "";
      document.getElementById("cp-card-source").textContent = card.dataset.source || "Source";
      document.getElementById("cp-card-page").textContent = card.dataset.page || "";
      document.querySelectorAll('[name="card_id"]').forEach(function (field) {
        field.value = card.dataset.cardId || "";
      });
      setRevealed(false);
    }

    function updateEvidence() {
      const count = document.getElementById("cp-reviewed-count");
      const evidence = document.getElementById("cp-evidence-reviewed");
      const recall = document.getElementById("cp-evidence-recall");
      const bar = document.getElementById("cp-review-bar");
      if (count) count.textContent = String(reviewed);
      if (evidence) evidence.textContent = String(reviewed);
      if (recall) recall.textContent = reviewed ? "80%" : "—";
      if (bar) bar.style.width = Math.min(100, reviewed / 8 * 100) + "%";
    }

    function rate() {
      if (!revealed) return;
      reviewed += 1;
      index = cards.length ? (index + 1) % cards.length : 0;
      updateEvidence();
      renderCurrent();
    }

    revealButton.addEventListener("click", function () { setRevealed(true); });
    document.querySelectorAll("form[data-flash-rate]").forEach(function (form) {
      form.addEventListener("submit", function (event) {
        event.preventDefault();
        const request = fetch(form.action, { method: "POST", body: new FormData(form), redirect: "manual" });
        request.catch(function () {});
        rate();
      });
    });
    document.querySelectorAll("button[data-flash-rate]").forEach(function (button) {
      button.addEventListener("click", rate);
    });

    document.addEventListener("keydown", function (event) {
      const target = event.target;
      if (target && /INPUT|TEXTAREA|SELECT/.test(target.tagName)) return;
      if (event.code === "Space") {
        event.preventDefault();
        if (!revealed) setRevealed(true);
      } else if (revealed && /^[1-4]$/.test(event.key)) {
        event.preventDefault();
        rate();
      }
    });
    renderCurrent();
  }
})();
