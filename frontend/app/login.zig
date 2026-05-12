// app/login.zig — single "Connect with Canvas" button + friendly error
// surfaces for OAuth failures coming back via ?error=…

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Sign in",
    .description = "Connect your Canvas account to CanvasPilot.",
};

pub fn render(req: mer.Request) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;

    w.writeAll(
        \\<section class="cp-landing">
        \\  <h1 class="cp-landing-title">Sign in to CanvasPilot</h1>
        \\  <p class="cp-landing-sub">We never store your Canvas password. We use Canvas's OAuth flow and only keep the access token your backend issues us.</p>
        \\
    ) catch return mer.internalError("login render failed");

    if (req.queryParam("error")) |err| {
        const safe = lib.ui.escape(req.allocator, err) catch err;
        w.print(
            "<div class=\"cp-status-banner cp-status-error\">Canvas sign-in failed: {s}</div>\n",
            .{safe},
        ) catch return mer.internalError("login render failed");
    }

    const start_url = lib.backend.oauthStartUrl(req.allocator);
    w.print(
        \\  <div class="cp-landing-actions">
        \\    <a class="cp-btn cp-btn-primary" href="/api/auth/start">Connect with Canvas</a>
        \\    <a class="cp-btn cp-btn-ghost" href="/dashboard?mock=1">Skip & try the demo</a>
        \\  </div>
        \\  <p class="cp-landing-sub" style="margin-top:18px;font-size:12px">
        \\    Direct backend route: <code>{s}</code>
        \\  </p>
        \\</section>
        \\
    , .{start_url}) catch return mer.internalError("login render failed");

    return lib.ui.htmlResponse(&buf);
}
