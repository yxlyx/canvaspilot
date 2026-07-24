(() => {
  const forms = document.querySelectorAll("[data-settings-form]");
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
          message(form, "Saved.");
        }
      } catch (error) {
        if (error.field) {
          error.field.setAttribute("aria-invalid", "true");
          error.field.focus();
        }
        message(form, error.message || "That change could not be saved.", true, !error.field);
      } finally {
        submit?.removeAttribute("disabled");
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

  const activeSettingsTab = document.querySelector('.cp-local-tabs[aria-label="Settings"] a[aria-current="page"]');
  const settingsTabs = activeSettingsTab?.closest(".cp-local-tabs");
  if (activeSettingsTab && settingsTabs && settingsTabs.scrollWidth > settingsTabs.clientWidth) {
    activeSettingsTab.scrollIntoView({ block: "nearest", inline: "center" });
  }
})();
