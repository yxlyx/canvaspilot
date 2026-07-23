(() => {
  const forms = document.querySelectorAll("[data-settings-form]");
  const message = (form, text, error = false) => {
    const status = form.querySelector(".cp-form-status");
    if (!status) return;
    status.textContent = text;
    status.dataset.error = error ? "true" : "false";
    if (error) status.focus();
  };

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
        const response = await fetch(form.action, {
          method: "POST",
          headers: { Accept: form.matches("[data-download]") ? "application/zip" : "application/json" },
          body: new URLSearchParams(new FormData(form)),
          credentials: "same-origin",
        });
        if (!response.ok) {
          let detail = "That change could not be saved.";
          try {
            const body = await response.json();
            detail = body.detail?.message || body.detail || body.error || detail;
          } catch (_) {}
          throw new Error(detail);
        }
        if (form.matches("[data-download]")) {
          const blob = await response.blob();
          const disposition = response.headers.get("content-disposition") || "";
          const match = disposition.match(/filename=\"?([A-Za-z0-9._-]+)\"?/);
          const link = document.createElement("a");
          link.href = URL.createObjectURL(blob);
          link.download = match?.[1] || "wikibase-account.zip";
          link.click();
          setTimeout(() => URL.revokeObjectURL(link.href), 1000);
          message(form, "Archive downloaded.");
        } else {
          const body = await response.json().catch(() => ({}));
          if (body.redirect || form.matches("[data-session-ending], [data-delete-account]")) {
            window.location.assign(body.redirect || "/login");
            return;
          }
          message(form, "Saved.");
        }
      } catch (error) {
        message(form, error.message || "That change could not be saved.", true);
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
})();
