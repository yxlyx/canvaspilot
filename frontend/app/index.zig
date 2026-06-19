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
        \\  <h1 class="cp-landing-title">All your modules, ready to ask.</h1>
        \\  <p class="cp-landing-sub">
        \\    Create a demo account, view module updates, and try the chat flow with cited
        \\    course material.
        \\  </p>
        \\  <div class="cp-landing-actions">
        \\    <a class="cp-btn cp-btn-primary" href="/login">Sign in</a>
        \\    <a class="cp-btn cp-btn-ghost" href="/dashboard?mock=1">View demo data</a>
        \\  </div>
        \\</section>
    ;
    return mer.html(body);
}
