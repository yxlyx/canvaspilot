const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Provider settings", .description = "Review AI provider status and capabilities." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Provider settings")) |response| return response;
    if (!lib.m3.isExplicitDemo(req)) return renderLive(req);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">Provider settings</h1><p class=\"cp-page-sub\">Connection status and capabilities. Credentials are write-only and are never rendered back.</p></div></header>") catch return mer.internalError("providers render failed");
    lib.m3.demoBanner(req, w) catch return mer.internalError("providers render failed");
    w.writeAll("<div class=\"cp-provider-grid\">\n") catch return mer.internalError("providers render failed");
    for (lib.mock.providers) |provider| {
        const name = lib.ui.escapeSafe(req.allocator, provider.name);
        const detail = lib.ui.escapeSafe(req.allocator, provider.status_detail);
        const id = lib.m3.safeId(provider.id, "demo-provider");
        w.print("<article class=\"cp-card cp-provider-card\" aria-labelledby=\"provider-title-{s}\"><div class=\"cp-card-title\"><h2 id=\"provider-title-{s}\">{s}</h2><strong class=\"cp-state cp-state-{s}\">{s}</strong></div><p>{s}</p><ul class=\"cp-plain-list\">", .{ id, id, name, @tagName(provider.status), @tagName(provider.status), detail }) catch return mer.internalError("providers render failed");
        for (provider.capabilities) |capability| {
            const label = lib.ui.escapeSafe(req.allocator, capability.label);
            w.print("<li>{s}: <strong>{s}</strong></li>", .{ label, if (capability.available) "available" else "unavailable" }) catch return mer.internalError("providers render failed");
        }
        w.print("</ul><div class=\"cp-provider-form\" role=\"group\" aria-labelledby=\"provider-title-{s}\" aria-describedby=\"provider-actions-{s}\">", .{ id, id }) catch return mer.internalError("providers render failed");
        for (provider.fields) |field| {
            const field_id = lib.m3.safeId(field.id, "field");
            const input_id = std.fmt.allocPrint(req.allocator, "provider-{s}-{s}", .{ id, field_id }) catch return mer.internalError("providers render failed");
            const label = lib.ui.escapeSafe(req.allocator, field.label);
            const placeholder = lib.ui.escapeSafe(req.allocator, field.placeholder);
            const input_type = fieldInputType(field.kind);
            const autocomplete: []const u8 = if (field.kind == .secret) "new-password" else "off";
            const required: []const u8 = if (field.required) " aria-required=\"true\"" else "";
            const write_only: []const u8 = if (field.kind == .secret) " (write-only)" else "";
            w.print("<label class=\"cp-field\" for=\"{s}\"><span>{s}{s}</span><input id=\"{s}\" name=\"{s}\" type=\"{s}\" autocomplete=\"{s}\" placeholder=\"{s}\" aria-describedby=\"provider-actions-{s}\" aria-disabled=\"true\" readonly{s}></label>", .{ input_id, label, write_only, input_id, field_id, input_type, autocomplete, placeholder, id, required }) catch return mer.internalError("providers render failed");
        }
        w.print(
            \\<div class="cp-action-row">
            \\  <button class="cp-btn cp-btn-ghost" type="button" aria-disabled="true" aria-describedby="provider-actions-{s}">Test connection</button>
            \\  <button class="cp-btn cp-btn-primary" type="button" aria-disabled="true" aria-describedby="provider-actions-{s}">{s}</button>
            \\  <button class="cp-btn cp-btn-danger" type="button" aria-disabled="true" aria-describedby="provider-actions-{s}">Disconnect</button>
            \\</div>
            \\<ul class="cp-action-notes" id="provider-actions-{s}">
            \\  <li>Test is unavailable until a backend connectivity probe exists.</li>
            \\  <li>{s} is unavailable; this demo submits and stores no field values.</li>
            \\  <li>Disconnect is unavailable until an authenticated mutation contract exists.</li>
            \\</ul></div></article>
        , .{ id, id, saveButtonLabel(provider.status), id, id, saveButtonLabel(provider.status) }) catch return mer.internalError("providers render failed");
    }
    w.writeAll("</div>") catch return mer.internalError("providers render failed");
    return lib.ui.htmlResponse(&buf);
}

