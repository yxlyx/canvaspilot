(() => {
  const forms = document.querySelectorAll("[data-settings-form]");
  const notificationsLedger = document.querySelector(".cp-notification-ledger");
  const message = (form, text, error = false, focusStatus = true) => {
    const status = form.querySelector(".cp-form-status");
    if (!status) return;
    status.textContent = text;
    status.dataset.error = error ? "true" : "false";
    status.setAttribute("role", error ? "alert" : "status");
    if (error && focusStatus) status.focus();
  };

  const applyMotionPreference = (preference, persist = false) => {
    const requested = preference === "reduce" ? "reduce" : "system";
    document.documentElement.dataset.motion = requested;
    if (!persist) return;
    localStorage.setItem("wikibase-motion-preference", requested);
    const secure = window.location.protocol === "https:" ? "; Secure" : "";
    document.cookie = `wb_motion_preference=${requested}; Path=/; Max-Age=31536000; SameSite=Lax${secure}`;
  };

  const errorField = (form, body) => {
    const explicit = Array.isArray(body?.detail)
      ? body.detail.find((item) => Array.isArray(item?.loc))?.loc?.at(-1)
      : null;
    const mapped = {
      missing_name: "name",
      invalid_password: "current_password",
      weak_password: "new_password",
      password_unchanged: "new_password",
      not_found: "default_module_id",
    }[body?.error];
    const name = explicit || mapped;
    if (!name) return null;
    return form.querySelector(`[name="${CSS.escape(String(name))}"]`);
  };

  const syncNotificationBell = async () => {
    try {
      const response = await fetch("/api/notifications/unread-count", {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });
      if (!response.ok) return;
      const body = await response.json();
      const count = Number.isFinite(body.unread_count) ? Math.max(0, body.unread_count) : 0;
      document.querySelectorAll("[data-cp-notification-link]").forEach((link) => {
        const dot = link.querySelector("i");
        if (dot) dot.hidden = count === 0;
        link.setAttribute("aria-label", count ? `Notifications, ${count} unread` : "Notifications");
      });
    } catch (_) {}
  };

  const showCaughtUp = () => {
    if (!notificationsLedger || notificationsLedger.querySelector(".cp-notification-item")) return;
    const empty = document.createElement("div");
    empty.className = "cp-empty";
    empty.innerHTML = "<div><h2>You are caught up</h2><p>New actionable reminders will appear here.</p></div>";
    notificationsLedger.appendChild(empty);
  };

  const markNotificationRead = (form) => {
    const item = form.closest(".cp-notification-item");
    if (!item) return;
    if (new URLSearchParams(window.location.search).get("state") === "unread") {
      item.remove();
      showCaughtUp();
      return;
    }
    item.classList.remove("is-unread");
    item.querySelector(".cp-notification-mark")?.setAttribute("aria-label", "Read");
    const state = document.createElement("span");
    state.className = "cp-read-state";
    state.textContent = "Read";
    form.replaceWith(state);
  };

  const markAllNotificationsRead = (form) => {
    if (!notificationsLedger) return;
    const unreadOnly = new URLSearchParams(window.location.search).get("state") === "unread";
    notificationsLedger.querySelectorAll(".cp-notification-item").forEach((item) => {
      if (unreadOnly) {
        item.remove();
        return;
      }
      item.classList.remove("is-unread");
      item.querySelector(".cp-notification-mark")?.setAttribute("aria-label", "Read");
      const action = item.querySelector("[data-notification-read]");
      if (action) {
        const state = document.createElement("span");
        state.className = "cp-read-state";
        state.textContent = "Read";
        action.replaceWith(state);
      }
    });
    showCaughtUp();
    const submit = form.querySelector("button[type='submit']");
    if (submit) {
      submit.textContent = "All read";
      submit.setAttribute("disabled", "");
      form.dataset.complete = "true";
    }
  };

  const passwordForm = document.querySelector("[data-settings-password-change]");
  if (passwordForm) {
    const password = passwordForm.querySelector("[data-settings-new-password]");
    const confirmation = passwordForm.querySelector("[data-settings-confirm-password]");
    const match = passwordForm.querySelector("[data-settings-password-match]");
    const checks = {
      length: (value) => value.length >= 8,
      uppercase: (value) => /[A-Z]/.test(value),
      number: (value) => /[0-9]/.test(value),
    };
    const updatePassword = () => {
      const value = password?.value || "";
      let valid = true;
      Object.entries(checks).forEach(([name, check]) => {
        const item = passwordForm.querySelector(`[data-settings-password-rule="${name}"]`);
        const met = check(value);
        valid = valid && met;
        item?.classList.toggle("is-met", met);
        item?.setAttribute("aria-label", `${met ? "Met" : "Not met"}: ${item.textContent.trim()}`);
      });
      password?.setCustomValidity(value && !valid ? "Use at least 8 characters, including an uppercase letter and a number." : "");
      return valid;
    };
    const updateConfirmation = () => {
      if (!confirmation || !password || !match) return;
      const hasValue = confirmation.value.length > 0;
      const matches = hasValue && confirmation.value === password.value;
      confirmation.setCustomValidity(hasValue && !matches ? "Passwords do not match." : "");
      confirmation.setAttribute("aria-invalid", hasValue && !matches ? "true" : "false");
      match.textContent = !hasValue ? "" : matches ? "Passwords match" : "Passwords do not match";
      match.dataset.state = !hasValue ? "" : matches ? "match" : "mismatch";
    };
    password?.addEventListener("input", () => {
      updatePassword();
      updateConfirmation();
    });
    confirmation?.addEventListener("input", updateConfirmation);
    updatePassword();
    updateConfirmation();
  }

  forms.forEach((form) => {
    form.addEventListener("submit", async (event) => {
      if (!form.reportValidity()) return;
      if (form.matches("[data-delete-account]") && !window.confirm("Permanently delete this WikiBase account and all locally owned data?")) {
        event.preventDefault();
        return;
      }
      event.preventDefault();
      const submit = form.querySelector("button[type='submit']");
      submit?.setAttribute("disabled", "");
      message(form, form.matches("[data-download]") ? "Preparing archive…" : "Saving…");
      try {
        const response = await fetch(form.getAttribute("action") || "/api/settings", {
          method: "POST",
          headers: { Accept: form.matches("[data-download]") ? "application/zip, application/json" : "application/json" },
          body: new URLSearchParams(new FormData(form)),
          credentials: "same-origin",
        });
        if (!response.ok) {
          let detail = "That change could not be saved.";
          let body = {};
          try {
            body = await response.json();
            detail = body.detail?.message || body.detail || body.error || detail;
          } catch (_) {}
          const failure = new Error(Array.isArray(detail) ? detail[0]?.msg || "Review the highlighted field." : detail);
          failure.field = errorField(form, body);
          throw failure;
        }
        if (form.matches("[data-download]")) {
          const type = (response.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
          const disposition = response.headers.get("content-disposition") || "";
          const match = /^attachment\s*;(?:[^;]+;)*\s*filename=\"?([A-Za-z0-9._-]+)\"?(?:;|$)/i.exec(disposition);
          if (response.redirected || type !== "application/zip" || !match) throw new Error("The archive response was not a valid ZIP download.");
          const blob = await response.blob();
          const signature = new Uint8Array(await blob.slice(0, 4).arrayBuffer());
          const zip = signature.length === 4 && signature[0] === 0x50 && signature[1] === 0x4b && ((signature[2] === 3 && signature[3] === 4) || (signature[2] === 5 && signature[3] === 6) || (signature[2] === 7 && signature[3] === 8));
          if (!zip) throw new Error("The archive response was not a valid ZIP download.");
          const link = document.createElement("a");
          link.href = URL.createObjectURL(blob);
          link.download = match[1];
          link.click();
          setTimeout(() => URL.revokeObjectURL(link.href), 1000);
          message(form, "Archive downloaded.");
        } else {
          const body = await response.json().catch(() => ({}));
          if (body.redirect || form.matches("[data-session-ending], [data-delete-account]")) {
            window.location.assign(body.redirect || "/login");
            return;
          }
          if (form.matches("[data-appearance-form]")) {
            applyMotionPreference(form.querySelector("input[name='motion_preference']:checked")?.value, true);
          }
          if (form.matches("[data-notification-read]")) {
            markNotificationRead(form);
            await syncNotificationBell();
            return;
          }
          if (form.matches("[data-notifications-read-all]")) {
            markAllNotificationsRead(form);
            await syncNotificationBell();
            return;
          }
          message(form, "Saved.");
        }
      } catch (error) {
        if (error.field) {
          error.field.setAttribute("aria-invalid", "true");
          error.field.focus();
        }
        message(form, error.message || "That change could not be saved.", true, !error.field);
      } finally {
        if (form.dataset.complete !== "true") submit?.removeAttribute("disabled");
      }
    });
  });

  document.querySelectorAll("[data-password-toggle]").forEach((button) => {
    button.addEventListener("click", () => {
      const input = button.parentElement?.querySelector("input");
      if (!input) return;
      const showing = input.type === "text";
      input.type = showing ? "password" : "text";
      button.textContent = showing ? "Show" : "Hide";
      button.setAttribute("aria-label", `${showing ? "Show" : "Hide"} password`);
    });
  });

  document.querySelectorAll("[data-appearance-form] input[name='theme']").forEach((radio) => {
    radio.addEventListener("change", () => {
      const requested = radio.value;
      const theme = requested === "system" ? (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light") : requested;
      document.documentElement.dataset.theme = theme;
      localStorage.setItem("wikibase-theme-preference", requested);
      localStorage.setItem("wikibase-theme", theme);
    });
  });

  document.querySelectorAll("[data-appearance-form] input[name='motion_preference']").forEach((radio) => {
    radio.addEventListener("change", () => applyMotionPreference(radio.value));
  });

  const policyForm = document.querySelector("[data-processing-policy-form]");
  if (policyForm) policyForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!policyForm.reportValidity()) return;
    const submit = policyForm.querySelector("button[type='submit']");
    submit?.setAttribute("disabled", "");
    message(policyForm, "Saving durable processing policy…");
    const random = window.crypto?.randomUUID ? window.crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    try {
      const response = await fetch("/api/processing", {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify({
          action: "policy.update",
          idempotency_key: `policy-${random}`,
          payload: {
            process_sources: policyForm.elements.process_sources.checked,
            map_topics: policyForm.elements.map_topics.checked,
            compile_wiki: policyForm.elements.compile_wiki.checked,
            flashcard_mode: policyForm.elements.flashcard_mode.value,
          },
        }),
      });
      if (!response.ok) {
        let detail = "The processing policy could not be saved.";
        try { const body = await response.json(); detail = body.detail?.message || body.detail || body.error || detail; } catch (_) {}
        throw new Error(detail);
      }
      const policy = await response.json();
      message(policyForm, policy.process_sources ? "Processing policy saved." : "Policy saved. Queued source runs are paused. Re-enable source processing before retrying them.");
    } catch (error) {
      message(policyForm, error.message || "The processing policy could not be saved.", true);
    } finally {
      submit?.removeAttribute("disabled");
    }
  });

  const activeSettingsTab = document.querySelector('.cp-local-tabs[aria-label="Settings"] a[aria-current="page"]');
  const settingsTabs = activeSettingsTab?.closest(".cp-local-tabs");
  if (activeSettingsTab && settingsTabs && settingsTabs.scrollWidth > settingsTabs.clientWidth) {
    activeSettingsTab.scrollIntoView({ block: "nearest", inline: "center" });
  }
})();
