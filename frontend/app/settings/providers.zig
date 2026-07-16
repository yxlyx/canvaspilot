const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Provider settings", .description = "Review AI provider status and capabilities." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Provider settings")) |response| return response;
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">Provider settings</h1><p class=\"cp-page-sub\">Connection status and capabilities. Credentials are write-only and are never rendered back.</p></div></header>") catch return mer.internalError("providers render failed");
    lib.m3.demoBanner(w) catch return mer.internalError("providers render failed");
    w.writeAll("<div class=\"cp-provider-grid\">\n") catch return mer.internalError("providers render failed");
    for (lib.mock.providers) |provider| {
        const name = lib.ui.escape(req.allocator, provider.name) catch provider.name;
        const detail = lib.ui.escape(req.allocator, provider.status_detail) catch provider.status_detail;
        const id = lib.m3.safeId(provider.id, "demo-provider");
        w.print("<article class=\"cp-card cp-provider-card\"><div class=\"cp-card-title\"><span>{s}</span><strong class=\"cp-state cp-state-{s}\">{s}</strong></div><p>{s}</p><ul class=\"cp-plain-list\">", .{ name, @tagName(provider.status), @tagName(provider.status), detail }) catch return mer.internalError("providers render failed");
        for (provider.capabilities) |capability| {
            const label = lib.ui.escape(req.allocator, capability.label) catch capability.label;
            w.print("<li>{s}: <strong>{s}</strong></li>", .{ label, if (capability.available) "available" else "unavailable" }) catch return mer.internalError("providers render failed");
        }
        w.print(
            \\</ul><form class="cp-provider-form" aria-label="{s} write-only credentials">
            \\  <label class="cp-field" for="credential-{s}"><span>API key or credential (write-only)</span><input id="credential-{s}" type="password" autocomplete="new-password" placeholder="Not shown or stored in demo" disabled></label>
            \\  <div class="cp-action-row"><button class="cp-btn cp-btn-ghost" type="button" disabled>Test</button><button class="cp-btn cp-btn-primary" type="button" disabled>Save</button><button class="cp-btn cp-btn-danger" type="button" disabled>Disconnect</button></div>
            \\  <small>Demo is read-only. Provider mutation needs a backend contract.</small>
            \\</form></article>
        , .{ name, id, id }) catch return mer.internalError("providers render failed");
    }
    w.writeAll("</div>") catch return mer.internalError("providers render failed");
    return lib.ui.htmlResponse(&buf);
}
