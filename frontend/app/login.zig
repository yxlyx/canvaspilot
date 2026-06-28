const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Sign in",
    .description = "Sign in or create a CanvasPilot account.",
};

fn errorText(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "invalid_credentials")) return "Email or password is incorrect.";
    if (std.mem.eql(u8, code, "email_taken")) return "An account already exists for that email.";
    if (std.mem.eql(u8, code, "weak_password")) return "Password must be at least 8 characters.";
    if (std.mem.eql(u8, code, "password_mismatch")) return "Passwords do not match.";
    if (std.mem.eql(u8, code, "missing_fields")) return "Fill in all required fields.";
    if (std.mem.eql(u8, code, "invalid_email")) return "Enter a valid email address.";
    if (std.mem.eql(u8, code, "backend_unavailable")) return "Could not reach the backend.";
    return "Something went wrong. Try again.";
}

pub fn render(req: mer.Request) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const mode = req.queryParam("mode") orelse "signin";
    const signup_active = std.mem.eql(u8, mode, "signup");

    w.writeAll(
        \\<section class="cp-auth-shell">
        \\  <div class="cp-auth-copy">
        \\    <div>
        \\      <div class="cp-kicker">Course workspace</div>
        \\      <h1 class="cp-landing-title">Keep revision moving.</h1>
        \\      <p class="cp-landing-sub">Use a local account for the full workspace, or jump into the demo data to inspect the prototype flow.</p>
        \\    </div>
        \\    <div class="cp-flow-list">
        \\      <div class="cp-flow-row"><span class="cp-flow-dot"></span><span class="cp-flow-label">Source-backed notes</span><span class="cp-flow-meta">wiki</span></div>
        \\      <div class="cp-flow-row"><span class="cp-flow-dot"></span><span class="cp-flow-label">Cited answers</span><span class="cp-flow-meta">Q&amp;A</span></div>
        \\      <div class="cp-flow-row"><span class="cp-flow-dot"></span><span class="cp-flow-label">Study practice</span><span class="cp-flow-meta">cards</span></div>
        \\    </div>
        \\  </div>
        \\  <div class="cp-auth-card">
        \\
    ) catch return mer.internalError("login render failed");

    if (req.queryParam("error")) |err| {
        const safe = lib.ui.escape(req.allocator, errorText(err)) catch errorText(err);
        w.print("<div class=\"cp-status-banner cp-status-error\">{s}</div>\n", .{safe}) catch return mer.internalError("login render failed");
    } else if (req.queryParam("signed_out") != null) {
        w.writeAll("<div class=\"cp-status-banner cp-status-info\">You have been signed out.</div>\n") catch return mer.internalError("login render failed");
    }

    const signin_cls: []const u8 = if (signup_active) "cp-auth-tab" else "cp-auth-tab cp-auth-tab-active";
    const signup_cls: []const u8 = if (signup_active) "cp-auth-tab cp-auth-tab-active" else "cp-auth-tab";
    w.print(
        \\  <div class="cp-auth-tabs" role="tablist">
        \\    <a class="{s}" href="/login?mode=signin">Sign in</a>
        \\    <a class="{s}" href="/login?mode=signup">Create account</a>
        \\  </div>
        \\
    , .{ signin_cls, signup_cls }) catch return mer.internalError("login render failed");

    if (signup_active) {
        w.writeAll(
            \\  <form class="cp-auth-form" method="post" action="/api/auth/register">
            \\    <label class="cp-field">
            \\      <span>Name</span>
            \\      <input name="name" autocomplete="name" required>
            \\    </label>
            \\    <label class="cp-field">
            \\      <span>Email</span>
            \\      <input name="email" type="email" autocomplete="email" required>
            \\    </label>
            \\    <label class="cp-field">
            \\      <span>Password</span>
            \\      <input name="password" type="password" autocomplete="new-password" minlength="8" required>
            \\    </label>
            \\    <label class="cp-field">
            \\      <span>Confirm password</span>
            \\      <input name="confirm_password" type="password" autocomplete="new-password" minlength="8" required>
            \\    </label>
            \\    <button class="cp-btn cp-btn-primary cp-auth-submit" type="submit">Create account</button>
            \\  </form>
            \\
        ) catch return mer.internalError("login render failed");
    } else {
        w.writeAll(
            \\  <form class="cp-auth-form" method="post" action="/api/auth/signin">
            \\    <label class="cp-field">
            \\      <span>Email</span>
            \\      <input name="email" type="email" autocomplete="email" required>
            \\    </label>
            \\    <label class="cp-field">
            \\      <span>Password</span>
            \\      <input name="password" type="password" autocomplete="current-password" required>
            \\    </label>
            \\    <button class="cp-btn cp-btn-primary cp-auth-submit" type="submit">Sign in</button>
            \\  </form>
            \\
        ) catch return mer.internalError("login render failed");
    }

    w.writeAll(
        \\    <p class="cp-auth-note">Need a quick look first?</p>
        \\    <div class="cp-landing-actions" style="margin-top:0;justify-content:center">
        \\      <a class="cp-btn cp-btn-ghost" href="/dashboard?mock=1">View demo data without signing in</a>
        \\    </div>
        \\  </div>
        \\</section>
        \\
    ) catch return mer.internalError("login render failed");

    return lib.ui.htmlResponse(&buf);
}
