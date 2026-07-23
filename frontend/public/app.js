(function () {
  const themeButtons = document.querySelectorAll("[data-cp-theme-toggle]");

  function persistThemePreference(preference) {
    try {
      localStorage.setItem("wikibase-theme", preference);
      localStorage.setItem("wikibase-theme-preference", preference);
      const secure = window.location.protocol === "https:" ? "; Secure" : "";
      document.cookie = "wb_theme_preference=" + encodeURIComponent(preference) + "; Path=/; Max-Age=31536000; SameSite=Lax" + secure;
    } catch (_) {}

    if (!document.querySelector("[data-cp-account-name]")) return;
    fetch("/api/settings", {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
      },
      body: new URLSearchParams({ action: "preferences.theme", theme: preference }),
      credentials: "same-origin",
    }).catch(function () {});
  }

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
      persistThemePreference(next);
      syncThemeButtons();
    });
  });
  syncThemeButtons();

  setupAuth();
  setupShell();
  setupChat();
  setupFlashcards();
  setupDashboard();
  setupSources();
  setupWiki();
  setupArticle();

  async function setupShell() {
    const nameNodes = document.querySelectorAll("[data-cp-account-name]");
    const initialNodes = document.querySelectorAll("[data-cp-account-initial]");
    const notificationLinks = document.querySelectorAll("[data-cp-notification-link]");
    if (!nameNodes.length && !initialNodes.length && !notificationLinks.length) return;

    try {
      const response = await fetch("/api/me", { headers: { Accept: "application/json" }, credentials: "same-origin" });
      if (response.ok) {
        const user = await response.json();
        const name = typeof user.name === "string" && user.name.trim() ? user.name.trim() : "Account";
        const initial = Array.from(name)[0]?.toUpperCase() || "W";
        nameNodes.forEach(function (node) { node.textContent = name; });
        initialNodes.forEach(function (node) { node.textContent = initial; });
      }
    } catch (_) {}

    if (!notificationLinks.length) return;
    try {
      const response = await fetch("/api/notifications/unread-count", { headers: { Accept: "application/json" }, credentials: "same-origin" });
      if (!response.ok) return;
      const body = await response.json();
      const count = Number.isFinite(body.unread_count) ? Math.max(0, body.unread_count) : 0;
      notificationLinks.forEach(function (link) {
        const dot = link.querySelector("i");
        if (dot) dot.hidden = count === 0;
        link.setAttribute("aria-label", count > 0 ? `Notifications, ${count} unread` : "Notifications");
      });
    } catch (_) {}
  }

  function setupAuth() {
    const page = document.querySelector("[data-auth-page]");
    if (!page) return;

    const form = page.querySelector("[data-auth-form]");
    const submit = page.querySelector("[data-auth-submit]");
    const submitLabel = page.querySelector("[data-auth-submit-label]");
    let submitting = false;

    page.querySelectorAll("[data-password-toggle]").forEach(function (button) {
      button.addEventListener("click", function () {
        const input = button.parentElement && button.parentElement.querySelector("input");
        if (!input) return;
        const willShow = input.type === "password";
        input.type = willShow ? "text" : "password";
        button.textContent = willShow ? "Hide" : "Show";
        const subject = input.matches("[data-password-confirm-input]") ? "password confirmation" : "password";
        button.setAttribute("aria-label", (willShow ? "Hide " : "Show ") + subject);
      });
    });

    if (form && form.dataset.authKind === "signup") {
      const password = form.querySelector("[data-password-input]");
      const confirm = form.querySelector("[data-password-confirm-input]");
      const confirmWrap = form.querySelector("[data-password-confirm]");
      const match = form.querySelector("[data-password-match]");
      let revealed = false;

      const ruleChecks = {
        length: function (value) { return value.length >= 8; },
        uppercase: function (value) { return /[A-Z]/.test(value); },
        number: function (value) { return /[0-9]/.test(value); },
      };

      function revealConfirmation() {
        if (revealed || !confirmWrap || !confirm) return;
        revealed = true;
        confirm.disabled = false;
        confirmWrap.classList.add("is-revealed");
        confirmWrap.removeAttribute("aria-hidden");
      }

      function updatePolicy() {
        if (!password) return false;
        const value = password.value;
        let valid = true;
        Object.keys(ruleChecks).forEach(function (name) {
          const item = form.querySelector('[data-password-rule="' + name + '"]');
          const met = ruleChecks[name](value);
          valid = valid && met;
          if (!item) return;
          item.classList.toggle("is-met", met);
          item.setAttribute("aria-label", (met ? "Met: " : "Not met: ") + item.textContent.trim());
        });
        password.setCustomValidity(value && !valid ? "Use at least 8 characters, including an uppercase letter and a number." : "");
        if (value) revealConfirmation();
        return valid;
      }

      function updateMatch() {
        if (!password || !confirm || !match) return true;
        const hasConfirmation = confirm.value.length > 0;
        const matches = hasConfirmation && confirm.value === password.value;
        confirm.setCustomValidity(hasConfirmation && !matches ? "Passwords do not match." : "");
        confirm.setAttribute("aria-invalid", hasConfirmation && !matches ? "true" : "false");
        match.textContent = !hasConfirmation ? "" : matches ? "Passwords match" : "Passwords do not match";
        match.classList.toggle("is-match", matches);
        match.classList.toggle("is-mismatch", hasConfirmation && !matches);
        return !hasConfirmation || matches;
      }

      if (password && confirm && confirmWrap) {
        if (password.value) {
          revealConfirmation();
        } else {
          confirm.disabled = true;
          confirmWrap.setAttribute("aria-hidden", "true");
        }
        password.addEventListener("input", function () {
          updatePolicy();
          updateMatch();
          password.removeAttribute("aria-invalid");
        });
        password.addEventListener("blur", function () {
          password.setAttribute("aria-invalid", password.value && !updatePolicy() ? "true" : "false");
        });
        confirm.addEventListener("input", updateMatch);
        [120, 500].forEach(function (delay) {
          window.setTimeout(function () {
            if (password.value) revealConfirmation();
            updatePolicy();
            updateMatch();
          }, delay);
        });
        updatePolicy();
      }
    }

    if (form) {
      form.addEventListener("submit", function (event) {
        if (submitting) {
          event.preventDefault();
          return;
        }
        const password = form.querySelector("[data-password-input]");
        const confirm = form.querySelector("[data-password-confirm-input]");
        if (password) password.dispatchEvent(new Event("input"));
        if (confirm) confirm.dispatchEvent(new Event("input"));
        if (!form.checkValidity()) {
          event.preventDefault();
          const invalid = form.querySelector(":invalid");
          if (invalid) {
            invalid.setAttribute("aria-invalid", "true");
            invalid.focus();
            invalid.reportValidity();
          }
          return;
        }
        submitting = true;
        if (submit) {
          submit.disabled = true;
          submit.setAttribute("aria-busy", "true");
        }
        if (submitLabel) {
          submitLabel.textContent = form.dataset.authKind === "signup" ? "Creating workspace…" : "Opening workspace…";
        }
      });
    }

    const alert = page.querySelector('[data-auth-alert][role="alert"]');
    if (alert) window.requestAnimationFrame(function () { alert.focus(); });

    window.addEventListener("pageshow", function () {
      submitting = false;
      if (submit) {
        submit.disabled = false;
        submit.removeAttribute("aria-busy");
      }
      if (submitLabel && form) {
        submitLabel.textContent = form.dataset.authKind === "signup" ? "Create my WikiBase" : "Sign in to WikiBase";
      }
    });
  }

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
    if (!grid || !search || !format) return;

    let status = "All";
    let lastTrigger = null;
    const initialParams = new URLSearchParams(window.location.search);
    const initialStatus = normalizeStatus(initialParams.get("status"));
    const initialType = normalizeFormat(initialParams.get("type"));
    if (initialStatus) status = initialStatus;
    if (initialType) format.value = initialType;

    function normalizeStatus(value) {
      const normalized = (value || "").trim().toLowerCase();
      if (!normalized || normalized === "all") return "All";
      if (normalized === "ready" || normalized === "indexed") return "Ready";
      if (normalized === "pending" || normalized === "indexing" || normalized === "processing" || normalized === "pending / importing") return "Importing";
      if (normalized === "failed" || normalized === "archived" || normalized === "review" || normalized === "needs review" || normalized === "needs attention") return "Needs attention";
      return value;
    }

    function normalizeFormat(value) {
      const normalized = (value || "").trim().toLowerCase();
      if (!normalized) return "";
      if (normalized === "url" || normalized === "web" || normalized === "web_page" || normalized === "link") return "url";
      return "document";
    }

    function cards() {
      return Array.from(grid.querySelectorAll(".document-card"));
    }

    function applyFilters() {
      const query = search.value.trim().toLowerCase();
      const activeFormat = normalizeFormat(format.value);
      let shown = 0;
      cards().forEach(function (card) {
        const haystack = [card.dataset.title, card.dataset.module, card.dataset.format, card.dataset.tags].join(" ").toLowerCase();
        const visible = (!query || haystack.indexOf(query) !== -1)
          && (status === "All" || normalizeStatus(card.dataset.status) === status)
          && (!activeFormat || normalizeFormat(card.dataset.format) === activeFormat)
          && (!module || module.value === "All" || card.dataset.module === module.value);
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
      const initiallySelected = normalizeStatus(button.dataset.sourceStatus) === status;
      button.classList.toggle("active", initiallySelected);
      button.setAttribute("aria-pressed", String(initiallySelected));
      button.addEventListener("click", function (event) {
        event.preventDefault();
        status = normalizeStatus(button.dataset.sourceStatus);
        document.querySelectorAll("[data-source-status]").forEach(function (item) {
          const selected = item === button;
          item.classList.toggle("active", selected);
          item.setAttribute("aria-pressed", String(selected));
        });
        applyFilters();
      });
    });
    document.querySelectorAll("[data-source-view]").forEach(function (button) {
      button.addEventListener("click", function (event) {
        event.preventDefault();
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
    if (module) module.addEventListener("change", applyFilters);

    const clear = document.getElementById("cp-clear-source-filters");
    if (clear) clear.addEventListener("click", function () {
      search.value = "";
      format.value = "";
      if (module) module.value = "All";
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
      const previewContext = document.getElementById("cp-preview-context");
      const previewFormat = document.getElementById("cp-preview-format");
      const previewTopics = document.getElementById("cp-preview-topics");
      if (titleElement) titleElement.textContent = title;
      if (paperTitle) paperTitle.textContent = title.replace(/^.*?—\s*/, "");
      if (detail) detail.textContent = [card.dataset.module, card.dataset.format, card.dataset.tags].filter(Boolean).join(" · ");
      if (previewContext) previewContext.textContent = card.dataset.module || "Workspace";
      if (previewFormat) previewFormat.textContent = card.dataset.format || "Source";
      if (previewTopics) previewTopics.textContent = card.dataset.tags || "No topics assigned";
      if (previewStatus) {
        const displayStatus = card.dataset.displayStatus || normalizeStatus(card.dataset.status) || "Ready";
        previewStatus.textContent = displayStatus;
        previewStatus.className = "status-pill status-" + (displayStatus === "Ready" ? "good" : displayStatus === "Pending" || displayStatus === "Importing" ? "info" : "warn");
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
      const activeModal = addModal && !addModal.hidden ? addModal : previewModal && !previewModal.hidden ? previewModal : null;
      if (!activeModal) return;
      if (event.key === "Escape") {
        closeModal(activeModal);
        return;
      }
      if (event.key !== "Tab") return;
      const focusable = Array.from(activeModal.querySelectorAll('button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])'));
      if (!focusable.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    });

    const addForm = document.getElementById("cp-add-source-form");
    if (addForm) addForm.addEventListener("submit", async function (event) {
      event.preventDefault();
      const statusNode = addForm.querySelector(".cp-form-status");
      const submit = addForm.querySelector('button[type="submit"]');
      const title = (document.getElementById("cp-new-source-title") || {}).value || "";
      const url = (document.getElementById("cp-new-source-url") || {}).value || "";
      const origin = (document.getElementById("cp-new-source-module") || {}).value || "Workspace";
      if (submit) submit.disabled = true;
      if (statusNode) statusNode.textContent = "Adding source…";
      try {
        const response = await fetch(addForm.action, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ source_type: "link", origin: origin.trim(), title: title.trim(), source_url: url.trim() }),
        });
        if (!response.ok) throw new Error(response.status === 401 ? "Your session has expired. Sign in and try again." : "The source could not be added. Check the link and try again.");
        if (statusNode) statusNode.textContent = "Source saved as metadata. Ingestion has not started.";
        window.setTimeout(function () { window.location.assign("/sources?import=saved"); }, 450);
      } catch (error) {
        if (statusNode) statusNode.textContent = error && error.message ? error.message : "The source could not be added.";
        if (submit) submit.disabled = false;
      }
    });

    applyFilters();
  }

  function setupWiki() {
    const grid = document.getElementById("cp-wiki-grid");
    const search = document.getElementById("cp-wiki-search");
    const empty = document.getElementById("cp-wiki-empty");
    if (!grid || !search) return;
    const requestedModule = new URLSearchParams(window.location.search).get("module");
    let module = !requestedModule || requestedModule === "Workspace" ? (requestedModule || "All") : "Workspace";

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
      button.addEventListener("click", function (event) {
        event.preventDefault();
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
    const exportTrigger = document.getElementById("cp-open-wiki-export");
    const exportDialog = document.getElementById("cp-wiki-export-dialog");
    if (exportTrigger && exportDialog && typeof exportDialog.showModal === "function") {
      exportTrigger.addEventListener("click", function () { exportDialog.showModal(); });
      exportDialog.addEventListener("click", function (event) {
        if (event.target === exportDialog) exportDialog.close();
      });
    }
    filter();
  }

  function setupArticle() {
    const copy = document.getElementById("cp-copy-article");
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
      profile.textContent = "You";
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
      if (!raw || /[\u0000-\u0020\u007f\\]/.test(raw)) return "#";
      try {
        if (raw.startsWith("/") && !raw.startsWith("//")) return raw;
        const url = new URL(raw, window.location.origin);
        if (url.protocol === "http:" || url.protocol === "https:") return url.href;
      } catch (_) {}
      return "#";
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

      const citationList = Array.isArray(citations) ? citations : [];
      if (citationList.length) {
        const citationRow = document.createElement("div");
        citationRow.className = "answer-citations";
        citationList.slice(0, 3).forEach(function (citation, index) {
          const link = document.createElement("a");
          link.className = "citation";
          link.href = safeCitationUrl(citation.url || "");
          link.target = "_blank";
          link.rel = "noopener noreferrer";
          const number = document.createElement("span");
          number.textContent = String(index + 1);
          const citationText = (citation.title || "Source") + (citation.snippet ? " — " + citation.snippet : "");
          link.append(number, document.createTextNode(citationText));
          citationRow.appendChild(link);
        });
        content.appendChild(citationRow);
      }

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
      footer.append(prompt, useful, needsWork);
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
        const endpoint = form.dataset.endpoint || "/api/chat";
        const response = await fetch(endpoint, {
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

    syncModule();
    syncSend();
  }

  function setupFlashcards() {
    const review = document.getElementById("cp-flash-review");
    const flashcard = document.getElementById("cp-flashcard");
    const details = document.getElementById("cp-card-details");
    const revealButton = document.getElementById("cp-reveal-card");
    const answer = document.getElementById("cp-card-answer");
    const ratingPanel = document.getElementById("cp-rating-panel");
    const hint = document.getElementById("cp-review-hint");
    if (!review || !flashcard || !details || !revealButton || !answer || !ratingPanel) return;

    const cards = Array.from(document.querySelectorAll("#cp-flash-data [data-card-id]"));
    const ratingForms = Array.from(document.querySelectorAll("form[data-flash-rate]"));
    let index = 0;
    let reviewed = Number((document.getElementById("cp-reviewed-count") || {}).textContent || 0);
    let revealed = false;
    let submitting = false;
    let attemptStatus = null;

    details.style.display = "contents";
    flashcard.insertAdjacentElement("afterend", ratingPanel);

    document.querySelectorAll("[data-deck-url]").forEach(function (button) {
      button.addEventListener("click", function () {
        window.location.href = button.dataset.deckUrl;
      });
    });

    function setRevealed(next) {
      revealed = next;
      details.open = next;
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
      reviewed += 1;
      index = cards.length ? (index + 1) % cards.length : 0;
      updateEvidence();
      renderCurrent();
    }

    function showFailure(message) {
      if (!attemptStatus) {
        attemptStatus = document.createElement("div");
        attemptStatus.className = "cp-status-banner cp-status-error";
        attemptStatus.setAttribute("role", "alert");
        ratingPanel.insertAdjacentElement("beforebegin", attemptStatus);
      }
      attemptStatus.textContent = message;
      attemptStatus.hidden = false;
    }

    function setSubmitting(next) {
      submitting = next;
      ratingForms.forEach(function (form) {
        const button = form.querySelector('button[type="submit"]');
        if (button) button.disabled = next;
      });
    }

    revealButton.addEventListener("click", function (event) {
      event.preventDefault();
      setRevealed(true);
    });
    ratingForms.forEach(function (form) {
      form.addEventListener("submit", async function (event) {
        event.preventDefault();
        if (!revealed || submitting) return;
        if (attemptStatus) attemptStatus.hidden = true;
        setSubmitting(true);
        try {
          const response = await fetch(form.action, { method: "POST", body: new FormData(form) });
          if (response.status === 401) {
            throw new Error("unauthorized");
          }
          if (!response.ok) {
            throw new Error("request failed");
          }
          if (response.redirected) {
            const destination = new URL(response.url, window.location.href);
            if (destination.pathname === "/login") {
              throw new Error("unauthorized");
            }
            if (destination.searchParams.get("attempt") !== "saved") {
              throw new Error("save failed");
            }
          }
          rate();
        } catch (error) {
          const message = error && error.message === "unauthorized"
            ? "Your session has expired. This answer was not recorded; sign in and try again."
            : "Practice result could not be saved. This card is still open and your answer was not recorded; try again.";
          showFailure(message);
        } finally {
          setSubmitting(false);
        }
      });
    });

    document.addEventListener("keydown", function (event) {
      const target = event.target;
      if (target && /INPUT|TEXTAREA|SELECT/.test(target.tagName)) return;
      if (event.code === "Space") {
        event.preventDefault();
        if (!revealed) setRevealed(true);
      } else if (revealed && !submitting && /^[1-4]$/.test(event.key)) {
        const form = ratingForms[Number(event.key) - 1];
        if (!form) return;
        event.preventDefault();
        form.requestSubmit();
      }
    });
    renderCurrent();
  }
})();
