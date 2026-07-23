const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Provider settings", .description = "Review AI provider status and capabilities." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Provider settings")) |response| return response;
    if (!lib.m3.isExplicitDemo(req)) return renderLive(req);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("providers render failed");
    w.writeAll("<header class=\"cp-page-header wb-m3-header\"><div><p class=\"cp-page-kicker wb-m3-eyebrow\">Synthetic demo · AI connections</p><h1 class=\"cp-page-title wb-m3-title\">AI providers</h1><p class=\"cp-page-sub wb-m3-deck\">Connection status and capabilities. Credentials are write-only and are never rendered back.</p></div></header>") catch return mer.internalError("providers render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.settings_tabs, "providers", "Settings", true) catch return mer.internalError("providers render failed");
    const requested = req.queryParam("provider") orelse lib.mock.providers[0].id;
    var selected_index: usize = 0;
    for (lib.mock.providers, 0..) |provider, index| if (std.mem.eql(u8, provider.id, requested)) {
        selected_index = index;
        break;
    };
    w.writeAll("<div class=\"cp-provider-workspace\"><nav class=\"cp-provider-list\" aria-label=\"AI providers\">") catch return mer.internalError("providers render failed");
    for (lib.mock.providers, 0..) |provider, index| {
        const id = lib.m3.safeId(provider.id, "demo-provider");
        w.print("<a href=\"/settings/providers?mock=1&amp;provider={s}\"{s}><span>{s}</span><small>{s}</small></a>", .{ id, if (index == selected_index) " aria-current=\"page\"" else "", lib.ui.escapeSafe(req.allocator, provider.name), @tagName(provider.status) }) catch return mer.internalError("providers render failed");
    }
    const provider = lib.mock.providers[selected_index];
    const id = lib.m3.safeId(provider.id, "demo-provider");
    w.print("</nav><section class=\"cp-provider-active\"><article class=\"cp-card cp-provider-card surface wb-m3-provider-card\" aria-labelledby=\"provider-title-{s}\"><div class=\"cp-card-title wb-m3-card-head\"><h2 id=\"provider-title-{s}\">{s}</h2><strong class=\"cp-state status-pill cp-state-{s} wb-m3-status\">{s}</strong></div><p>{s}</p><ul class=\"cp-plain-list\">", .{ id, id, lib.ui.escapeSafe(req.allocator, provider.name), @tagName(provider.status), @tagName(provider.status), lib.ui.escapeSafe(req.allocator, provider.status_detail) }) catch return mer.internalError("providers render failed");
    for (provider.capabilities) |capability| w.print("<li>{s}: <strong>{s}</strong></li>", .{ lib.ui.escapeSafe(req.allocator, capability.label), if (capability.available) "available" else "unavailable" }) catch return mer.internalError("providers render failed");
    w.print("</ul><div class=\"cp-provider-form wb-m3-provider-spec\" role=\"group\" aria-labelledby=\"provider-title-{s}\"><p class=\"eyebrow\">Required configuration</p><dl>", .{id}) catch return mer.internalError("providers render failed");
    for (provider.fields) |field| {
        const kind: []const u8 = if (field.kind == .secret) "Write-only" else "Configuration value";
        w.print("<div><dt>{s}</dt><dd>{s}{s}</dd></div>", .{ lib.ui.escapeSafe(req.allocator, field.label), kind, if (field.required) " · required" else "" }) catch return mer.internalError("providers render failed");
    }
    w.writeAll("</dl><p class=\"cp-muted-copy\">Read-only preview. No credential is accepted or stored in demo mode.</p></div></article></section></div>") catch return mer.internalError("providers render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderLive(req: mer.Request) mer.Response {
    const token = lib.session.fromRequest(req).token;
    const descriptors_result = lib.backend.providerDescriptors(req.allocator, token);
    const settings_result = lib.backend.providerSettings(req.allocator, token);
    const descriptors = if (descriptors_result.value) |p| p.value else return lib.m3.liveError(req, "Provider settings", descriptors_result.status);
    const settings = if (settings_result.value) |p| p.value else return lib.m3.liveError(req, "Provider settings", settings_result.status);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header wb-m3-header\"><div><p class=\"cp-page-kicker wb-m3-eyebrow\">AI connections</p><h1 class=\"cp-page-title wb-m3-title\">AI providers</h1><p class=\"cp-page-sub wb-m3-deck\">Configure, test, update, or disconnect a live AI provider. Secret keys are write-only.</p></div></header>") catch return mer.internalError("providers render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.settings_tabs, "providers", "Settings", false) catch return mer.internalError("providers render failed");
    const requested = req.queryParam("provider") orelse if (settings.len > 0) settings[0].provider else if (descriptors.len > 0) descriptors[0].id else "";
    var selected_index: usize = 0;
    for (descriptors, 0..) |provider, index| if (std.mem.eql(u8, provider.id, requested)) {
        selected_index = index;
        break;
    };
    w.writeAll("<div class=\"cp-settings-column\"><section class=\"cp-settings-readonly\"><strong>Write-only credentials.</strong> Stored keys are shown only as a masked state and are never returned to this page.</section></div><div class=\"cp-provider-workspace\"><nav class=\"cp-provider-list\" aria-label=\"AI providers\">") catch return mer.internalError("providers render failed");
    for (descriptors, 0..) |provider, index| {
        const current = findSetting(settings, provider.id);
        const status = if (current) |setting| setting.status else "disconnected";
        w.print("<a href=\"/settings/providers?provider={s}\"{s}><span>{s}</span><small>{s}</small></a>", .{ lib.ui.escapeSafe(req.allocator, provider.id), if (index == selected_index) " aria-current=\"page\"" else "", lib.ui.escapeSafe(req.allocator, provider.name), lib.ui.escapeSafe(req.allocator, status) }) catch return mer.internalError("providers render failed");
    }
    if (descriptors.len == 0) w.writeAll("</nav><section class=\"cp-provider-active\"><div class=\"cp-empty\"><h2>No providers available</h2><p>No provider descriptors were returned.</p></div></section></div>") catch return mer.internalError("providers render failed") else {
        const provider = descriptors[selected_index];
        const current = findSetting(settings, provider.id);
        const status = if (current) |setting| setting.status else "disconnected";
        const model = if (current) |setting| setting.model else if (provider.models.len > 0) provider.models[0] else "";
        const endpoint = if (current) |setting| setting.endpoint else provider.endpoint;
        const fixed_endpoint = std.mem.eql(u8, provider.id, "openai") or std.mem.eql(u8, provider.id, "google_gemini");
        const endpoint_readonly = if (fixed_endpoint) " readonly aria-label=\"Fixed official endpoint URL\"" else "";
        const fixed_note_hidden = if (fixed_endpoint) "" else " hidden";
        w.print("</nav><section class=\"cp-provider-active\"><article class=\"cp-card cp-provider-card surface wb-m3-provider-card\"><div class=\"cp-card-title wb-m3-card-head\"><h2>{s}</h2><strong class=\"cp-state status-pill cp-state-{s} wb-m3-status\">{s}</strong></div><p><strong>API key:</strong> {s}</p><form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.save\"><input type=\"hidden\" name=\"provider\" value=\"{s}\"><label class=\"cp-field wb-m3-field\"><span>Replacement API key</span><input type=\"password\" name=\"api_key\" minlength=\"8\" maxlength=\"4096\" autocomplete=\"new-password\" required aria-describedby=\"key-note-{s}\"></label><small id=\"key-note-{s}\">Required for every save or update. The field is never prefilled.</small><label class=\"cp-field wb-m3-field\"><span>Model</span><input name=\"model\" value=\"{s}\" maxlength=\"100\" required></label><label class=\"cp-field wb-m3-field\"><span>Endpoint URL</span><input type=\"url\" name=\"endpoint\" value=\"{s}\" maxlength=\"500\"{s}></label><small{s}>Official provider endpoints are fixed and shown for information only.</small><button class=\"cp-btn cp-btn-primary\" type=\"submit\">{s} configuration</button><p class=\"cp-form-status wb-m3-form-status\" role=\"status\"></p></form>", .{ lib.ui.escapeSafe(req.allocator, provider.name), lib.ui.escapeSafe(req.allocator, status), lib.ui.escapeSafe(req.allocator, status), if (current != null) "Stored securely (masked)" else "Not configured", lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, model), lib.ui.escapeSafe(req.allocator, endpoint), endpoint_readonly, fixed_note_hidden, if (current == null) "Save" else "Update" }) catch return mer.internalError("providers render failed");
        if (current != null) w.print("<div class=\"cp-action-row wb-m3-actions\"><form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.test\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Test connection</button></form><form class=\"wb-m3-form cp-provider-disconnect\" method=\"post\" action=\"/api/m3\" data-m3-form data-confirm=\"Disconnect this provider and delete its stored credential?\" data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.disconnect\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-danger\" type=\"submit\">Disconnect</button></form></div>", .{ lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, provider.id) }) catch return mer.internalError("providers render failed");
        w.writeAll("</article></section></div>") catch return mer.internalError("providers render failed");
    }
    w.writeAll("<script src=\"/m3.js?v=20260722\" defer></script>") catch return mer.internalError("providers render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}
fn findSetting(settings: []const lib.types.ProviderStatusResponse, id: []const u8) ?lib.types.ProviderStatusResponse {
    for (settings) |setting| if (std.mem.eql(u8, setting.provider, id)) return setting;
    return null;
}

fn fieldInputType(kind: lib.types.ProviderFieldKind) []const u8 {
    return switch (kind) {
        .text => "text",
        .url => "url",
        .secret => "password",
    };
}

fn saveButtonLabel(status: lib.types.ProviderStatus) []const u8 {
    return if (status == .disconnected) "Save configuration" else "Update configuration";
}
