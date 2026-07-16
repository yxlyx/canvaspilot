const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Provider settings", .description = "Review AI provider status and capabilities." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Provider settings")) |response| return response;
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
