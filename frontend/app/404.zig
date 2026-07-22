// app/404.zig — friendly not-found page that links back into the app.

const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Page not found" };

pub fn render(req: mer.Request) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    if (!lib.session.fromRequest(req).isAuthenticated()) {
        buf.writer.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>") catch return mer.internalError("not found render failed");
    }
    buf.writer.writeAll(BODY) catch return mer.internalError("not found render failed");
    var response = lib.ui.htmlResponse(&buf);
    response.status = .not_found;
    return response;
}

const BODY =
    \\<main class="cp-landing" id="main" tabindex="-1" data-cp-document-title="Page not found">
    \\  <h1 class="cp-landing-title">Page not found</h1>
    \\  <p class="cp-landing-sub">
    \\    The page you're looking for hasn't been built yet (or you mistyped the URL).
    \\    Head back to the workspace to find your sources, wiki notes, cards and chat.
    \\  </p>
    \\  <div class="cp-landing-actions">
    \\    <a class="cp-btn cp-btn-primary" href="/dashboard">Open workspace</a>
    \\    <a class="cp-btn cp-btn-ghost" href="/chat">Ask WikiBase</a>
    \\  </div>
    \\</main>
;
