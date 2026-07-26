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
    w.writeAll("<header class=\"cp-page-header wb-m3-header\"><div><p class=\"cp-page-kicker wb-m3-eyebrow\">AI connections</p><h1 class=\"cp-page-title wb-m3-title\">AI providers</h1><p class=\"cp-page-sub wb-m3-deck\">Connect through a secure browser flow when available, or use a write-only developer key.</p></div></header>") catch return mer.internalError("providers render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.settings_tabs, "providers", "Settings", false) catch return mer.internalError("providers render failed");
    const requested = req.queryParam("provider") orelse if (settings.len > 0) settings[0].provider else if (descriptors.len > 0) descriptors[0].id else "";
    var selected_index: usize = 0;
    for (descriptors, 0..) |provider, index| if (std.mem.eql(u8, provider.id, requested)) {
        selected_index = index;
        break;
    };
    w.writeAll("<div class=\"cp-provider-guidance\"><section><p class=\"eyebrow\">Choose how to connect</p><h2>Account sign-in or developer key.</h2><p>Browser sign-in uses the connected account plan. API-key providers use separate developer billing; set a spend limit in that provider's console.</p></section><section><p class=\"eyebrow\">Retrieval</p><h2>Your source search stays stable.</h2><p>The active provider powers cited answers. Search embeddings and deterministic study guides remain managed by the workspace.</p></section></div><div class=\"cp-provider-workspace\"><nav class=\"cp-provider-list\" aria-label=\"AI providers\">") catch return mer.internalError("providers render failed");
    for (descriptors, 0..) |provider, index| {
        const current = findSetting(settings, provider.id);
        const status = if (current) |setting| liveStatusLabel(setting) else "Not connected";
        w.print("<a href=\"/settings/providers?provider={s}\"{s}><span>{s}</span><small>{s}</small></a>", .{ lib.ui.escapeSafe(req.allocator, provider.id), if (index == selected_index) " aria-current=\"page\"" else "", lib.ui.escapeSafe(req.allocator, provider.name), lib.ui.escapeSafe(req.allocator, status) }) catch return mer.internalError("providers render failed");
    }
    if (descriptors.len == 0) w.writeAll("</nav><section class=\"cp-provider-active\"><div class=\"cp-empty\"><h2>No providers available</h2><p>No provider descriptors were returned.</p></div></section></div>") catch return mer.internalError("providers render failed") else {
        const provider = descriptors[selected_index];
        const current = findSetting(settings, provider.id);
        const status = if (current) |setting| liveStatusLabel(setting) else "Not connected";
        const model = if (current) |setting| setting.model else if (provider.models.len > 0) provider.models[0] else "";
        const endpoint = if (current) |setting| setting.endpoint else provider.endpoint;
        const fixed_endpoint = std.mem.eql(u8, provider.endpoint_mode, "fixed");
        const endpoint_readonly = if (fixed_endpoint) " readonly aria-label=\"Fixed official endpoint URL\"" else "";
        const fixed_note_hidden = if (fixed_endpoint) "" else " hidden";
        const status_class = if (current) |setting| setting.status else "disconnected";
        w.print("</nav><section class=\"cp-provider-active\"><article class=\"cp-card cp-provider-card surface wb-m3-provider-card\"><div class=\"cp-card-title wb-m3-card-head\"><div><p class=\"eyebrow\">Generation provider</p><h2>{s}</h2></div><strong class=\"cp-state status-pill cp-state-{s} wb-m3-status\">{s}</strong></div><p class=\"cp-provider-description\">{s}</p><ul class=\"cp-provider-capabilities\">", .{ lib.ui.escapeSafe(req.allocator, provider.name), lib.ui.escapeSafe(req.allocator, status_class), lib.ui.escapeSafe(req.allocator, status), lib.ui.escapeSafe(req.allocator, provider.description) }) catch return mer.internalError("providers render failed");
        for (provider.capabilities) |capability| w.print("<li>{s}</li>", .{lib.ui.escapeSafe(req.allocator, capability)}) catch return mer.internalError("providers render failed");
        w.print("</ul><aside class=\"cp-provider-billing\"><strong>Before you connect</strong><p>{s}</p>", .{lib.ui.escapeSafe(req.allocator, provider.billing_note)}) catch return mer.internalError("providers render failed");
        if (provider.setup_url.len > 0) w.print("<a href=\"{s}\" target=\"_blank\" rel=\"noopener noreferrer\">Open developer setup ↗</a>", .{lib.ui.escapeSafe(req.allocator, provider.setup_url)}) catch return mer.internalError("providers render failed");
        w.writeAll("</aside>") catch return mer.internalError("providers render failed");
        if (req.queryParam("auth")) |auth_result| {
            if (std.mem.eql(u8, auth_result, "connected")) w.writeAll("<div class=\"notice notice-success cp-provider-error\" role=\"status\"><strong>Browser sign-in complete</strong><span>Your account is connected. Tokens stay encrypted on the server.</span></div>") catch return mer.internalError("providers render failed") else w.writeAll("<div class=\"notice notice-warn cp-provider-error\" role=\"alert\"><strong>Browser sign-in was not completed</strong><span>Try again. No incomplete credential is used for answers.</span></div>") catch return mer.internalError("providers render failed");
        }
        if (current) |setting| if (setting.last_error) |reason| w.print("<div class=\"notice notice-warn cp-provider-error\" role=\"status\"><strong>Connection needs attention</strong><span>{s}</span></div>", .{lib.ui.escapeSafe(req.allocator, reason)}) catch return mer.internalError("providers render failed");
        if (oauthMethod(provider)) |auth_method| {
            if (current) |setting| if (setting.provider_account_label) |account| w.print("<dl class=\"cp-provider-account\"><div><dt>Connected account</dt><dd>{s}</dd></div><div><dt>Authentication</dt><dd>Browser sign-in</dd></div><div><dt>Model</dt><dd>{s}</dd></div></dl>", .{ lib.ui.escapeSafe(req.allocator, account), lib.ui.escapeSafe(req.allocator, setting.model) }) catch return mer.internalError("providers render failed");
            w.print("<form class=\"wb-m3-form cp-provider-setup cp-provider-browser\" method=\"post\" action=\"/api/m3\" data-m3-form><input type=\"hidden\" name=\"action\" value=\"provider.auth.start\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><input type=\"hidden\" name=\"return_path\" value=\"/settings/providers?provider={s}\"><div class=\"cp-provider-auth-choice\"><span class=\"cp-provider-auth-icon\" aria-hidden=\"true\">↗</span><div><strong>{s}</strong><small>Uses PKCE and a one-time, 10-minute sign-in session. Credentials never enter browser storage.</small></div></div><button class=\"cp-btn cp-btn-primary\" type=\"submit\"{s}>{s}</button><p class=\"cp-form-status wb-m3-form-status\" role=\"status\"></p><noscript><small>Submitting redirects this page to the provider and returns here after authorization.</small></noscript></form>", .{ lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, auth_method.label), if (auth_method.enabled) "" else " disabled aria-disabled=\"true\"", if (current == null) "Sign in through browser" else "Reconnect through browser" }) catch return mer.internalError("providers render failed");
            if (!auth_method.enabled) if (auth_method.unavailable_reason) |reason| w.print("<p class=\"cp-muted-copy cp-provider-unavailable\">{s}</p>", .{lib.ui.escapeSafe(req.allocator, reason)}) catch return mer.internalError("providers render failed");
            w.writeAll("<aside class=\"cp-provider-disclosure\"><strong>What is sent</strong><p>When this provider is active, your question, recent chat turns, and the selected local source excerpts are sent to the provider. During connection, only authentication metadata and account identity are exchanged; workspace questions and sources are not sent.</p></aside>") catch return mer.internalError("providers render failed");
        } else {
            w.print("<form class=\"wb-m3-form cp-provider-setup\" method=\"post\" action=\"/api/m3\" data-m3-form data-provider-save data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.save\"><input type=\"hidden\" name=\"provider\" value=\"{s}\"><label class=\"cp-field wb-m3-field\"><span>{s}</span><input type=\"password\" name=\"api_key\" minlength=\"8\" maxlength=\"4096\" autocomplete=\"new-password\"{s} aria-describedby=\"key-note-{s}\"></label><small id=\"key-note-{s}\">{s}</small>", .{ lib.ui.escapeSafe(req.allocator, provider.id), if (current == null) "API key" else "Replacement API key (optional)", if (current == null) " required" else "", lib.ui.escapeSafe(req.allocator, provider.id), lib.ui.escapeSafe(req.allocator, provider.id), if (current == null) "Stored encrypted and never shown again." else "Leave blank to keep the stored credential." }) catch return mer.internalError("providers render failed");
            if (provider.models.len > 0) {
                w.writeAll("<label class=\"cp-field wb-m3-field\"><span>Model</span><select name=\"model\" required>") catch return mer.internalError("providers render failed");
                for (provider.models) |item| w.print("<option value=\"{s}\"{s}>{s}</option>", .{ lib.ui.escapeSafe(req.allocator, item), if (std.mem.eql(u8, item, model)) " selected" else "", lib.ui.escapeSafe(req.allocator, item) }) catch return mer.internalError("providers render failed");
                w.writeAll("</select></label>") catch return mer.internalError("providers render failed");
            } else w.print("<label class=\"cp-field wb-m3-field\"><span>{s}</span><input name=\"model\" value=\"{s}\" maxlength=\"100\" placeholder=\"{s}\" required></label>", .{ if (std.mem.eql(u8, provider.id, "azure_openai")) "Deployment name" else "Model ID", lib.ui.escapeSafe(req.allocator, model), if (std.mem.eql(u8, provider.id, "azure_openai")) "e.g. course-gpt" else "e.g. llama-3.1-70b" }) catch return mer.internalError("providers render failed");
            w.print("<label class=\"cp-field wb-m3-field\"><span>Endpoint URL</span><input type=\"url\" name=\"endpoint\" value=\"{s}\" maxlength=\"500\"{s}></label><small{s}>Official endpoint; it cannot be changed.</small><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save and test connection</button><p class=\"cp-form-status wb-m3-form-status\" role=\"status\"></p><noscript><small>Saving stores the configuration. Use Test connection afterward to validate it.</small></noscript></form>", .{ lib.ui.escapeSafe(req.allocator, endpoint), endpoint_readonly, fixed_note_hidden }) catch return mer.internalError("providers render failed");
        }
        if (current != null) {
            const disconnect_confirm = if (current.?.active_for_generation) "Disconnect this active provider and delete its stored credential? Answers will return to the workspace-managed fallback." else "Disconnect this provider and delete its stored credential?";
            w.writeAll("<div class=\"cp-action-row wb-m3-actions\">") catch return mer.internalError("providers render failed");
            if (std.mem.eql(u8, current.?.status, "connected") and !current.?.active_for_generation) w.print("<form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.activate\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Use for answers</button></form>", .{lib.ui.escapeSafe(req.allocator, provider.id)}) catch return mer.internalError("providers render failed");
            w.print("<form class=\"wb-m3-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.test\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Test connection</button></form><form class=\"wb-m3-form cp-provider-disconnect\" method=\"post\" action=\"/api/m3\" data-m3-form data-confirm=\"{s}\" data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"provider.disconnect\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-danger\" type=\"submit\">Disconnect</button></form></div>", .{ lib.ui.escapeSafe(req.allocator, provider.id), disconnect_confirm, lib.ui.escapeSafe(req.allocator, provider.id) }) catch return mer.internalError("providers render failed");
        }
        w.writeAll("</article></section></div>") catch return mer.internalError("providers render failed");
    }
    w.writeAll("<script src=\"/m3.js?v=20260801\" defer></script>") catch return mer.internalError("providers render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}
fn oauthMethod(provider: lib.types.ProviderDescriptor) ?lib.types.ProviderAuthMethodDescriptor {
    for (provider.auth_methods) |method| if (std.mem.eql(u8, method.kind, "oauth_code")) return method;
    return null;
}

fn findSetting(settings: []const lib.types.ProviderStatusResponse, id: []const u8) ?lib.types.ProviderStatusResponse {
    for (settings) |setting| if (std.mem.eql(u8, setting.provider, id)) return setting;
    return null;
}

fn liveStatusLabel(setting: lib.types.ProviderStatusResponse) []const u8 {
    if (std.mem.eql(u8, setting.status, "invalid") or std.mem.eql(u8, setting.status, "reauth_required")) return "Reconnect required";
    if (setting.active_for_generation) return "Active for answers";
    if (std.mem.eql(u8, setting.status, "connected")) return "Connected";
    return "Saved · not tested";
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
