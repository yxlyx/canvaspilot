const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "AI providers", .description = "Choose how WikiBase creates cited answers and study material." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "AI providers")) |response| return response;
    if (lib.m3.isExplicitDemo(req)) return renderDemo(req);
    return renderLive(req);
}

fn renderLive(req: mer.Request) mer.Response {
    const token = lib.session.fromRequest(req).token;
    const descriptors_result = lib.backend.providerDescriptors(req.allocator, token);
    const settings_result = lib.backend.providerSettings(req.allocator, token);
    const descriptors = if (descriptors_result.value) |p| p.value else return lib.m3.liveError(req, "AI providers", descriptors_result.status);
    const settings = if (settings_result.value) |p| p.value else return lib.m3.liveError(req, "AI providers", settings_result.status);
    const codegraff = findDescriptor(descriptors, "codegraff");
    const codegraff_setting = findSetting(settings, "codegraff");
    const session = if (req.queryParam("session")) |raw| blk: {
        const id = lib.m3.safeId(raw, "");
        if (id.len == 0) break :blk null;
        const result = lib.backend.providerAuthorization(req.allocator, token, id);
        break :blk if (result.value) |p| p.value else null;
    } else null;
    const models: []const lib.types.ProviderModelOption = if (codegraff_setting != null) blk: {
        const result = lib.backend.providerModels(req.allocator, token, "codegraff");
        break :blk if (result.value) |p| p.value else &.{};
    } else &.{};

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header wb-m3-header\"><div><p class=\"cp-page-kicker wb-m3-eyebrow\">Answer connections</p><h1 class=\"cp-page-title wb-m3-title\">AI providers</h1><p class=\"cp-page-sub wb-m3-deck\">Choose how WikiBase creates cited answers and study material. Your sources remain available when no provider is connected.</p></div></header>") catch return mer.internalError("providers render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.settings_tabs, "providers", "Settings", false) catch return mer.internalError("providers render failed");
    w.writeAll("<div class=\"cp-provider-page\">") catch return mer.internalError("providers render failed");
    renderCodegraff(req, w, codegraff, codegraff_setting, session, models) catch return mer.internalError("providers render failed");
    renderOtherProviders(req, w, descriptors, settings) catch return mer.internalError("providers render failed");
    w.writeAll("</div><script src=\"/m3.js?v=20260806\" defer></script>") catch return mer.internalError("providers render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderCodegraff(req: mer.Request, w: anytype, descriptor: ?lib.types.ProviderDescriptor, setting: ?lib.types.ProviderStatusResponse, session: ?lib.types.ProviderAuthorizationSessionResponse, models: []const lib.types.ProviderModelOption) !void {
    try w.writeAll("<section class=\"cp-provider-section\" id=\"connect-codegraff\" aria-labelledby=\"codegraff-title\"><div class=\"cp-provider-section-head\"><p class=\"eyebrow\">Recommended connection</p><h2 id=\"codegraff-title\">Codegraff</h2><p>Use one account and balance across several answer models. Credits and current pricing remain in your Codegraff account.</p></div><div class=\"cp-provider-disclosure\"><p><strong>What leaves WikiBase</strong><br>Your question, recent chat context, and selected source excerpts are sent through Codegraff to the model you choose.</p><p><strong>What stays private</strong><br>WikiBase encrypts the gateway credential and never returns it to your browser.</p></div>");
    const visible_session = if (session) |item| if (!std.mem.eql(u8, item.status, "completed")) item else null else null;
    if (visible_session) |item| {
        try renderDeviceSession(req, w, item);
    } else if (setting == null) {
        try w.writeAll("<div class=\"cp-provider-start\"><div><strong>Not connected</strong><p>Connect Codegraff to enable cited answers and new study material. Reading, search, Sources, and Wiki remain available.</p></div><form class=\"wb-m3-form cp-provider-connect\" method=\"post\" action=\"/api/m3\" data-m3-form data-codegraff-auth-start data-approval-bootstrap=\"/settings/providers?opening=codegraff\"><input type=\"hidden\" name=\"action\" value=\"provider.auth.start\"><input type=\"hidden\" name=\"id\" value=\"codegraff\"><input type=\"hidden\" name=\"return_path\" value=\"/settings/providers?provider=codegraff\"><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Connect Codegraff</button><p class=\"cp-form-status\" role=\"status\"></p></form></div>");
    } else {
        const current = setting.?;
        try renderCodegraffState(req, w, current);
        try renderModelChoices(req, w, descriptor, current, models);
    }
    if (setting) |current| if (current.last_error) |reason| try w.print("<div class=\"notice notice-warn cp-provider-error\" role=\"status\"><strong>Connection needs attention</strong><span>{s}</span></div>", .{lib.ui.escapeSafe(req.allocator, reason)});
    try w.writeAll("</section>");
}

fn renderCodegraffState(req: mer.Request, w: anytype, setting: lib.types.ProviderStatusResponse) !void {
    const tested_relative = if (setting.last_tested_at) |value| lib.time.formatRelative(req.allocator, value, lib.time.nowSecs()) catch "Recently" else "Not tested yet";
    const needs_attention = std.mem.eql(u8, setting.status, "invalid") or std.mem.eql(u8, setting.status, "reauth_required");
    const is_tested = std.mem.eql(u8, setting.status, "connected") or setting.active_for_generation;
    const state_title = if (setting.active_for_generation) "Active for cited answers" else if (needs_attention) "Connection needs attention" else if (is_tested) "Tested, not active" else "Authorized, not tested";
    const state_copy = if (setting.active_for_generation) "WikiBase will use Codegraff and this model for new answers and study material." else if (needs_attention) "The latest connection check failed. Resolve the issue below or reconnect Codegraff." else if (is_tested) "The connection works, but WikiBase will not use it until you choose Use for answers." else "Codegraff approved WikiBase. Choose a model and run Test and use to finish setup.";
    const state_class = if (setting.active_for_generation) " is-active" else if (needs_attention) " is-error" else if (is_tested) " is-tested" else " is-authorized";
    const mark_path = if (needs_attention) "M7 7l10 10M17 7 7 17" else "m5 12 4 4L19 6";
    const test_result = if (needs_attention) "Failed" else if (is_tested) "Passed" else "Not run";
    const account_label = setting.provider_account_label orelse "Codegraff account";
    try w.print("<div class=\"cp-provider-state\"><div class=\"cp-provider-state-mark{s}\" aria-hidden=\"true\"><svg viewBox=\"0 0 24 24\"><path d=\"{s}\"/></svg></div><div><strong>{s}</strong><p>{s}</p><dl><div><dt>Account</dt><dd>{s}</dd></div><div><dt>Model</dt><dd>{s}</dd></div><div><dt>Connection test</dt><dd>{s}{s}{s}</dd></div></dl></div><div class=\"cp-provider-action-stack\"><div class=\"cp-provider-actions\">", .{ state_class, mark_path, state_title, state_copy, lib.ui.escapeSafe(req.allocator, account_label), lib.ui.escapeSafe(req.allocator, setting.model), test_result, if (setting.last_tested_at != null) " · " else "", if (setting.last_tested_at != null) lib.ui.escapeSafe(req.allocator, tested_relative) else "" });
    if (is_tested and !setting.active_for_generation) try w.writeAll("<form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.activate\"><input type=\"hidden\" name=\"id\" value=\"codegraff\"><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Use for answers</button></form>");
    try w.writeAll("<a class=\"cp-btn cp-btn-ghost\" href=\"https://codegraff.com/\" target=\"_blank\" rel=\"noopener noreferrer\">Manage credits ↗</a><form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-confirm=\"Disconnect Codegraff and remove its stored WikiBase credential?\" data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.disconnect\"><input type=\"hidden\" name=\"id\" value=\"codegraff\"><button class=\"cp-btn cp-btn-danger\" type=\"submit\">Disconnect</button></form></div><p class=\"cp-form-status\" role=\"status\"></p></div></div>");
}

fn renderDeviceSession(req: mer.Request, w: anytype, session: lib.types.ProviderAuthorizationSessionResponse) !void {
    if (std.mem.eql(u8, session.status, "pending")) {
        try w.print("<div class=\"cp-device-session\" data-device-session=\"{s}\" data-session-status=\"pending\" data-poll-interval=\"{d}\" data-session-expires=\"{s}\" aria-live=\"polite\"><div class=\"cp-device-heading\"><span class=\"cp-device-spinner\" aria-hidden=\"true\"></span><div><strong>Waiting for authorization</strong><p>Signing in alone does not connect WikiBase. Approve this device on Codegraff.</p></div></div><ol class=\"cp-device-steps\"><li><span>1</span><div><strong>Open the approval page</strong><p>The secure page opens automatically. Use the button below if your browser blocked it.</p></div></li><li><span>2</span><div><strong>Verify the code and authorize</strong><p>Confirm Codegraff shows this one-time code, then choose Authorize.</p><div class=\"cp-device-code-row\"><code tabindex=\"0\" data-user-code>{s}</code><button class=\"cp-btn cp-btn-ghost\" type=\"button\" data-copy-code>Copy</button></div></div></li><li><span>3</span><div><strong>Return to WikiBase</strong><p>This page keeps checking until Codegraff approves the device.</p></div></li></ol><div class=\"cp-provider-actions\"><a class=\"cp-btn cp-btn-primary\" href=\"{s}\" target=\"_blank\" rel=\"noopener noreferrer\">Open approval page ↗</a><form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.auth.poll\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Check connection</button></form></div><p class=\"cp-form-status\" data-device-poll-status role=\"status\">Waiting for Codegraff authorization.</p></div>", .{ lib.ui.escapeSafe(req.allocator, session.id), session.poll_interval_seconds orelse 5, lib.ui.escapeSafe(req.allocator, session.expires_at), lib.ui.escapeSafe(req.allocator, session.user_code orelse "Code unavailable"), lib.ui.escapeSafe(req.allocator, session.verification_uri_complete orelse session.verification_uri orelse "https://codegraff.com/cli/auth"), lib.ui.escapeSafe(req.allocator, session.id) });
    } else {
        try w.print("<div class=\"cp-provider-empty\" role=\"alert\"><h3>Connection not completed</h3><p>{s}</p><a class=\"cp-btn cp-btn-primary\" href=\"/settings/providers?provider=codegraff#connect-codegraff\">Start again</a></div>", .{lib.ui.escapeSafe(req.allocator, session.error_message orelse "The one-time connection could not be completed.")});
    }
}

fn renderModelChoices(req: mer.Request, w: anytype, descriptor: ?lib.types.ProviderDescriptor, setting: lib.types.ProviderStatusResponse, models: []const lib.types.ProviderModelOption) !void {
    try w.writeAll("<form id=\"choose-model\" class=\"wb-m3-form cp-provider-model-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-provider-save data-provider-activate data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.save\"><input type=\"hidden\" name=\"provider\" value=\"codegraff\"><fieldset><legend>Answer model</legend><p class=\"cp-muted-copy\">Choose the balance you want. Testing sends one minimal request and may use a negligible amount of credit.</p><div class=\"cp-model-ledger\">");
    const labels = [_][]const u8{ "Balanced", "Thorough", "Economy" };
    var shown: usize = 0;
    if (descriptor) |item| for (item.models, 0..) |model, index| {
        if (!hasModel(models, model)) continue;
        const label = if (index < labels.len) labels[index] else "Model";
        try w.print("<label><input type=\"radio\" name=\"model\" value=\"{s}\"{s} required><span><strong>{s}</strong><small>{s}</small></span></label>", .{ lib.ui.escapeSafe(req.allocator, model), if (std.mem.eql(u8, setting.model, model) or (shown == 0 and setting.model.len == 0)) " checked" else "", label, lib.ui.escapeSafe(req.allocator, model) });
        shown += 1;
    };
    try w.writeAll("</div></fieldset><details class=\"cp-provider-details\"><summary>Advanced model catalog</summary><div class=\"cp-model-advanced\">");
    for (models) |model| {
        const is_preset = if (descriptor) |item| hasString(item.models, model.id) else false;
        if (is_preset) continue;
        try w.print("<label><input type=\"radio\" name=\"model\" value=\"{s}\"{s}><span>{s}</span></label>", .{ lib.ui.escapeSafe(req.allocator, model.id), if (std.mem.eql(u8, setting.model, model.id)) " checked" else "", lib.ui.escapeSafe(req.allocator, model.label) });
    }
    try w.writeAll("</div><p><a href=\"https://codegraff.com/\" target=\"_blank\" rel=\"noopener noreferrer\">View current Codegraff pricing ↗</a></p></details>");
    if (models.len == 0)
        try w.writeAll("<div class=\"notice notice-warn\" role=\"status\">The model catalog is temporarily unavailable. Refresh this page to try again.</div><button class=\"cp-btn cp-btn-primary\" type=\"submit\" disabled>Catalog unavailable</button>")
    else
        try w.print("<button class=\"cp-btn cp-btn-primary\" type=\"submit\">{s}</button>", .{if (setting.active_for_generation) "Save and retest model" else if (std.mem.eql(u8, setting.status, "connected")) "Change model and use" else "Test and use"});
    try w.writeAll("<p class=\"cp-form-status\" role=\"status\"></p></form>");
}

fn renderOtherProviders(req: mer.Request, w: anytype, descriptors: []const lib.types.ProviderDescriptor, settings: []const lib.types.ProviderStatusResponse) !void {
    const requested = req.queryParam("provider") orelse "";
    const open = requested.len > 0 and !std.mem.eql(u8, requested, "codegraff");
    try w.print("<details class=\"cp-provider-section cp-provider-other\"{s}><summary><span><small>Advanced</small><strong>Other providers</strong></span><span>Direct developer connections</span></summary><div class=\"cp-provider-ledger\">", .{if (open) " open" else ""});
    for (descriptors) |provider| {
        if (std.mem.eql(u8, provider.id, "codegraff")) continue;
        const current = findSetting(settings, provider.id);
        if (provider.legacy and current == null) continue;
        try w.print("<details id=\"provider-{s}\" class=\"cp-provider-row\"{s}><summary><span><strong>{s}</strong><small>{s}</small></span><span>{s}</span></summary><div class=\"cp-provider-row-body\"><p>{s}</p>", .{ lib.ui.escapeSafe(req.allocator, provider.id), if (std.mem.eql(u8, provider.id, requested)) " open" else "", lib.ui.escapeSafe(req.allocator, provider.name), if (provider.legacy) "Legacy connection" else "Direct API connection", if (current) |setting| liveStatusLabel(setting) else "Not connected", lib.ui.escapeSafe(req.allocator, provider.description) });
        if (provider.legacy) {
            try w.writeAll("<p>Existing browser connections remain usable until disconnected. New legacy connections are not offered.</p>");
        } else {
            try renderDirectForm(req, w, provider, current);
        }
        if (current) |setting| {
            try w.print("<div class=\"cp-provider-actions\"><form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.test\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Test connection</button></form>", .{lib.ui.escapeSafe(req.allocator, setting.provider)});
            if (std.mem.eql(u8, setting.status, "connected") and !setting.active_for_generation) try w.print("<form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.activate\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Use for answers</button></form>", .{lib.ui.escapeSafe(req.allocator, setting.provider)});
            try w.print("<form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-confirm=\"Disconnect this provider?\" data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.disconnect\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-danger\" type=\"submit\">Disconnect</button></form></div>", .{lib.ui.escapeSafe(req.allocator, setting.provider)});
        }
        try w.writeAll("</div></details>");
    }
    try w.writeAll("</div></details>");
}

fn renderDirectForm(req: mer.Request, w: anytype, provider: lib.types.ProviderDescriptor, current: ?lib.types.ProviderStatusResponse) !void {
    const model = if (current) |item| item.model else if (provider.models.len > 0) provider.models[0] else "";
    const endpoint = if (current) |item| item.endpoint else provider.endpoint;
    const reactivate = if (current) |item| item.active_for_generation else false;
    try w.print("<form class=\"wb-m3-form cp-provider-direct-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-provider-save{s} data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.save\"><input type=\"hidden\" name=\"provider\" value=\"{s}\"><label class=\"cp-field\"><span>{s}</span><input type=\"password\" name=\"api_key\" minlength=\"8\" maxlength=\"4096\" autocomplete=\"new-password\"{s}></label><label class=\"cp-field\"><span>{s}</span><input name=\"model\" value=\"{s}\" maxlength=\"100\" required></label>", .{ if (reactivate) " data-provider-activate" else "", lib.ui.escapeSafe(req.allocator, provider.id), if (current == null) "API key" else "Replacement API key (optional)", if (current == null) " required" else "", if (std.mem.eql(u8, provider.id, "azure_openai")) "Deployment name" else "Model", lib.ui.escapeSafe(req.allocator, model) });
    if (std.mem.eql(u8, provider.endpoint_mode, "custom")) try w.print("<label class=\"cp-field\"><span>Endpoint URL</span><input type=\"url\" name=\"endpoint\" value=\"{s}\" maxlength=\"500\" required></label>", .{lib.ui.escapeSafe(req.allocator, endpoint)});
    try w.writeAll("<button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save and test</button><p class=\"cp-form-status\" role=\"status\"></p></form>");
}

fn renderDemo(req: mer.Request) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("providers render failed");
    w.writeAll("<header class=\"cp-page-header wb-m3-header\"><div><p class=\"cp-page-kicker wb-m3-eyebrow\">Answer connections</p><h1 class=\"cp-page-title wb-m3-title\">AI providers</h1><p class=\"cp-page-sub wb-m3-deck\">Choose how WikiBase creates cited answers and study material. Your sources remain available when no provider is connected.</p></div></header>") catch return mer.internalError("providers render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.settings_tabs, "providers", "Settings", true) catch return mer.internalError("providers render failed");
    w.writeAll("<div class=\"cp-provider-page\"><section class=\"cp-provider-section\"><div class=\"cp-provider-section-head\"><p class=\"eyebrow\">Recommended connection</p><h2>Codegraff</h2><p>Use one account and balance across several answer models.</p></div><div class=\"cp-provider-start\"><div><strong>Not connected</strong><p>Connections are unavailable in this read-only preview.</p></div><button class=\"cp-btn cp-btn-primary\" type=\"button\" disabled>Connect Codegraff</button></div></section><details class=\"cp-provider-section cp-provider-other\"><summary><span><small>Advanced</small><strong>Other providers</strong></span><span>Direct developer connections</span></summary></details></div>") catch return mer.internalError("providers render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn findDescriptor(items: []const lib.types.ProviderDescriptor, id: []const u8) ?lib.types.ProviderDescriptor {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}
fn findSetting(items: []const lib.types.ProviderStatusResponse, id: []const u8) ?lib.types.ProviderStatusResponse {
    for (items) |item| if (std.mem.eql(u8, item.provider, id)) return item;
    return null;
}
fn hasModel(items: []const lib.types.ProviderModelOption, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}
fn hasString(items: []const []const u8, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, id)) return true;
    return false;
}
fn liveStatusLabel(setting: lib.types.ProviderStatusResponse) []const u8 {
    if (setting.active_for_generation) return "Active for answers";
    if (std.mem.eql(u8, setting.status, "connected")) return "Connected";
    if (std.mem.eql(u8, setting.status, "invalid") or std.mem.eql(u8, setting.status, "reauth_required")) return "Needs attention";
    return "Connected · not tested";
}