fn renderLive(req: mer.Request) mer.Response {
    const token = lib.session.fromRequest(req).token;
    const descriptors_result = lib.backend.providerDescriptors(req.allocator, token);
    const settings_result = lib.backend.providerSettings(req.allocator, token);
    const descriptors = if (descriptors_result.value) |p| p.value else return lib.m3.liveError(req, "Provider settings", descriptors_result.status);
    const settings = if (settings_result.value) |p| p.value else return lib.m3.liveError(req, "Provider settings", settings_result.status);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">Provider settings</h1><p class=\"cp-page-sub\">Configure, test, update, or disconnect a live AI provider. Secret keys are write-only.</p></div></header><section class=\"cp-card cp-privacy-note\"><h2>Credential safety</h2><p>Stored keys are represented only as a masked state. Updating a provider always requires entering a replacement key; the existing key is never returned to this page.</p></section><div class=\"cp-provider-grid\">") catch return mer.internalError("providers render failed");
    for (descriptors) |provider| {
        const current = findSetting(settings, provider.id);
        const status = if (current) |s| s.status else "disconnected";
        const model = if (current) |s| s.model else if (provider.models.len > 0) provider.models[0] else "";
        const endpoint = if (current) |s| s.endpoint else provider.endpoint;
        const fixed_endpoint = std.mem.eql(u8, provider.id, "openai") or std.mem.eql(u8, provider.id, "google_gemini");
        const endpoint_readonly = if (fixed_endpoint) " readonly aria-label=\"Fixed official endpoint URL\"" else "";
        const fixed_note_hidden = if (fixed_endpoint) "" else " hidden";
        w.print("<article class=\"cp-card cp-provider-card\"><div class=\"cp-card-title\"><h2>{s}</h2><strong class=\"cp-state cp-state-{s}\">{s}</strong></div><p><strong>API key:</strong> {s}</p><form method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.save\"><input type=\"hidden\" name=\"provider\" value=\"{s}\"><label class=\"cp-field\"><span>Replacement API key</span><input type=\"password\" name=\"api_key\" minlength=\"8\" maxlength=\"4096\" autocomplete=\"new-password\" required aria-describedby=\"key-note-{s}\"></label><small id=\"key-note-{s}\">Required for every save or update. The field is never prefilled.</small><label class=\"cp-field\"><span>Model</span><input name=\"model\" value=\"{s}\" maxlength=\"100\" required></label><label class=\"cp-field\"><span>Endpoint URL</span><input type=\"url\" name=\"endpoint\" value=\"{s}\" maxlength=\"500\"{s}></label><small{s}>Official provider endpoints are fixed and shown for information only.</small><button class=\"cp-btn cp-btn-primary\" type=\"submit\">{s} configuration</button><p class=\"cp-form-status\" role=\"status\"></p></form>", .{ lib.ui.escapeSafe(req.allocator, provider.name), lib.ui.escapeSafe(req.allocator, status), lib.ui.escapeSafe(req.allocator, status), if (current != null) "Stored securely (masked)" else "Not configured", lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, model), lib.ui.escapeSafe(req.allocator, endpoint), endpoint_readonly, fixed_note_hidden, if (current == null) "Save" else "Update" }) catch return mer.internalError("providers render failed");
        if (current != null) w.print("<div class=\"cp-action-row\"><form method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.test\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Test connection</button></form><form method=\"post\" action=\"/api/m3\" data-m3-form data-confirm=\"Disconnect this provider and delete its stored credential?\" data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.disconnect\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-danger\" type=\"submit\">Disconnect</button></form></div>", .{ lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, provider.id) }) catch return mer.internalError("providers render failed");
        w.writeAll("</article>") catch return mer.internalError("providers render failed");
    }
    w.writeAll("</div><script src=\"/m3.js?v=20260721\" defer></script>") catch return mer.internalError("providers render failed");
    return lib.ui.htmlResponse(&buf);
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
