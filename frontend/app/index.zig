// app/index.zig — landing page. Authenticated users get sent straight to the
// dashboard so the root URL feels like a real app, not a marketing page.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Home",
    .description = "Study chat for your modules and deadlines.",
};

pub fn render(req: mer.Request) mer.Response {
    if (lib.session.fromRequest(req).isAuthenticated()) {
        return mer.redirect("/dashboard", .see_other);
    }

    const body =
        \\<section class="cp-landing">
        \\  <h1 class="cp-landing-title">Your course workspace, ready to study.</h1>
        \\  <p class="cp-landing-sub">
        \\    CanvasPilot turns your Canvas LMS modules into a study workspace: import sources,
        \\    generate cited wiki notes, ask grounded questions, and practise flashcards — all in one place.
        \\  </p>
        \\  <div class="cp-landing-actions">
        \\    <a class="cp-btn cp-btn-primary" href="/login?mode=signup">Create account</a>
        \\    <a class="cp-btn cp-btn-ghost" href="/login">Sign in</a>
        \\    <a class="cp-btn cp-btn-ghost" href="/dashboard?mock=1">View demo workspace</a>
        \\  </div>
        \\</section>
    ;
    return mer.html(body);
}
