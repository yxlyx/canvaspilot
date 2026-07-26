const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Notifications", .description = "Review actionable workspace reminders." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Notifications")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const unread_only = std.mem.eql(u8, req.queryParam("state") orelse "all", "unread");
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("notifications render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Actionable reminders</p><h1 class=\"cp-page-title\">Notifications</h1><p class=\"cp-page-sub\">Only events that need your attention appear here.</p></div>") catch return mer.internalError("notifications render failed");
    if (!demo) w.writeAll("<form method=\"post\" action=\"/api/settings\" data-settings-form data-notifications-read-all><input type=\"hidden\" name=\"action\" value=\"notifications.read_all\"><input type=\"hidden\" name=\"next\" value=\"/notifications\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Mark all read</button><p class=\"cp-form-status\" role=\"status\"></p></form>") catch return mer.internalError("notifications render failed");
    w.writeAll("</header><nav class=\"cp-filter-row\" aria-label=\"Notification filter\"><a class=\"filter-button") catch return mer.internalError("notifications render failed");
    if (!unread_only) w.writeAll(" active") catch return mer.internalError("notifications render failed");
    w.writeAll("\" href=\"/notifications\"") catch return mer.internalError("notifications render failed");
    if (!unread_only) w.writeAll(" aria-current=\"page\"") catch return mer.internalError("notifications render failed");
    w.writeAll(">All</a><a class=\"filter-button") catch return mer.internalError("notifications render failed");
    if (unread_only) w.writeAll(" active") catch return mer.internalError("notifications render failed");
    w.writeAll("\" href=\"/notifications?state=unread\"") catch return mer.internalError("notifications render failed");
    if (unread_only) w.writeAll(" aria-current=\"page\"") catch return mer.internalError("notifications render failed");
    w.writeAll(">Unread</a><a class=\"filter-button\" href=\"/settings/notifications\">Preferences</a></nav><section class=\"cp-notification-ledger\" aria-label=\"Notifications\">") catch return mer.internalError("notifications render failed");
    if (demo) {
        notification(w, "Source needs attention", "Lecture 08 could not finish processing. Review the affected source.", "/sources?mock=1&status=failed", "Source", true, null) catch return mer.internalError("notifications render failed");
        notification(w, "Daily review target", "Four more card reviews will complete today's target.", "/flashcards?mock=1", "Learning", true, null) catch return mer.internalError("notifications render failed");
        notification(w, "Paper ready for review", "Tutorial 05 has three extracted questions waiting for confirmation.", "/sources/papers?mock=1", "Papers", false, null) catch return mer.internalError("notifications render failed");
    } else {
        const result = lib.backend.notifications(req.allocator, lib.session.fromRequest(req).token, unread_only);
        const page = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Notifications", result.status);
        for (page.items) |item| notification(w, lib.ui.escapeSafe(req.allocator, item.title), lib.ui.escapeSafe(req.allocator, item.body), lib.m3.safeInternalHref(item.href, "/notifications"), notificationKindLabel(item.kind), item.read_at == null, item.id) catch return mer.internalError("notifications render failed");
        if (page.items.len == 0) w.writeAll("<div class=\"cp-empty\"><div><h2>You are caught up</h2><p>New actionable reminders will appear here.</p></div></div>") catch return mer.internalError("notifications render failed");
    }
    w.writeAll("</section><script src=\"/settings.js?v=20260728-1\" defer></script>") catch return mer.internalError("notifications render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn notificationKindLabel(kind: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(kind, "daily_review")) return "Daily review";
    if (std.ascii.eqlIgnoreCase(kind, "processing_attention")) return "Source needs attention";
    if (std.ascii.eqlIgnoreCase(kind, "processing_complete")) return "Source ready";
    if (std.ascii.eqlIgnoreCase(kind, "paper_review")) return "Paper ready for review";
    if (std.ascii.eqlIgnoreCase(kind, "health_attention")) return "Health finding";
    return "Workspace update";
}

fn notification(w: *std.Io.Writer, title: []const u8, body: []const u8, href: []const u8, kind: []const u8, unread: bool, id: ?[]const u8) !void {
    try w.print("<article class=\"cp-notification-item{s}\"><span class=\"cp-notification-mark\" aria-label=\"{s}\"></span><div><p class=\"eyebrow\">{s}</p><h2><a href=\"{s}\">{s}</a></h2><p>{s}</p></div>", .{ if (unread) " is-unread" else "", if (unread) "Unread" else "Read", kind, href, title, body });
    if (id) |notification_id| try w.print("<form method=\"post\" action=\"/api/settings\" data-settings-form data-notification-read><input type=\"hidden\" name=\"action\" value=\"notification.read\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><input type=\"hidden\" name=\"next\" value=\"/notifications\"><button class=\"cp-text-button\" type=\"submit\">Mark read</button></form>", .{notification_id});
    try w.writeAll("</article>");
}
