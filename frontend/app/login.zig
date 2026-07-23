const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Sign in",
    .description = "Sign in or create a WikiBase account.",
};

fn errorText(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "invalid_credentials")) return "Email or password is incorrect.";
    if (std.mem.eql(u8, code, "email_taken")) return "An account already exists for that email.";
    if (std.mem.eql(u8, code, "weak_password")) return "Use at least 8 characters, including an uppercase letter and a number.";
    if (std.mem.eql(u8, code, "password_mismatch")) return "Passwords do not match.";
    if (std.mem.eql(u8, code, "missing_fields")) return "Fill in all required fields.";
    if (std.mem.eql(u8, code, "invalid_email")) return "Enter a valid email address.";
    if (std.mem.eql(u8, code, "backend_unavailable")) return "WikiBase could not be reached. Try again shortly.";
    return "Something went wrong. Try again.";
}

fn signupValue(req: mer.Request, name: []const u8) []const u8 {
    const raw = req.queryParam(name) orelse return "";
    const decoded = lib.form.decode(req.allocator, raw) catch return "";
    return lib.ui.escape(req.allocator, decoded) catch "";
}

pub fn render(req: mer.Request) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const mode = req.queryParam("mode") orelse "signin";
    const signup_active = std.mem.eql(u8, mode, "signup");
    const mode_name: []const u8 = if (signup_active) "signup" else "signin";

    w.print(
        \\<main class="wb-auth-page" id="main" tabindex="-1" data-auth-page data-auth-mode="{s}">
        \\  <section class="wb-auth-story" aria-labelledby="auth-story-title">
        \\    <a class="wb-auth-brand" href="/" aria-label="WikiBase home"><span>W</span><strong>WikiBase</strong></a>
        \\    <div class="wb-auth-story-copy">
        \\      <p class="wb-auth-eyebrow">Your knowledge has a place</p>
        \\      <h1 id="auth-story-title">Return to the structure you are building.</h1>
        \\      <p>Sources, notes, citations, and review stay connected across every module.</p>
        \\    </div>
        \\    <div class="wb-auth-landmark" aria-hidden="true"><span>&#8546;</span><span>&#8545;</span><span>&#8544;</span></div>
        \\    <small>One source at a time. One idea made clearer.</small>
        \\  </section>
        \\  <section class="wb-auth-form-wrap">
        \\    <a class="wb-auth-back" href="/"><span aria-hidden="true">&#8592;</span> Back to home</a>
        \\    <div class="wb-auth-panel">
    , .{mode_name}) catch return mer.internalError("login render failed");

    const signin_cls: []const u8 = if (signup_active) "wb-auth-tab" else "wb-auth-tab is-active";
    const signup_cls: []const u8 = if (signup_active) "wb-auth-tab is-active" else "wb-auth-tab";
    const signin_current: []const u8 = if (signup_active) "" else " aria-current=\"page\"";
    const signup_current: []const u8 = if (signup_active) " aria-current=\"page\"" else "";
    w.print(
        \\      <nav class="wb-auth-tabs" aria-label="Authentication mode">
        \\        <a class="{s}" href="/login?mode=signin"{s}>Sign in</a>
        \\        <a class="{s}" href="/login?mode=signup"{s}>Create account</a>
        \\      </nav>
    , .{ signin_cls, signin_current, signup_cls, signup_current }) catch return mer.internalError("login render failed");

    if (signup_active) {
        w.writeAll(
            \\      <header class="wb-auth-heading">
            \\        <p class="wb-auth-eyebrow">Begin your workspace</p>
            \\        <h2 id="auth-form-title">Build from your sources.</h2>
            \\        <p>Create one workspace for connected sources, Wiki articles, cited answers, and review.</p>
            \\      </header>
        ) catch return mer.internalError("login render failed");
    } else {
        w.writeAll(
            \\      <header class="wb-auth-heading">
            \\        <p class="wb-auth-eyebrow">Welcome back</p>
            \\        <h2 id="auth-form-title">Continue your studies.</h2>
            \\        <p>Use your email to return to your WikiBase workspace.</p>
            \\      </header>
        ) catch return mer.internalError("login render failed");
    }

    if (req.queryParam("error")) |err| {
        const safe = lib.ui.escapeSafe(req.allocator, errorText(err));
        w.print("<div class=\"wb-auth-alert wb-auth-alert-error\" role=\"alert\" tabindex=\"-1\" data-auth-alert>{s}</div>\n", .{safe}) catch return mer.internalError("login render failed");
    } else if (req.queryParam("signed_out") != null) {
        w.writeAll("<div class=\"wb-auth-alert wb-auth-alert-info\" role=\"status\" tabindex=\"-1\" data-auth-alert>You have been signed out.</div>\n") catch return mer.internalError("login render failed");
    }

    if (signup_active) {
        const name_value = signupValue(req, "name");
        const email_value = signupValue(req, "email");
        w.print(
            \\      <form class="wb-auth-form" method="post" action="/api/auth/register" aria-labelledby="auth-form-title" data-auth-form data-auth-kind="signup">
            \\        <label class="wb-auth-field" for="auth-name"><span>Name</span><input id="auth-name" name="name" autocomplete="name" maxlength="255" value="{s}" placeholder="Your name" required></label>
            \\        <label class="wb-auth-field" for="auth-email"><span>Email</span><input id="auth-email" name="email" type="email" autocomplete="email" maxlength="320" inputmode="email" value="{s}" placeholder="you@example.edu" required></label>
            \\        <div class="wb-auth-field" data-password-policy>
            \\          <div class="wb-auth-field-label"><label for="auth-password">Create password</label></div>
            \\          <div class="wb-auth-password-control"><input id="auth-password" name="password" type="password" autocomplete="new-password" minlength="8" maxlength="4096" pattern="(?=.*[A-Z])(?=.*[0-9]).{{8,}}" title="Use at least 8 characters, including an uppercase letter and a number" aria-describedby="auth-password-rules" placeholder="At least 8 characters" required data-password-input><button type="button" data-password-toggle aria-label="Show password">Show</button></div>
            \\          <ul class="wb-auth-rules" id="auth-password-rules" aria-label="Password requirements">
            \\            <li data-password-rule="length"><span aria-hidden="true"></span>8 or more characters</li>
            \\            <li data-password-rule="uppercase"><span aria-hidden="true"></span>One uppercase letter</li>
            \\            <li data-password-rule="number"><span aria-hidden="true"></span>One number</li>
            \\          </ul>
            \\        </div>
            \\        <div class="wb-auth-confirm" data-password-confirm>
            \\          <div>
            \\            <div class="wb-auth-field">
            \\              <div class="wb-auth-field-label"><label for="auth-confirm-password">Confirm password</label><small data-password-match aria-live="polite"></small></div>
            \\              <div class="wb-auth-password-control"><input id="auth-confirm-password" name="confirm_password" type="password" autocomplete="new-password" minlength="8" maxlength="4096" placeholder="Repeat your password" required data-password-confirm-input><button type="button" data-password-toggle aria-label="Show password confirmation">Show</button></div>
            \\            </div>
            \\          </div>
            \\        </div>
            \\        <button class="wb-auth-submit" type="submit" data-auth-submit><span data-auth-submit-label>Create my WikiBase</span><span class="wb-auth-spinner" aria-hidden="true"></span></button>
            \\      </form>
        , .{ name_value, email_value }) catch return mer.internalError("login render failed");
    } else {
        w.writeAll(
            \\      <form class="wb-auth-form" method="post" action="/api/auth/signin" aria-labelledby="auth-form-title" data-auth-form data-auth-kind="signin">
            \\        <label class="wb-auth-field" for="auth-email"><span>Email</span><input id="auth-email" name="email" type="email" autocomplete="email" maxlength="320" inputmode="email" placeholder="you@example.edu" required></label>
            \\        <div class="wb-auth-field"><div class="wb-auth-field-label"><label for="auth-password">Password</label></div><div class="wb-auth-password-control"><input id="auth-password" name="password" type="password" autocomplete="current-password" maxlength="4096" placeholder="Your password" required><button type="button" data-password-toggle aria-label="Show password">Show</button></div></div>
            \\        <button class="wb-auth-submit" type="submit" data-auth-submit><span data-auth-submit-label>Sign in to WikiBase</span><span class="wb-auth-spinner" aria-hidden="true"></span></button>
            \\      </form>
        ) catch return mer.internalError("login render failed");
    }

    w.writeAll(
        \\      <div class="wb-auth-demo"><span>Want to look around first?</span><a href="/dashboard?mock=1">View the demo workspace <span aria-hidden="true">&#8599;</span></a></div>
        \\    </div>
        \\  </section>
        \\</main>
    ) catch return mer.internalError("login render failed");

    return lib.ui.htmlResponse(&buf);
}
