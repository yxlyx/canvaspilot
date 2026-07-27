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
  setupFlashcardWorkspace();
  setupDraftReview();
  setupFlashcards();
  setupDashboard();
  setupSources();
  setupProcessing();
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

    const focusedSource = grid.querySelector(".document-card.is-focused[data-source-id]");
    if (focusedSource) {
      focusedSource.scrollIntoView({ block: "center" });
      focusedSource.focus({ preventScroll: true });
      focusedSource.querySelector("[data-source-preview]")?.click();
    }

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

    let selectedFiles = [];
    const maxFileBytes = 10 * 1024 * 1024;
    const maxTextCharacters = 2000000;
    const textContents = new WeakMap();
    const textReads = new WeakMap();
    const textProblems = new WeakMap();
    function sourceType(file) {
      const name = file.name.toLowerCase();
      if (file.type === "application/pdf" || name.endsWith(".pdf")) return "pdf";
      if (file.type === "image/png" || file.type === "image/jpeg" || /\.(png|jpe?g)$/.test(name)) return "image";
      if (file.type === "text/markdown" || name.endsWith(".md")) return "markdown";
      if (file.type === "text/plain" || name.endsWith(".txt")) return "plain_text";
      return "";
    }
    function isTextFile(file) {
      const type = sourceType(file);
      return type === "markdown" || type === "plain_text";
    }
    function textExceedsLimit(text) {
      let characters = 0;
      for (const _character of text) {
        characters += 1;
        if (characters > maxTextCharacters) return true;
      }
      return false;
    }

    const addForm = document.getElementById("cp-add-source-form");
    const sourceParams = new URLSearchParams(window.location.search);
    const legacySourceScope = sourceParams.get("module_scope");
    const sourceEnrollmentId = addForm ? (sourceParams.get("enrollment_id") || legacySourceScope) : null;
    const sourceTopicId = addForm ? sourceParams.get("topic_id") : null;
    if (addForm) {
      const modeInput = addForm.elements.mode;
      const fileInput = document.getElementById("cp-source-files");
      const dropZone = addForm.querySelector(".source-drop-zone");
      const fileList = addForm.querySelector(".source-file-list");
      const modeButtons = Array.from(addModal.querySelectorAll("[data-source-mode]"));
      const panels = Array.from(addModal.querySelectorAll("[data-source-panel]"));
      function fileProblem(file) {
        if (!sourceType(file)) return "Unsupported format";
        if (!file.size) return "Empty file";
        if (file.size > maxFileBytes) return "Over 10 MiB";
        if (isTextFile(file)) return textProblems.get(file) || "Checking text length…";
        return "Ready to import";
      }
      function readText(file) {
        let pending = textReads.get(file);
        if (!pending) {
          pending = file.text().then(function (content) {
            textContents.set(file, content);
            return content;
          });
          textReads.set(file, pending);
        }
        return pending;
      }
      async function inspectTextFiles(files) {
        for (const file of files) {
          if (!isTextFile(file) || !file.size || file.size > maxFileBytes) continue;
          try {
            const content = await readText(file);
            textProblems.set(file, textExceedsLimit(content) ? "Over 2,000,000 characters" : "Ready to import");
          } catch (_) {
            textProblems.set(file, "Could not read file");
          }
        }
        if (files.length === selectedFiles.length && files.every(function (file, index) { return file === selectedFiles[index]; })) {
          showFiles(files);
        }
      }

      function setMode(mode) {
        modeInput.value = mode;
        modeButtons.forEach(function (button) {
          const active = button.dataset.sourceMode === mode;
          button.setAttribute("aria-selected", String(active));
          button.tabIndex = active ? 0 : -1;
        });
        panels.forEach(function (panel) { panel.hidden = panel.dataset.sourcePanel !== mode; });
        if (fileInput) fileInput.required = mode === "upload";
        const urlInput = document.getElementById("cp-new-source-url");
        const contentInput = document.getElementById("cp-source-content");
        if (urlInput) urlInput.required = mode === "link";
        if (contentInput) contentInput.required = mode === "paste";
      }

      function showFiles(files) {
        if (!fileList) return;
        const statusNode = addForm.querySelector(".cp-form-status");
        if (statusNode) statusNode.textContent = "";
        fileList.replaceChildren();
        Array.from(files || []).forEach(function (file) {
          const item = document.createElement("li");
          const size = file.size < 1024 * 1024 ? Math.max(1, Math.round(file.size / 1024)) + " KB" : (file.size / (1024 * 1024)).toFixed(1) + " MB";
          const problem = fileProblem(file);
          item.classList.toggle("invalid", !["Ready to import", "Checking text length…"].includes(problem));
          item.innerHTML = "<span><strong></strong><small></small></span><button type=\"button\">Remove</button>";
          item.querySelector("strong").textContent = file.name;
          item.querySelector("small").textContent = [sourceType(file) ? sourceType(file).replace("_", " ") : "unknown type", size, problem].join(" · ");
          item.querySelector("button").setAttribute("aria-label", "Remove " + file.name);
          item.querySelector("button").addEventListener("click", function () {
            selectedFiles = selectedFiles.filter(function (selected) { return selected !== file; });
            showFiles(selectedFiles);
            if (fileInput && typeof DataTransfer !== "undefined") {
              const transfer = new DataTransfer();
              selectedFiles.forEach(function (selected) { transfer.items.add(selected); });
              fileInput.files = transfer.files;
            }
          });
          fileList.appendChild(item);
        });
      }

      modeButtons.forEach(function (button, index) {
        button.addEventListener("click", function () { setMode(button.dataset.sourceMode); });
        button.addEventListener("keydown", function (event) {
          if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
          event.preventDefault();
          const offset = event.key === "ArrowRight" ? 1 : -1;
          const next = modeButtons[(index + offset + modeButtons.length) % modeButtons.length];
          setMode(next.dataset.sourceMode);
          next.focus();
        });
      });
      if (fileInput) fileInput.addEventListener("change", function () {
        selectedFiles = Array.from(fileInput.files || []);
        showFiles(selectedFiles);
        void inspectTextFiles(selectedFiles);
      });
      if (dropZone) {
        ["dragenter", "dragover"].forEach(function (name) { dropZone.addEventListener(name, function (event) { event.preventDefault(); dropZone.classList.add("dragging"); }); });
        ["dragleave", "drop"].forEach(function (name) { dropZone.addEventListener(name, function (event) { event.preventDefault(); dropZone.classList.remove("dragging"); }); });
        dropZone.addEventListener("drop", function (event) {
          if (!fileInput || !event.dataTransfer.files.length) return;
          selectedFiles = Array.from(event.dataTransfer.files);
          if (typeof DataTransfer !== "undefined") {
            const transfer = new DataTransfer();
            selectedFiles.forEach(function (selected) { transfer.items.add(selected); });
            fileInput.files = transfer.files;
          }
          showFiles(selectedFiles);
          void inspectTextFiles(selectedFiles);
        });
      }
      window.addEventListener("dragover", function (event) {
        const overDropZone = event.target instanceof Element && event.target.closest(".source-drop-zone");
        if (!addModal.hidden && !overDropZone) event.preventDefault();
      });
      window.addEventListener("drop", function (event) {
        const overDropZone = event.target instanceof Element && event.target.closest(".source-drop-zone");
        if (!addModal.hidden && !overDropZone) event.preventDefault();
      });
      setMode("upload");
    }
    if (addForm) addForm.addEventListener("submit", async function (event) {
      event.preventDefault();
      const statusNode = addForm.querySelector(".cp-form-status");
      const submit = addForm.querySelector('button[type="submit"]');
      const mode = addForm.elements.mode.value;
      const rawTitle = ((document.getElementById("cp-new-source-title") || {}).value || "").trim();
      const courseContext = (document.getElementById("cp-new-source-module") || {}).value || "";
      if (submit) submit.disabled = true;
      if (statusNode) statusNode.textContent = mode === "upload" ? "Reading files securely…" : "Adding source…";
      function base64(bytes) {
        let encoded = "";
        for (let offset = 0; offset < bytes.length; offset += 0x8000) encoded += String.fromCharCode.apply(null, bytes.subarray(offset, offset + 0x8000));
        return btoa(encoded);
      }
      function importError(message) {
        const raw = String(message || "");
        if (/missing credentials|openai_api_key|workload_identity|admin_api_key/i.test(raw)) {
          return "Indexing is not configured yet. Ask the workspace owner to connect the search service, then retry.";
        }
        return raw || "The document could not be parsed.";
      }
      function intakeKey() {
        if (window.crypto && typeof window.crypto.randomUUID === "function") return "source-" + window.crypto.randomUUID();
        const bytes = new Uint8Array(16);
        window.crypto.getRandomValues(bytes);
        return "source-" + Array.from(bytes, function (value) { return value.toString(16).padStart(2, "0"); }).join("");
      }
      async function send(payload, idempotencyKey) {
        if (sourceEnrollmentId) payload.enrollment_id = sourceEnrollmentId;
        let response;
        for (let attempt = 0; attempt < 2; attempt += 1) {
          try {
            response = await fetch(addForm.action, {
              method: "POST",
              headers: { "Content-Type": "application/json", "Idempotency-Key": idempotencyKey },
              credentials: "same-origin",
              body: JSON.stringify(payload),
            });
            break;
          } catch (error) {
            if (attempt === 1) throw error;
          }
        }
        if (!response || !response.ok) {
          let message = response && response.status === 401 ? "Your session has expired. Sign in and try again." : "The source could not be queued.";
          try { const data = await response.json(); message = data.detail || data.error || message; } catch (_) {}
          throw new Error(message);
        }
        return response.json();
      }
      try {
        let results = [];
        if (mode === "upload") {
          const files = selectedFiles.length ? selectedFiles : Array.from((document.getElementById("cp-source-files") || {}).files || []);
          if (!files.length) throw new Error("Choose at least one PDF, PNG, JPEG, Markdown, or text file.");
          files.forEach(function (file) {
            const type = sourceType(file);
            if (!type) throw new Error(file.name + " is not a PDF, PNG, JPEG, Markdown, or text file.");
            if (!file.size) throw new Error(file.name + " is empty.");
            if (file.size > maxFileBytes) throw new Error(file.name + " exceeds the 10 MiB file limit.");
          });
          for (const file of files) {
            if (!isTextFile(file)) continue;
            let content;
            try {
              content = await readText(file);
            } catch (_) {
              throw new Error(file.name + " could not be read.");
            }
            if (textExceedsLimit(content)) throw new Error(file.name + " exceeds the 2,000,000 character text limit.");
          }
          const failures = [];
          for (let index = 0; index < files.length; index += 1) {
            const file = files[index];
            const type = sourceType(file);
            if (statusNode) statusNode.textContent = "Importing " + (index + 1) + " of " + files.length + " · " + file.name;
            const title = rawTitle && files.length === 1 ? rawTitle : file.name.replace(/\.(pdf|png|jpe?g|md|txt)$/i, "");
            const payload = { mode: "upload", title, course_context: courseContext.trim() || null, source_type: type, filename: file.name };
            if (type === "pdf" || type === "image") {
              payload.content_base64 = base64(new Uint8Array(await file.arrayBuffer()));
            } else {
              payload.content = textContents.get(file) || await readText(file);
            }
            try {
              results.push(await send(payload, intakeKey()));
            } catch (error) {
              failures.push(file.name + ": " + (error && error.message ? error.message : "Import failed"));
            }
          }
          if (failures.length) {
            const imported = results.length ? results.length + (results.length === 1 ? " file imported. " : " files imported. ") : "";
            throw new Error(imported + failures.join(" "));
          }
        } else if (mode === "link") {
          const url = (document.getElementById("cp-new-source-url") || {}).value || "";
          if (!url.trim()) throw new Error("Enter a public link.");
          let title = rawTitle;
          if (!title) { try { title = new URL(url).hostname.replace(/^www\./, ""); } catch (_) {} }
          results.push(await send({ mode: "link", title: title || "Reference link", course_context: courseContext.trim() || null, source_type: "link", source_url: url.trim() }, intakeKey()));
        } else {
          const content = (document.getElementById("cp-source-content") || {}).value || "";
          const type = (document.getElementById("cp-paste-format") || {}).value || "plain_text";
          if (!rawTitle) throw new Error("Give the pasted notes a clear title.");
          if (!content.trim()) throw new Error("Paste some notes to import.");
          results.push(await send({ mode: "paste", title: rawTitle, course_context: courseContext.trim() || null, source_type: type, content }, intakeKey()));
        }
        const duplicates = results.filter(function (item) { return item.duplicate; }).length;
        const states = results.map(function (item) { return item.import_status || "queued"; });
        const importState = states.includes("failed") ? "failed" : states.includes("paused") ? "paused" : states.includes("running") ? "running" : states.includes("queued") ? "queued" : states.every(function (state) { return state === "saved"; }) ? "saved" : "completed";
        if (statusNode) statusNode.textContent = (importState === "saved" ? "Bookmark metadata saved. No processing was started" : "Source accepted. Persisted state: " + importState) + (duplicates ? " · " + duplicates + " replayed existing run" : "") + ".";
        window.setTimeout(function () {
          const importedSourceId = results.length === 1 && results[0].source ? results[0].source.id : null;
          const importedRunId = results.length === 1 ? results[0].job_id : null;
          const next = new URL(sourceEnrollmentId && sourceTopicId ? "/learning/" + sourceEnrollmentId : "/sources", window.location.origin);
          next.searchParams.set("import", importState);
          if (importedSourceId) next.searchParams.set("source", importedSourceId);
          if (importedRunId) {
            next.searchParams.set("run", importedRunId);
            next.hash = "processing";
          }
          if (sourceEnrollmentId && sourceTopicId) {
            next.searchParams.set("topic_id", sourceTopicId);
            if (importedSourceId) next.searchParams.set("review_source", importedSourceId);
          } else if (sourceEnrollmentId) {
            next.searchParams.set(legacySourceScope ? "module_scope" : "enrollment_id", sourceEnrollmentId);
          }
          window.location.assign(next.pathname + next.search + next.hash);
        }, 650);
      } catch (error) {
        if (statusNode) statusNode.textContent = error && error.message ? error.message : "The source could not be imported.";
        if (submit) submit.disabled = false;
      }
    });

    applyFilters();
  }

  function setupProcessing() {
    const panel = document.querySelector("[data-processing-panel]");
    if (!panel) return;
    const errorNode = panel.querySelector("[data-processing-error]");
    let delay = 1500;
    let timer = 0;
    let stopped = false;

    function key() {
      return "processing-" + (window.crypto && window.crypto.randomUUID ? window.crypto.randomUUID() : Date.now() + "-" + Math.random().toString(16).slice(2));
    }
    async function request(envelope) {
      const response = await fetch("/api/processing", {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify(envelope),
      });
      if (!response.ok) {
        let message = "Processing status could not be refreshed.";
        try { const body = await response.json(); message = body.detail?.message || body.detail || body.error || message; } catch (_) {}
        throw new Error(message);
      }
      return response.json();
    }
    function activeRuns() {
      return Array.from(panel.querySelectorAll("[data-processing-run]")).filter(function (run) {
        return run.dataset.runStatus === "queued" || run.dataset.runStatus === "running";
      });
    }
    function apply(run) {
      const node = panel.querySelector('[data-processing-run="' + CSS.escape(run.id) + '"]');
      if (!node) return;
      const previous = node.dataset.runStatus;
      node.dataset.runStatus = run.status;
      const pill = node.querySelector("header .status-pill");
      if (pill) {
        pill.textContent = run.status === "ready" ? "completed" : run.status;
        pill.className = "status-pill status-" + (run.status === "ready" ? "good" : run.status === "failed" || run.status === "cancelled" ? "warn" : "info");
      }
      (run.stages || []).forEach(function (stage) {
        const item = node.querySelector('[data-stage="' + CSS.escape(stage.name) + '"]');
        if (!item) return;
        item.dataset.status = stage.status;
        const spans = item.querySelectorAll("span");
        if (spans[0]) spans[0].textContent = "Status: " + stage.status;
        if (spans[1]) spans[1].textContent = (stage.completed_at || stage.started_at || stage.available_at) + " · attempt " + stage.attempt_count + " of " + stage.max_attempts;
      });
      if ((run.status === "ready" || run.status === "failed" || run.status === "cancelled" || run.status === "paused") && previous !== run.status) {
        stopped = true;
        window.location.reload();
      }
    }
    async function poll() {
      window.clearTimeout(timer);
      if (stopped || document.hidden) return;
      const runs = activeRuns();
      if (!runs.length) return;
      try {
        const values = await Promise.all(runs.map(function (node) { return request({ action: "run.status", id: node.dataset.processingRun }); }));
        values.forEach(apply);
        delay = Math.min(Math.round(delay * 1.5), 15000);
        if (errorNode) errorNode.hidden = true;
      } catch (error) {
        delay = Math.min(delay * 2, 30000);
        if (errorNode) {
          errorNode.textContent = (error && error.message ? error.message : "Processing status could not be refreshed.") + " Existing timeline and source content are preserved.";
          errorNode.hidden = false;
        }
      }
      timer = window.setTimeout(poll, delay);
    }
    panel.addEventListener("click", async function (event) {
      const button = event.target.closest("[data-processing-action]");
      if (!button || button.disabled) return;
      if (button.dataset.processingAction === "run.cancel" && !window.confirm("Cancel this active processing run? Completed outputs will remain available.")) return;
      button.disabled = true;
      button.setAttribute("aria-busy", "true");
      try {
        const run = await request({ action: button.dataset.processingAction, id: button.dataset.runId, idempotency_key: key(), payload: {} });
        apply(run);
        if (!stopped) window.location.reload();
      } catch (error) {
        if (errorNode) {
          errorNode.textContent = error && error.message ? error.message : "The run could not be changed.";
          errorNode.hidden = false;
          errorNode.focus();
        }
        button.disabled = false;
      } finally {
        button.removeAttribute("aria-busy");
      }
    });
    document.querySelectorAll("[data-manual-processing-trigger]").forEach(function (button) {
      button.addEventListener("click", async function () {
        const status = button.parentElement && button.parentElement.querySelector(".cp-form-status");
        button.disabled = true;
        if (status) status.textContent = "Queueing rebuild…";
        try {
          const run = await request({ action: "manual.trigger", idempotency_key: key(), payload: { source_id: button.dataset.sourceId } });
          if (status) status.textContent = "Rebuild queued. Run " + run.id + ". The current Wiki remains available.";
          window.setTimeout(function () { window.location.reload(); }, 500);
        } catch (error) {
          if (status) {
            status.textContent = error && error.message ? error.message : "The rebuild could not be queued.";
            status.setAttribute("role", "alert");
            status.focus();
          }
          button.disabled = false;
        }
      });
    });
    document.addEventListener("visibilitychange", function () {
      window.clearTimeout(timer);
      if (!document.hidden) {
        delay = 1500;
        poll();
      }
    });
    poll();
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
    let requestGeneration = 0;

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
        citationList.forEach(function (citation, index) {
          const link = document.createElement("a");
          link.className = "citation";
          const citationUrl = citation.source_id
            ? "/sources?source=" + encodeURIComponent(citation.source_id)
              + (moduleSelect && moduleSelect.value ? "&enrollment_id=" + encodeURIComponent(moduleSelect.value) : "")
            : citation.url || "";
          link.href = safeCitationUrl(citationUrl);
          link.target = "_blank";
          link.rel = "noopener noreferrer";
          const number = document.createElement("span");
          const referenceNumber = Number.isInteger(citation.reference_number) && citation.reference_number > 0
            ? citation.reference_number
            : index + 1;
          number.textContent = String(referenceNumber);
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
      const generation = requestGeneration += 1;
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
            enrollment_id: moduleSelect && moduleSelect.value ? moduleSelect.value : null,
            history: priorHistory,
          }),
        });
        if (!response.ok) throw new Error("HTTP " + response.status);
        const data = await response.json();
        if (generation !== requestGeneration) return;
        pending.remove();
        const reply = data.message || "No grounded answer was returned.";
        appendAnswer(reply, data.citations);
        history.push({ role: "assistant", content: reply });
        input.value = "";
      } catch (error) {
        if (generation !== requestGeneration) return;
        pending.remove();
        history.length = 0;
        history.push.apply(history, priorHistory);
        appendError("The retrieval step could not complete. Your question is still here, so you can retry safely.", message);
        lastFailedMessage = message;
        input.value = message;
      } finally {
        if (generation === requestGeneration) {
          loading = false;
          input.disabled = false;
          syncSend();
          input.focus();
          log.scrollTop = log.scrollHeight;
        }
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
    if (moduleSelect) moduleSelect.addEventListener("change", function () {
      requestGeneration += 1;
      loading = false;
      lastFailedMessage = null;
      log.querySelectorAll(".chat-dynamic").forEach(function (turn) { turn.remove(); });
      history.length = 0;
      input.value = "";
      input.disabled = false;
      syncModule();
      syncSend();
      if (welcome) welcome.hidden = false;
      if (clearButton) clearButton.disabled = true;
    });
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      const message = input.value.trim();
      if (!message || loading) return;
      sendMessage(message, true);
    });
    if (clearButton) {
      clearButton.addEventListener("click", function () {
        requestGeneration += 1;
        loading = false;
        lastFailedMessage = null;
        log.querySelectorAll(".chat-dynamic").forEach(function (turn) { turn.remove(); });
        history.length = 0;
        input.disabled = false;
        syncSend();
        if (welcome) welcome.hidden = false;
        clearButton.disabled = true;
      });
    }

    syncModule();
    syncSend();
  }

  function flashKey(prefix) {
    if (window.crypto && window.crypto.randomUUID) return prefix + "-" + window.crypto.randomUUID();
    return prefix + "-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
  }

  async function flashRequest(action, options) {
    options = options || {};
    const response = await fetch("/api/flashcards", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({
        action: action,
        deck_id: options.deckId || null,
        card_id: options.cardId || null,
        expected_revision: options.revision || null,
        idempotency_key: options.key || flashKey(action),
        payload: options.payload === undefined ? null : options.payload,
      }),
    });
    let body = null;
    try { body = await response.json(); } catch (_) {}
    if (!response.ok) {
      const error = new Error(response.status === 409 ? "revision-conflict" : "request-failed");
      error.status = response.status;
      error.body = body;
      throw error;
    }
    return body;
  }

  function setupFlashcardWorkspace() {
    const area = document.querySelector("[data-flash-create]");
    if (!area) return;
    const form = area.querySelector("form");
    const status = area.querySelector("[data-flash-create-status]");
    const effective = area.querySelector("[data-scope-effective]");
    if (!form || form.querySelector("fieldset:disabled")) return;
    const enrollment = form.elements.enrollment_id;
    const topics = form.elements.topic_ids;
    const chunks = form.elements.source_chunk_ids;
    const createRecoveryKey = "flashcard-create-recovery";
    let createRecovery = null;

    function snapshotCreateForm() {
      const values = {};
      Array.from(form.elements).forEach(function (control) {
        if (!control.name || ((control.type === "radio" || control.type === "checkbox") && !control.checked)) return;
        values[control.name] = control.multiple
          ? Array.from(control.selectedOptions).map(function (option) { return option.value; })
          : control.value;
      });
      return values;
    }

    function applyCreateRecovery() {
      if (!createRecovery) return;
      Object.keys(createRecovery).forEach(function (name) {
        const control = form.elements[name];
        if (!control) return;
        if (control instanceof RadioNodeList) {
          Array.from(control).forEach(function (item) { item.checked = item.value === createRecovery[name]; });
        } else if (control.multiple && Array.isArray(createRecovery[name])) {
          Array.from(control.options).forEach(function (option) { option.selected = createRecovery[name].includes(option.value); });
        } else if (control.type === "checkbox") {
          control.checked = Boolean(createRecovery[name]);
        } else {
          control.value = createRecovery[name];
        }
      });
    }

    try {
      createRecovery = JSON.parse(sessionStorage.getItem(createRecoveryKey) || "null");
      applyCreateRecovery();
    } catch (_) { createRecovery = null; }

    async function loadChunks() {
      const topic = form.elements.chunk_topic_id;
      const source = form.elements.chunk_source_id;
      chunks.innerHTML = "";
      if (!enrollment.value || !topic.value || !source.value) return;
      const records = await flashRequest("chunks", { deckId: enrollment.value, payload: { topic_id: topic.value, source_id: source.value } });
      records.slice(0, 100).forEach(function (record) { chunks.add(new Option(record.citation + " · " + (record.excerpt || "current evidence"), record.chunk_id)); });
      applyCreateRecovery();
    }

    async function loadEnrollmentScope() {
      if (!enrollment || !enrollment.value) return;
      try {
        const loadedTopics = await flashRequest("topics", { deckId: enrollment.value });
        topics.innerHTML = "";
        loadedTopics.filter(function (topic) { return !topic.archived; }).slice(0, 100).forEach(function (topic) {
          topics.add(new Option(topic.title + " · " + topic.provenance, topic.id));
        });
        const chunkTopic = form.elements.chunk_topic_id;
        chunkTopic.innerHTML = topics.innerHTML;
        const candidates = await flashRequest("candidates", { deckId: enrollment.value });
        const chunkSource = form.elements.chunk_source_id;
        chunkSource.innerHTML = "";
        candidates.filter(function (source) { return source.eligible && source.state === "ready"; }).slice(0, 100).forEach(function (source) {
          chunkSource.add(new Option(source.title, source.id));
        });
        applyCreateRecovery();
        await loadChunks();
      } catch (_) {
        status.textContent = "Canonical topics or current chunks could not be loaded. Other stable scopes remain available.";
      }
    }
    enrollment.addEventListener("change", loadEnrollmentScope);
    form.elements.chunk_topic_id.addEventListener("change", function () { loadChunks().catch(function () { status.textContent = "Current chunks could not be loaded."; }); });
    form.elements.chunk_source_id.addEventListener("change", function () { loadChunks().catch(function () { status.textContent = "Current chunks could not be loaded."; }); });
    loadEnrollmentScope();

    function syncScope() {
      const selected = form.querySelector('[name="scope_type"]:checked:not(:disabled)');
      const scope = selected ? selected.value : "";
      form.querySelectorAll("[data-scope]").forEach(function (node) {
        const activeScopes = node.dataset.scope.split(/\s+/);
        const active = activeScopes.includes(scope);
        node.hidden = !active;
        node.querySelectorAll("input, select, textarea, button").forEach(function (control) {
          control.disabled = !active;
          control.required = active && (control.name === scope || control.name === "enrollment_id");
        });
      });
      const label = selected && selected.nextElementSibling ? selected.nextElementSibling.textContent.trim() : "No available material";
      effective.textContent = selected ? label + " will be used as the only generation scope." : "Process a source or create a Wiki page to continue.";
      form.querySelector('button[type="submit"]').disabled = !selected;
    }
    form.addEventListener("change", syncScope);
    syncScope();
    form.addEventListener("submit", async function (event) {
      event.preventDefault();
      const scope = form.querySelector('[name="scope_type"]:checked').value;
      const control = form.elements[scope];
      const values = control && control.multiple ? Array.from(control.selectedOptions).map(function (option) { return option.value; }) : [control && control.value].filter(Boolean);
      if (!values.length) { status.textContent = "Select at least one item in the visible scope."; return; }
      if (form.elements.regenerate.checked && !window.confirm("Regenerate creates a linked successor draft. The current matching draft remains in history. Continue?")) return;
      const payload = { limit: Number(form.elements.limit.value), regenerate: form.elements.regenerate.checked };
      if (form.elements.deck_title.value.trim()) payload.deck_title = form.elements.deck_title.value.trim();
      payload[scope] = control.multiple ? values : values[0];
      form.querySelector('button[type="submit"]').disabled = true;
      status.textContent = "Creating or replaying the review draft…";
      try {
        const result = await flashRequest("generate", { payload: payload });
        if (!result.deck) throw new Error("request-failed");
        try { sessionStorage.removeItem(createRecoveryKey); } catch (_) {}
        window.location.href = "/flashcards/drafts/" + encodeURIComponent(result.deck.id);
      } catch (error) {
        const code = error.body && error.body.error;
        const providerIssue = ["provider_not_configured", "credential_unavailable", "reauth_required", "provider_authentication_failed", "provider_unavailable", "local_codex_unavailable", "local_codex_login_required"].includes(code);
        if (error.status === 401) {
          createRecovery = snapshotCreateForm();
          try { sessionStorage.setItem(createRecoveryKey, JSON.stringify(createRecovery)); } catch (_) {}
          status.textContent = "Your session expired. This scope is saved in this browser. ";
          const loginLink = document.createElement("a");
          loginLink.href = "/login";
          loginLink.textContent = "Sign in, then return to Create";
          status.appendChild(loginLink);
        } else {
          status.textContent = providerIssue
            ? "Connect or reconnect an answer provider before generating this draft. Your scope selection is preserved. "
            : "The draft could not be created. Your scope selection is preserved; try again.";
        }
        if (providerIssue && error.status !== 401) {
          const settingsLink = document.createElement("a");
          settingsLink.href = "/settings/providers";
          settingsLink.textContent = "Open provider settings";
          status.appendChild(settingsLink);
        }
        form.querySelector('button[type="submit"]').disabled = false;
      }
    });
  }

  function setupDraftReview() {
    const page = document.querySelector("[data-draft-review]");
    if (!page) return;
    let revision = Number(page.dataset.revision);
    const deckId = page.dataset.deckId;
    const status = page.querySelector("[data-draft-status]");
    const editable = page.dataset.lifecycle === "draft";
    let pending = false;
    const dirtyForms = new Set();
    const recoveryKey = "flashcard-draft-reapply-" + deckId;
    let recoveryState = null;
    try {
      recoveryState = JSON.parse(sessionStorage.getItem(recoveryKey) || "null");
      if (recoveryState && editable) {
        page.querySelectorAll("form[data-recovery-key]").forEach(function (form) {
          const values = recoveryState[form.dataset.recoveryKey] || {};
          Object.keys(values).forEach(function (name) {
            const control = form.elements[name];
            if (!control) return;
            if (control instanceof RadioNodeList) Array.from(control).forEach(function (item) { item.checked = item.value === values[name]; });
            else control.value = values[name];
          });
          if (Object.keys(values).length) dirtyForms.add(form);
        });
        status.className = "cp-status-banner cp-status-info";
        status.textContent = "Latest revision loaded. Your local field edits were reapplied; review and save them.";
      } else if (recoveryState) {
        sessionStorage.removeItem(recoveryKey);
        recoveryState = null;
      }
    } catch (_) { recoveryState = null; }
    function ids(approvableOnly) {
      return Array.from(page.querySelectorAll("[data-card-id]"))
        .filter(function (card) { return !approvableOnly || card.dataset.approvable === "true"; })
        .map(function (card) { return card.dataset.cardId; });
    }
    function syncBulkApproval() {
      const button = page.querySelector("[data-approve-selected]");
      if (button) button.disabled = !page.querySelector("[data-card-select]:checked") || dirtyForms.size > 0;
    }
    page.querySelectorAll("form[data-recovery-key]").forEach(function (form) {
      form.addEventListener("input", function () { dirtyForms.add(form); syncBulkApproval(); });
      form.addEventListener("change", function () { dirtyForms.add(form); syncBulkApproval(); });
    });
    page.addEventListener("change", function (event) {
      if (event.target.matches("[data-card-select]")) syncBulkApproval();
    });
    syncBulkApproval();
    window.addEventListener("beforeunload", function (event) {
      if (!dirtyForms.size) return;
      event.preventDefault();
      event.returnValue = "";
    });
    function snapshotForm(form) {
      const values = {};
      Array.from(form.elements).forEach(function (control) {
        if (!control.name || ((control.type === "radio" || control.type === "checkbox") && !control.checked)) return;
        values[control.name] = control.value;
      });
      return values;
    }
    function persistDirtyForms(exclude) {
      const snapshot = Object.assign({}, recoveryState || {});
      if (exclude && exclude.dataset.recoveryKey) delete snapshot[exclude.dataset.recoveryKey];
      dirtyForms.forEach(function (form) {
        if (form === exclude) return;
        snapshot[form.dataset.recoveryKey] = snapshotForm(form);
      });
      recoveryState = snapshot;
      try {
        if (Object.keys(snapshot).length) sessionStorage.setItem(recoveryKey, JSON.stringify(snapshot));
        else sessionStorage.removeItem(recoveryKey);
      } catch (_) {}
    }
    function conflict() {
      status.className = "cp-status-banner cp-status-error";
      status.innerHTML = "This draft changed elsewhere. Your unsaved fields remain on this page. <button type=\"button\" data-conflict-reload>Reload latest and reapply my edits</button>";
      status.querySelector("button").addEventListener("click", function () {
        persistDirtyForms(null);
        dirtyForms.clear();
        window.location.reload();
      });
    }
    async function mutate(action, payload, cardId) {
      if (pending) return null;
      pending = true;
      status.textContent = "Saving…";
      try {
        const result = await flashRequest(action, { deckId: deckId, cardId: cardId, revision: revision, payload: payload });
        revision = result.revision || revision + 1;
        page.dataset.revision = String(revision);
        status.className = "cp-status-banner cp-status-info";
        status.textContent = "Saved at revision " + revision + ".";
        return result;
      } catch (error) {
        if (error.status === 409) conflict();
        else if (error.status === 401) {
          persistDirtyForms(null);
          status.className = "cp-status-banner cp-status-error";
          status.innerHTML = "Your session expired. Local edits are saved in this browser. <a href=\"/login\">Sign in, then return to this draft</a>.";
        } else {
          status.className = "cp-status-banner cp-status-error";
          status.textContent = "The change was not saved. Your local edits are preserved; try again.";
        }
        return null;
      } finally { pending = false; }
    }
    const deckForm = page.querySelector("[data-deck-form]");
    if (deckForm) deckForm.addEventListener("submit", async function (event) {
      event.preventDefault();
      if (await mutate("update_deck", { title: deckForm.elements.title.value.trim() })) {
        dirtyForms.delete(deckForm);
        persistDirtyForms(deckForm);
        dirtyForms.clear();
        window.location.reload();
      }
    });
    page.querySelectorAll("[data-card-form]").forEach(function (form) {
      form.addEventListener("submit", async function (event) {
        event.preventDefault();
        const card = form.closest("[data-card-id]");
        const personal = form.elements.evidence_kind.value === "personal";
        const citationParts = String(form.elements.citation_choice.value || "").split("|");
        const sourceId = citationParts[0] || "";
        const chunkId = citationParts[1] || "";
        const wikiId = citationParts[2] || "";
        if (!personal && (!sourceId || !chunkId)) {
          const citation = form.elements.citation_choice;
          form.querySelectorAll("details").forEach(function (details) { details.open = true; });
          citation.setAttribute("aria-invalid", "true");
          status.className = "cp-status-banner cp-status-error";
          status.textContent = "Select a current evidence citation, or clearly label this as a personal note.";
          citation.focus();
          return;
        }
        form.elements.citation_choice.removeAttribute("aria-invalid");
        const split = function (value) { return value.split(",").map(function (part) { return part.trim(); }).filter(Boolean); };
        const citation = personal ? [] : [{ source_id: sourceId, source_chunk_id: chunkId, wiki_page_id: wikiId || null }];
        const payload = { question: form.elements.question.value.trim(), answer: form.elements.answer.value.trim(), tags: split(form.elements.tags.value), topic_ids: split(form.elements.topic_ids.value), citations: citation, manual_note: personal };
        if (await mutate("update_card", payload, card.dataset.cardId)) {
          dirtyForms.delete(form);
          persistDirtyForms(form);
          dirtyForms.clear();
          window.location.reload();
        }
      });
    });
    page.addEventListener("click", async function (event) {
      const button = event.target.closest("button");
      if (!button) return;
      const card = button.closest("[data-card-id]");
      const lifecycleAction = button.matches("[data-move], [data-approve], [data-discard], [data-approve-selected], [data-approve-all], [data-publish], [data-archive], [data-retire], [data-add-card]");
      if (lifecycleAction && dirtyForms.size > 0) {
        status.className = "cp-status-banner cp-status-warn";
        status.textContent = "Save your local card edits before changing approval, order, or deck status.";
        const firstDirty = dirtyForms.values().next().value;
        const disclosure = firstDirty && firstDirty.closest("details");
        if (disclosure) disclosure.open = true;
        if (firstDirty) firstDirty.querySelector("input, textarea, select")?.focus();
        return;
      }
      let action = null, payload = null;
      if (button.dataset.move) {
        const activeCards = Array.from(page.querySelectorAll("[data-card-id]")).filter(function (item) { return item.dataset.discarded !== "true"; });
        const index = activeCards.indexOf(card);
        const target = button.dataset.move === "up" ? index - 1 : index + 1;
        if (index < 0 || target < 0 || target >= activeCards.length) return;
        const orderedIds = activeCards.map(function (item) { return item.dataset.cardId; });
        [orderedIds[index], orderedIds[target]] = [orderedIds[target], orderedIds[index]];
        action = "reorder"; payload = { card_ids: orderedIds };
      } else if (button.hasAttribute("data-approve")) { action = "approve"; payload = { card_ids: [card.dataset.cardId] }; }
      else if (button.hasAttribute("data-discard")) {
        const reasonSelect = card.querySelector("[data-rejection-reason]");
        const reason = reasonSelect ? reasonSelect.value : "";
        if (!reason) {
          const control = card.querySelector("[data-rejection-reason]");
          const disclosure = control.closest("details");
          if (disclosure) disclosure.open = true;
          control.setAttribute("aria-invalid", "true");
          status.className = "cp-status-banner cp-status-error";
          status.textContent = "Choose why this card is not useful before discarding it.";
          control.focus();
          return;
        }
        reasonSelect.removeAttribute("aria-invalid");
        action = "discard";
        payload = { card_ids: [card.dataset.cardId], rejection_reason: reason };
      }
      else if (button.hasAttribute("data-restore")) { action = "restore"; payload = { card_ids: [card.dataset.cardId] }; }
      else if (button.hasAttribute("data-approve-selected")) {
        const selected = Array.from(page.querySelectorAll("[data-card-select]:checked")).map(function (input) { return input.closest("[data-card-id]").dataset.cardId; });
        if (!selected.length) { status.textContent = "Select at least one active card to approve."; return; }
        action = "approve"; payload = { card_ids: selected };
      }
      else if (button.hasAttribute("data-approve-all")) {
        const approvable = ids(true);
        if (!approvable.length) { status.textContent = "No supported cards are waiting for approval."; return; }
        action = "approve";
        payload = { card_ids: approvable };
      }
      else if (button.hasAttribute("data-publish")) { action = "publish"; payload = {}; }
      else if (button.hasAttribute("data-archive") && window.confirm("Archive this draft? It will leave the active review list.")) { action = "archive"; payload = {}; }
      else if (button.hasAttribute("data-retire") && window.confirm("Retire this approved deck? It will leave study, but its immutable snapshot remains.")) { action = "retire"; payload = {}; }
      else if (button.hasAttribute("data-add-card")) {
        const question = window.prompt("Personal-note prompt"); if (!question) return;
        const answer = window.prompt("Personal-note answer"); if (!answer) return;
        action = "add_card"; payload = { question: question, answer: answer, tags: [], topic_ids: [], citations: [], manual_note: true };
      }
      if (action && await mutate(action, payload, card && card.dataset.cardId)) {
        if (action === "restore" && dirtyForms.size) {
          persistDirtyForms(null);
          dirtyForms.clear();
        }
        if (action === "archive" || action === "retire") window.location.href = "/flashcards?view=drafts";
        else window.location.reload();
      }
    });
  }

  function setupFlashcards() {
    const review = document.getElementById("cp-flash-review");
    const flashcard = document.getElementById("cp-flashcard");
    const details = document.getElementById("cp-card-details");
    const revealButton = document.getElementById("cp-reveal-card");
    const answer = document.getElementById("cp-card-answer");
    const ratingPanel = document.getElementById("cp-rating-panel");
    const skipButton = document.getElementById("cp-skip-card");
    const hint = document.getElementById("cp-review-hint");
    if (!review || !flashcard || !details || !revealButton || !answer || !ratingPanel) return;

    const cards = Array.from(document.querySelectorAll("#cp-flash-data [data-card-id]"));
    const ratingForms = Array.from(document.querySelectorAll("form[data-flash-rate]"));
    let index = 0;
    let reviewed = Number((document.getElementById("cp-reviewed-count") || {}).textContent || 0);
    let recalled = 0;
    let missed = 0;
    let confidenceTotal = 0;
    let confidenceCount = 0;
    let skipped = 0;
    let revealed = false;
    let submitting = false;
    let attemptStatus = null;
    let pendingRating = null;

    details.style.display = "contents";
    flashcard.insertAdjacentElement("afterend", ratingPanel);
    const deckId = ratingForms.length ? ratingForms[0].elements.deck_id.value : "";
    const currentCardKey = deckId ? "flashcard-current-" + deckId : "";
    const pendingRatingKey = deckId ? "flashcard-pending-rating-" + deckId : "";
    if (currentCardKey) try {
      const savedCardId = sessionStorage.getItem(currentCardKey);
      const savedIndex = cards.findIndex(function (card) { return card.dataset.cardId === savedCardId; });
      if (savedIndex >= 0) index = savedIndex;
    } catch (_) {}
    if (pendingRatingKey) try {
      const savedPending = JSON.parse(sessionStorage.getItem(pendingRatingKey) || "null");
      const pendingIndex = savedPending && cards.findIndex(function (card) { return card.dataset.cardId === savedPending.cardId; });
      if (savedPending && pendingIndex >= 0 && savedPending.rating && savedPending.key) {
        pendingRating = savedPending;
        index = pendingIndex;
      } else if (savedPending) {
        sessionStorage.removeItem(pendingRatingKey);
      }
    } catch (_) {
      try { sessionStorage.removeItem(pendingRatingKey); } catch (_) {}
    }

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
      if (currentCardKey) try { sessionStorage.setItem(currentCardKey, card.dataset.cardId || ""); } catch (_) {}
      document.getElementById("cp-card-number").textContent = String((index % cards.length) + 1);
      document.getElementById("cp-card-question").textContent = card.dataset.question || "";
      document.getElementById("cp-card-answer-text").textContent = card.dataset.answer || "";
      document.getElementById("cp-card-source").textContent = card.dataset.source || "Source";
      document.getElementById("cp-card-page").textContent = card.dataset.page || "";
      const sourceHref = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(card.dataset.sourceId || "")
        ? "/sources?source=" + encodeURIComponent(card.dataset.sourceId)
        : "/sources";
      [document.getElementById("cp-card-source-link"), document.getElementById("cp-card-context-link")].forEach(function (link) {
        if (link) link.href = sourceHref;
      });
      document.querySelectorAll('[name="card_id"]').forEach(function (field) {
        field.value = card.dataset.cardId || "";
      });
      setRevealed(false);
    }

    function updateEvidence() {
      const count = document.getElementById("cp-reviewed-count");
      const evidence = document.getElementById("cp-evidence-reviewed");
      const recalledNode = document.getElementById("cp-evidence-recalled");
      const missedNode = document.getElementById("cp-evidence-missed");
      const confidenceNode = document.getElementById("cp-evidence-confidence");
      const skippedNode = document.getElementById("cp-evidence-skipped");
      const bar = document.getElementById("cp-review-bar");
      if (count) count.textContent = String(reviewed);
      if (evidence) evidence.textContent = String(reviewed);
      if (recalledNode) recalledNode.textContent = String(recalled);
      if (missedNode) missedNode.textContent = String(missed);
      if (confidenceNode) confidenceNode.textContent = confidenceCount ? (confidenceTotal / confidenceCount).toFixed(1) : "—";
      if (skippedNode) skippedNode.textContent = String(skipped);
      if (bar) bar.style.width = Math.min(100, reviewed / 8 * 100) + "%";
    }

    function rate(saved) {
      reviewed += 1;
      if (saved.is_correct === true) recalled += 1;
      else missed += 1;
      if (Number.isInteger(saved.confidence)) {
        confidenceTotal += saved.confidence;
        confidenceCount += 1;
      }
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

    function persistPendingRating() {
      if (!pendingRatingKey) return;
      try {
        if (pendingRating) sessionStorage.setItem(pendingRatingKey, JSON.stringify(pendingRating));
        else sessionStorage.removeItem(pendingRatingKey);
      } catch (_) {}
    }

    function skipCurrent() {
      if (pendingRating) {
        showFailure("Resolve the pending " + pendingRating.rating + " save before skipping this card.");
        return;
      }
      skipped += 1;
      index = cards.length ? (index + 1) % cards.length : 0;
      updateEvidence();
      renderCurrent();
    }

    revealButton.addEventListener("click", function (event) {
      event.preventDefault();
      setRevealed(true);
    });
    if (skipButton) skipButton.addEventListener("click", skipCurrent);
    ratingForms.forEach(function (form) {
      form.addEventListener("submit", async function (event) {
        event.preventDefault();
        if (!revealed || submitting) return;
        if (attemptStatus) attemptStatus.hidden = true;
        setSubmitting(true);
        try {
          const cardId = form.elements.card_id.value;
          const rating = form.elements.rating.value;
          if (pendingRating && pendingRating.cardId === cardId && pendingRating.rating !== rating) {
            showFailure("The previous save outcome is unknown. Retry the same " + pendingRating.rating + " rating before choosing a different rating.");
            return;
          }
          if (!pendingRating || pendingRating.cardId !== cardId) {
            pendingRating = { cardId: cardId, rating: rating, key: flashKey("rating") };
            persistPendingRating();
          }
          const saved = await flashRequest("attempt", {
            deckId: form.elements.deck_id.value,
            cardId: cardId,
            key: pendingRating.key,
            payload: { rating: pendingRating.rating, answer_text: "" },
          });
          pendingRating = null;
          persistPendingRating();
          rate(saved);
        } catch (error) {
          const message = error && error.status === 401
            ? "Your session has expired. This answer was not recorded; sign in and try again."
            : "The save outcome is unknown. This card and rating remain open; retry the same rating with the same interaction key.";
          showFailure(message);
        } finally {
          setSubmitting(false);
        }
      });
    });

    document.addEventListener("keydown", function (event) {
      const target = event.target;
      if (target && /INPUT|TEXTAREA|SELECT/.test(target.tagName)) return;
      if (event.key.toLowerCase() === "s" && skipButton && !submitting) {
        event.preventDefault();
        skipCurrent();
      } else if (event.code === "Space") {
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
    if (pendingRating) {
      setRevealed(true);
      showFailure("The previous save outcome is unknown. Retry the same " + pendingRating.rating + " rating with the same interaction key.");
    }
  }
})();
