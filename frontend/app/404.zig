// app/404.zig — friendly not-found page that links back into the app.

const mer = @import("mer");

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return .{ .status = .not_found, .content_type = .html, .body = BODY };
}

const BODY =
    \\<section class="cp-landing">
    \\  <h1 class="cp-landing-title">Page not found</h1>
    \\  <p class="cp-landing-sub">
    \\    The page you're looking for hasn't been built yet (or you mistyped the URL).
    \\    Head back to the dashboard to find your modules, deadlines and chat.
    \\  </p>
    \\  <div class="cp-landing-actions">
    \\    <a class="cp-btn cp-btn-primary" href="/dashboard">Open dashboard</a>
    \\    <a class="cp-btn cp-btn-ghost" href="/chat">Ask CanvasPilot</a>
    \\  </div>
    \\</section>
;
