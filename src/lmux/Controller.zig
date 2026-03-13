const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const AppState = @import("AppState.zig").AppState;
const attention = @import("attention.zig");
const ghostty = @import("ghostty/main.zig");
const ids = @import("ids.zig");
const ipc_protocol = @import("ipc/protocol.zig");
const ipc_server = @import("ipc/server.zig");
const key_specs = @import("keys.zig");
const metadata = @import("metadata.zig");
const ui_theme = @import("ui_theme.zig");

const GhosttyApplication = @import("../apprt/gtk/class/application.zig").Application;
const GhosttyTab = @import("../apprt/gtk/class/tab.zig").Tab;
const GhosttySurface = @import("../apprt/gtk/class/surface.zig").Surface;

const UUID = ids.UUID;

pub const Controller = struct {
    alloc: std.mem.Allocator,
    app: *GhosttyApplication,
    state: AppState,

    window: ?*adw.ApplicationWindow = null,
    tab_rail: ?*gtk.Box = null,
    pane_strip: ?*gtk.Box = null,
    terminal_host: ?*gtk.Frame = null,
    active_title_label: ?*gtk.Label = null,
    active_subtitle_label: ?*gtk.Label = null,
    cwd_label: ?*gtk.Label = null,
    branch_label: ?*gtk.Label = null,
    pr_label: ?*gtk.Label = null,
    pr_subtitle_label: ?*gtk.Label = null,
    ports_box: ?*gtk.Box = null,
    latest_notification_button: ?*gtk.Button = null,
    latest_notification_label: ?*gtk.Label = null,
    drawer_revealer: ?*gtk.Revealer = null,
    drawer_summary_label: ?*gtk.Label = null,
    drawer_toggle_button: ?*gtk.Button = null,
    drawer_badge_label: ?*gtk.Label = null,
    drawer_jump_button: ?*gtk.Button = null,
    drawer_list: ?*gtk.Box = null,
    current_tab: ?UUID = null,
    drawer_open: bool = false,

    tab_runtimes: std.AutoArrayHashMapUnmanaged(UUID, TabRuntime) = .{},
    pane_runtimes: std.AutoArrayHashMapUnmanaged(UUID, PaneRuntime) = .{},
    surface_index: std.AutoArrayHashMapUnmanaged(usize, UUID) = .{},
    notification_actions: std.AutoArrayHashMapUnmanaged(UUID, *NotificationClickData) = .{},

    request_mutex: std.Thread.Mutex = .{},
    requests: std.ArrayListUnmanaged(*PendingRequest) = .{},
    request_scheduled: bool = false,
    server_thread: ?std.Thread = null,
    metadata_timer: ?c_uint = null,

    const TabRuntime = struct {
        widget: *GhosttyTab,
        button: *gtk.Button,
        title_label: *gtk.Label,
        subtitle_label: *gtk.Label,
        badge_label: *gtk.Label,
        click_data: *TabClickData,
    };

    const PaneRuntime = struct {
        surface: *GhosttySurface,
        chip_button: *gtk.Button,
        chip_label: *gtk.Label,
        chip_badge: *gtk.Label,
        click_data: *PaneClickData,
    };

    const TabClickData = struct {
        controller: *Controller,
        tab_id: UUID,
    };

    const PaneClickData = struct {
        controller: *Controller,
        pane_id: UUID,
    };

    const NotificationClickData = struct {
        controller: *Controller,
        notification_id: UUID,
    };

    const PendingRequest = struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
        line: []u8,
        response: ?[]u8 = null,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        app: *GhosttyApplication,
    ) !*Controller {
        const controller = try alloc.create(Controller);
        controller.* = .{
            .alloc = alloc,
            .app = app,
            .state = try AppState.init(alloc),
        };
        return controller;
    }

    pub fn deinit(self: *Controller) void {
        if (self.metadata_timer) |source_id| _ = glib.Source.remove(source_id);

        var tab_it = self.tab_runtimes.iterator();
        while (tab_it.next()) |entry| {
            entry.value_ptr.widget.unref();
            entry.value_ptr.button.unref();
            self.alloc.destroy(entry.value_ptr.click_data);
        }

        var pane_it = self.pane_runtimes.iterator();
        while (pane_it.next()) |entry| {
            entry.value_ptr.chip_button.unref();
            self.alloc.destroy(entry.value_ptr.click_data);
        }

        var action_it = self.notification_actions.iterator();
        while (action_it.next()) |entry| self.alloc.destroy(entry.value_ptr.*);

        self.state.deinit();
        self.tab_runtimes.deinit(self.alloc);
        self.pane_runtimes.deinit(self.alloc);
        self.surface_index.deinit(self.alloc);
        self.notification_actions.deinit(self.alloc);
        self.requests.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn build(self: *Controller) !void {
        const window = gobject.ext.newInstance(adw.ApplicationWindow, .{
            .application = self.app,
        });
        self.window = window;

        window.as(gtk.Window).setTitle("Lmux");
        window.as(gtk.Window).setDefaultSize(1560, 960);

        const root = gtk.Box.new(.vertical, 0);
        window.setContent(root.as(gtk.Widget));

        const header = adw.HeaderBar.new();
        root.append(header.as(gtk.Widget));

        const header_title = gtk.Label.new("Lmux");
        header_title.as(gtk.Widget).addCssClass("title-3");
        header.setTitleWidget(header_title.as(gtk.Widget));

        const shell = gtk.Box.new(.horizontal, 18);
        shell.as(gtk.Widget).addCssClass("lmux-shell");
        shell.as(gtk.Widget).setHexpand(1);
        shell.as(gtk.Widget).setVexpand(1);
        root.append(shell.as(gtk.Widget));

        try self.buildRail(shell);
        try self.buildWorkspace(shell);
        try self.buildDrawer(shell);

        ui_theme.install(window);

        try self.createInitialTab();
        self.refreshUi();
        self.startServer();
        self.startMetadataRefresh();

        gtk.Window.present(window.as(gtk.Window));
    }

    fn buildRail(self: *Controller, shell: *gtk.Box) !void {
        const rail = gtk.Box.new(.vertical, 16);
        rail.as(gtk.Widget).addCssClass("lmux-rail");
        rail.as(gtk.Widget).setSizeRequest(@intCast(self.state.config.sidebar_width), -1);
        rail.as(gtk.Widget).setVexpand(1);
        shell.append(rail.as(gtk.Widget));

        const top = gtk.Box.new(.horizontal, 8);
        rail.append(top.as(gtk.Widget));

        const tabs_title = gtk.Label.new("Tabs");
        tabs_title.as(gtk.Widget).addCssClass("lmux-section-title");
        tabs_title.as(gtk.Widget).setHalign(.start);
        tabs_title.as(gtk.Widget).setHexpand(1);
        top.append(tabs_title.as(gtk.Widget));

        const new_tab = gtk.Button.new();
        new_tab.setLabel("+");
        new_tab.as(gtk.Widget).addCssClass("lmux-rail-add");
        _ = gtk.Button.signals.clicked.connect(new_tab, *Controller, createTabClicked, self, .{});
        top.append(new_tab.as(gtk.Widget));

        const tab_rail = gtk.Box.new(.vertical, 8);
        tab_rail.as(gtk.Widget).setVexpand(1);
        rail.append(tab_rail.as(gtk.Widget));
        self.tab_rail = tab_rail;

        const divider = gtk.Box.new(.vertical, 0);
        divider.as(gtk.Widget).addCssClass("lmux-section-divider");
        divider.as(gtk.Widget).setSizeRequest(-1, 1);
        rail.append(divider.as(gtk.Widget));

        const context_card = gtk.Box.new(.vertical, 10);
        context_card.as(gtk.Widget).addCssClass("lmux-context-card");
        rail.append(context_card.as(gtk.Widget));

        const context_title = gtk.Label.new("Focused Pane");
        context_title.as(gtk.Widget).addCssClass("lmux-section-title");
        context_title.as(gtk.Widget).setHalign(.start);
        context_card.append(context_title.as(gtk.Widget));

        self.cwd_label = try addContextValue(context_card, "Working directory", "Shell");
        self.branch_label = try addContextValue(context_card, "Git branch", "Not in a repository");
        self.pr_label = try addContextValue(context_card, "Pull request", "Unavailable");
        self.pr_subtitle_label = try addSubtleValue(context_card, "");
        self.ports_box = try addContextChips(context_card, "Listening ports");
        self.latest_notification_button, self.latest_notification_label = try addContextAction(
            context_card,
            "Latest notification",
            "No notifications",
            latestNotificationClicked,
            self,
        );
    }

    fn buildWorkspace(self: *Controller, shell: *gtk.Box) !void {
        const workspace = gtk.Box.new(.vertical, 12);
        workspace.as(gtk.Widget).addCssClass("lmux-workspace");
        workspace.as(gtk.Widget).setHexpand(1);
        workspace.as(gtk.Widget).setVexpand(1);
        shell.append(workspace.as(gtk.Widget));

        const topbar = gtk.Box.new(.horizontal, 12);
        topbar.as(gtk.Widget).addCssClass("lmux-topbar");
        workspace.append(topbar.as(gtk.Widget));

        const heading = gtk.Box.new(.vertical, 2);
        heading.as(gtk.Widget).setHexpand(1);
        topbar.append(heading.as(gtk.Widget));

        const active_title = gtk.Label.new("Shell");
        active_title.as(gtk.Widget).addCssClass("lmux-active-title");
        active_title.as(gtk.Widget).setHalign(.start);
        heading.append(active_title.as(gtk.Widget));
        self.active_title_label = active_title;

        const active_subtitle = gtk.Label.new("No active pane");
        active_subtitle.as(gtk.Widget).addCssClass("lmux-meta");
        active_subtitle.as(gtk.Widget).setHalign(.start);
        heading.append(active_subtitle.as(gtk.Widget));
        self.active_subtitle_label = active_subtitle;

        const pane_strip = gtk.Box.new(.horizontal, 8);
        pane_strip.as(gtk.Widget).setHexpand(1);
        topbar.append(pane_strip.as(gtk.Widget));
        self.pane_strip = pane_strip;

        const actions = gtk.Box.new(.horizontal, 8);
        topbar.append(actions.as(gtk.Widget));

        try addSplitButton(actions, "L", splitLeftClicked, self);
        try addSplitButton(actions, "R", splitRightClicked, self);
        try addSplitButton(actions, "U", splitUpClicked, self);
        try addSplitButton(actions, "D", splitDownClicked, self);

        const drawer_toggle = gtk.Button.new();
        drawer_toggle.as(gtk.Widget).addCssClass("lmux-ghost-button");
        const toggle_row = gtk.Box.new(.horizontal, 8);
        const toggle_label = gtk.Label.new("Notifications");
        toggle_row.append(toggle_label.as(gtk.Widget));
        const toggle_badge = gtk.Label.new("0");
        toggle_badge.as(gtk.Widget).addCssClass("lmux-badge");
        toggle_row.append(toggle_badge.as(gtk.Widget));
        drawer_toggle.setChild(toggle_row.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(drawer_toggle, *Controller, drawerToggleClicked, self, .{});
        actions.append(drawer_toggle.as(gtk.Widget));
        self.drawer_toggle_button = drawer_toggle;
        self.drawer_badge_label = toggle_badge;

        const terminal_host = gtk.Frame.new(null);
        terminal_host.as(gtk.Widget).addCssClass("lmux-terminal-frame");
        terminal_host.as(gtk.Widget).setHexpand(1);
        terminal_host.as(gtk.Widget).setVexpand(1);
        workspace.append(terminal_host.as(gtk.Widget));
        self.terminal_host = terminal_host;
    }

    fn buildDrawer(self: *Controller, shell: *gtk.Box) !void {
        const revealer = gtk.Revealer.new();
        revealer.as(gtk.Widget).setVexpand(1);
        revealer.setRevealChild(@intFromBool(false));
        revealer.setTransitionDuration(180);
        revealer.setTransitionType(.slide_left);
        shell.append(revealer.as(gtk.Widget));
        self.drawer_revealer = revealer;

        const drawer = gtk.Box.new(.vertical, 12);
        drawer.as(gtk.Widget).addCssClass("lmux-drawer");
        drawer.as(gtk.Widget).setSizeRequest(@intCast(self.state.config.notification_panel_width), -1);
        revealer.setChild(drawer.as(gtk.Widget));

        const header = gtk.Box.new(.horizontal, 8);
        drawer.append(header.as(gtk.Widget));

        const title_wrap = gtk.Box.new(.vertical, 2);
        title_wrap.as(gtk.Widget).setHexpand(1);
        header.append(title_wrap.as(gtk.Widget));

        const drawer_title = gtk.Label.new("Notifications");
        drawer_title.as(gtk.Widget).addCssClass("lmux-section-title");
        drawer_title.as(gtk.Widget).setHalign(.start);
        title_wrap.append(drawer_title.as(gtk.Widget));

        const drawer_summary = gtk.Label.new("0 unread");
        drawer_summary.as(gtk.Widget).addCssClass("lmux-meta");
        drawer_summary.as(gtk.Widget).setHalign(.start);
        title_wrap.append(drawer_summary.as(gtk.Widget));
        self.drawer_summary_label = drawer_summary;

        const jump_button = gtk.Button.new();
        jump_button.setLabel("Jump latest unread");
        jump_button.as(gtk.Widget).addCssClass("lmux-ghost-button");
        _ = gtk.Button.signals.clicked.connect(jump_button, *Controller, jumpLatestClicked, self, .{});
        header.append(jump_button.as(gtk.Widget));
        self.drawer_jump_button = jump_button;

        const scroller = gtk.ScrolledWindow.new();
        scroller.as(gtk.Widget).setHexpand(1);
        scroller.as(gtk.Widget).setVexpand(1);
        drawer.append(scroller.as(gtk.Widget));

        const list = gtk.Box.new(.vertical, 8);
        list.as(gtk.Widget).setVexpand(1);
        scroller.setChild(list.as(gtk.Widget));
        self.drawer_list = list;
    }

    fn startServer(self: *Controller) void {
        if (self.state.socketPath()) |socket_path| {
            self.server_thread = std.Thread.spawn(.{}, serverMain, .{ self, socket_path }) catch null;
        }
    }

    fn serverMain(self: *Controller, socket_path: [:0]const u8) void {
        var server = ipc_server.Server.init(
            self.alloc,
            socket_path,
            .{
                .ctx = self,
                .handleLine = handleLine,
            },
        );
        server.serve() catch {};
    }

    fn startMetadataRefresh(self: *Controller) void {
        self.metadata_timer = glib.timeoutAdd(
            @intCast(self.state.config.metadata_refresh_ms),
            metadataRefreshTick,
            self,
        );
    }

    fn createInitialTab(self: *Controller) !void {
        var params = std.json.ObjectMap.init(self.alloc);
        defer params.deinit();
        const result = try self.state.dispatch(self.alloc, "tab.create", .{ .object = params });
        defer switch (result) {
            .success => |payload| self.alloc.free(payload),
            .failure => {},
        };

        const payload = switch (result) {
            .success => |success| success,
            .failure => |failure| return errorFromFailure(failure),
        };
        const ids_result = try parseCreateTabPayload(self.alloc, payload);
        defer ids_result.deinit();
        try self.createTabRuntime(ids_result.workspace_id, ids_result.tab_id, ids_result.pane_id, .{});
    }

    fn handleLine(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        line: []const u8,
    ) ![]u8 {
        const self: *Controller = @ptrCast(@alignCast(ctx));
        const pending = try alloc.create(PendingRequest);
        errdefer alloc.destroy(pending);
        pending.* = .{
            .line = try alloc.dupe(u8, line),
        };

        self.request_mutex.lock();
        try self.requests.append(self.alloc, pending);
        if (!self.request_scheduled) {
            self.request_scheduled = true;
            _ = glib.idleAdd(processRequestsIdle, self);
        }
        self.request_mutex.unlock();

        pending.mutex.lock();
        defer pending.mutex.unlock();
        while (!pending.done) pending.cond.wait(&pending.mutex);

        const response = pending.response orelse try alloc.dupe(u8, "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"runtime_error\",\"message\":\"no response\"}}\n");
        alloc.free(pending.line);
        alloc.destroy(pending);
        return response;
    }

    fn processRequestsIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Controller = @ptrCast(@alignCast(ud orelse return 0));

        while (true) {
            self.request_mutex.lock();
            const pending = if (self.requests.items.len > 0)
                self.requests.orderedRemove(0)
            else blk: {
                self.request_scheduled = false;
                self.request_mutex.unlock();
                break :blk null;
            };
            self.request_mutex.unlock();

            const request = pending orelse break;
            const response = self.executeRequestLine(self.alloc, request.line) catch |err|
                std.fmt.allocPrint(self.alloc, "{{\"id\":null,\"ok\":false,\"error\":{{\"code\":\"runtime_error\",\"message\":{f}}}}}\n", .{
                    std.json.fmt(@errorName(err), .{}),
                }) catch null;

            request.mutex.lock();
            request.response = response;
            request.done = true;
            request.cond.signal();
            request.mutex.unlock();
        }

        return 0;
    }

    fn executeRequestLine(
        self: *Controller,
        alloc: std.mem.Allocator,
        line: []const u8,
    ) ![]u8 {
        var parsed = ipc_protocol.parseRequest(alloc, line) catch {
            var out: std.ArrayList(u8) = .{};
            errdefer out.deinit(alloc);
            try ipc_protocol.writeError(
                out.writer(alloc),
                null,
                "invalid_json",
                "request must be a JSON object with id, method, and params",
            );
            return try out.toOwnedSlice(alloc);
        };
        defer parsed.deinit();

        const result = try self.dispatchWithRuntime(alloc, parsed.method, parsed.params);
        defer switch (result) {
            .success => |payload| alloc.free(payload),
            .failure => {},
        };

        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(alloc);
        switch (result) {
            .success => |payload| try ipc_protocol.writeSuccess(out.writer(alloc), parsed.id, payload),
            .failure => |failure| try ipc_protocol.writeError(out.writer(alloc), parsed.id, failure.code, failure.message),
        }
        return try out.toOwnedSlice(alloc);
    }

    fn dispatchWithRuntime(
        self: *Controller,
        alloc: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
    ) !AppState.DispatchResult {
        const result = try self.state.dispatch(alloc, method, params);
        if (result != .success) return result;

        const payload = result.success;
        self.applyRuntime(method, params, payload) catch |err| {
            return .{
                .failure = .{
                    .code = "runtime_error",
                    .message = @errorName(err),
                },
            };
        };

        self.refreshUi();
        return result;
    }

    fn applyRuntime(
        self: *Controller,
        method: []const u8,
        params: std.json.Value,
        payload: []const u8,
    ) !void {
        if (std.mem.eql(u8, method, "tab.create")) {
            const created = try parseCreateTabPayload(self.alloc, payload);
            defer created.deinit();
            try self.createTabRuntime(created.workspace_id, created.tab_id, created.pane_id, paneOptions(params));
            return;
        }
        if (std.mem.eql(u8, method, "tab.focus") or std.mem.eql(u8, method, "workspace.focus")) {
            return;
        }
        if (std.mem.eql(u8, method, "pane.split")) {
            const target_pane_id = ids.parse(paramString(params, "pane_id").?) catch return error.InvalidPaneId;
            const new_pane_id = try parseSingleIdPayload(self.alloc, payload, "pane_id");
            defer new_pane_id.deinit();
            try self.splitPaneRuntime(target_pane_id, new_pane_id.value, paramString(params, "direction").?, paneOptions(params));
            return;
        }
        if (std.mem.eql(u8, method, "pane.focus")) {
            const pane_id = ids.parse(paramString(params, "pane_id").?) catch return error.InvalidPaneId;
            self.focusPaneRuntime(pane_id) catch {};
            return;
        }
        if (std.mem.eql(u8, method, "pane.send_text")) {
            const pane_id = ids.parse(paramString(params, "pane_id").?) catch return error.InvalidPaneId;
            const runtime = self.pane_runtimes.get(pane_id) orelse return error.PaneRuntimeNotFound;
            try ghostty.sendText(self.alloc, runtime.surface, paramString(params, "text").?);
            return;
        }
        if (std.mem.eql(u8, method, "pane.send_keys")) {
            const pane_id = ids.parse(paramString(params, "pane_id").?) catch return error.InvalidPaneId;
            const runtime = self.pane_runtimes.get(pane_id) orelse return error.PaneRuntimeNotFound;
            const key_value = params.object.get("keys") orelse return error.InvalidKeySpec;
            const strokes = try key_specs.parseJsonValue(self.alloc, key_value);
            defer key_specs.deinitOwned(self.alloc, strokes);
            try ghostty.sendKeys(self.alloc, runtime.surface, strokes);
            return;
        }
        if (std.mem.eql(u8, method, "notification.jump_latest") or std.mem.eql(u8, method, "notification.activate")) {
            const parsed = try parseSingleIdPayload(self.alloc, payload, "pane_id");
            defer parsed.deinit();
            self.focusPaneRuntime(parsed.value) catch {};
            return;
        }
    }

    fn createTabRuntime(
        self: *Controller,
        workspace_id: UUID,
        tab_id: UUID,
        pane_id: UUID,
        options: ghostty.CreateOptions,
    ) !void {
        _ = workspace_id;
        const tab_widget = try ghostty.newTab(self.alloc, options);
        const button = gtk.Button.new();
        button.as(gtk.Widget).addCssClass("lmux-tab-button");
        button.as(gtk.Widget).setHexpand(1);

        const row = gtk.Box.new(.horizontal, 10);
        const text = gtk.Box.new(.vertical, 2);
        text.as(gtk.Widget).setHexpand(1);
        row.append(text.as(gtk.Widget));

        const title = gtk.Label.new("Shell");
        title.as(gtk.Widget).setHalign(.start);
        text.append(title.as(gtk.Widget));

        const subtitle = gtk.Label.new("");
        subtitle.as(gtk.Widget).addCssClass("lmux-meta");
        subtitle.as(gtk.Widget).setHalign(.start);
        text.append(subtitle.as(gtk.Widget));

        const badge = gtk.Label.new("0");
        badge.as(gtk.Widget).addCssClass("lmux-badge");
        row.append(badge.as(gtk.Widget));

        button.setChild(row.as(gtk.Widget));

        const click_data = try self.alloc.create(TabClickData);
        click_data.* = .{ .controller = self, .tab_id = tab_id };
        _ = gtk.Button.signals.clicked.connect(button, *TabClickData, tabClicked, click_data, .{});
        _ = tab_widget.widget.ref();
        _ = button.ref();

        try self.tab_runtimes.put(self.alloc, tab_id, .{
            .widget = tab_widget.widget,
            .button = button,
            .title_label = title,
            .subtitle_label = subtitle,
            .badge_label = badge,
            .click_data = click_data,
        });

        const pane = ghostty.activePane(tab_widget.widget) orelse return error.SurfaceUnavailable;
        try self.registerPaneRuntime(pane_id, tab_id, pane.surface);
    }

    fn splitPaneRuntime(
        self: *Controller,
        target_pane_id: UUID,
        new_pane_id: UUID,
        direction: []const u8,
        options: ghostty.CreateOptions,
    ) !void {
        const target_pane = self.pane_runtimes.get(target_pane_id) orelse return error.PaneRuntimeNotFound;
        const target_state = self.state.panes.getPtr(target_pane_id) orelse return error.InvalidPaneId;
        const tab_runtime = self.tab_runtimes.get(target_state.tab_id) orelse return error.TabRuntimeNotFound;
        const new_pane = try ghostty.splitPane(self.alloc, tab_runtime.widget, direction, target_pane.surface, options);
        try self.registerPaneRuntime(new_pane_id, target_state.tab_id, new_pane.surface);
    }

    fn registerPaneRuntime(
        self: *Controller,
        pane_id: UUID,
        tab_id: UUID,
        surface: *GhosttySurface,
    ) !void {
        _ = tab_id;

        const chip_button = gtk.Button.new();
        chip_button.as(gtk.Widget).addCssClass("lmux-pane-chip");

        const row = gtk.Box.new(.horizontal, 8);
        const label = gtk.Label.new("Pane");
        row.append(label.as(gtk.Widget));
        const badge = gtk.Label.new("!");
        badge.as(gtk.Widget).addCssClass("lmux-badge");
        row.append(badge.as(gtk.Widget));
        chip_button.setChild(row.as(gtk.Widget));

        const click_data = try self.alloc.create(PaneClickData);
        click_data.* = .{ .controller = self, .pane_id = pane_id };
        _ = gtk.Button.signals.clicked.connect(chip_button, *PaneClickData, paneClicked, click_data, .{});
        _ = chip_button.ref();

        try self.pane_runtimes.put(self.alloc, pane_id, .{
            .surface = surface,
            .chip_button = chip_button,
            .chip_label = label,
            .chip_badge = badge,
            .click_data = click_data,
        });
        try self.surface_index.put(self.alloc, @intFromPtr(surface), pane_id);
        try self.bindSurfaceState(pane_id, surface);
        self.refreshPaneMetadata(pane_id);
    }

    fn bindSurfaceState(
        self: *Controller,
        pane_id: UUID,
        surface: *GhosttySurface,
    ) !void {
        _ = pane_id;
        _ = gobject.Object.signals.notify.connect(
            surface,
            *Controller,
            surfacePwdChanged,
            self,
            .{ .detail = "pwd" },
        );
        _ = gobject.Object.signals.notify.connect(
            surface,
            *Controller,
            surfaceTitleChanged,
            self,
            .{ .detail = "title" },
        );
        _ = gobject.Object.signals.notify.connect(
            surface,
            *Controller,
            surfaceFocusedChanged,
            self,
            .{ .detail = "focused" },
        );
        _ = gobject.Object.signals.notify.connect(
            surface,
            *Controller,
            surfaceChildExitedChanged,
            self,
            .{ .detail = "child-exited" },
        );
        _ = GhosttySurface.signals.bell.connect(
            surface,
            *Controller,
            surfaceBell,
            self,
            .{},
        );

        self.updatePaneFromSurface(surface);
    }

    fn refreshUi(self: *Controller) void {
        self.refreshTabRail();
        self.refreshPaneStrip();
        self.refreshVisibleTab();
        self.refreshActiveHeading();
        self.refreshContextCard();
        self.refreshNotificationDrawer();
        self.refreshDrawerToggle();
        self.refreshAttentionClasses();
        self.syncDrawerState();
    }

    fn refreshTabRail(self: *Controller) void {
        const rail = self.tab_rail orelse return;
        clearBox(rail);

        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        const workspace_id = self.state.focused_workspace orelse return;
        const workspace = self.state.workspaces.getPtr(workspace_id) orelse return;

        for (workspace.tabs.items) |tab_id| {
            const tab = self.state.tabs.getPtr(tab_id) orelse continue;
            const runtime = self.tab_runtimes.getPtr(tab_id) orelse continue;

            const label = self.tabLabelLocked(tab_id, tab);
            defer self.alloc.free(label);
            setLabel(self.alloc, runtime.title_label, label);

            const subtitle = if (tab.unread_count > 0) tab.latest_notification orelse "" else "";
            setLabel(self.alloc, runtime.subtitle_label, subtitle);
            runtime.subtitle_label.as(gtk.Widget).setVisible(@intFromBool(subtitle.len > 0));

            if (tab.unread_count > 0) {
                const unread = std.fmt.allocPrint(self.alloc, "{d}", .{tab.unread_count}) catch null;
                defer if (unread) |text| self.alloc.free(text);
                setLabel(self.alloc, runtime.badge_label, if (unread) |text| text else "!");
            } else {
                setLabel(self.alloc, runtime.badge_label, "0");
            }
            runtime.badge_label.as(gtk.Widget).setVisible(@intFromBool(tab.unread_count > 0));

            resetClasses(runtime.button.as(gtk.Widget), &.{
                "lmux-tab-button-active",
                "lmux-tab-attention",
            });
            if (workspace.focused_tab != null and uuidEq(workspace.focused_tab.?, tab_id)) {
                runtime.button.as(gtk.Widget).addCssClass("lmux-tab-button-active");
            }
            if (tabHasAttentionLocked(self, tab)) {
                runtime.button.as(gtk.Widget).addCssClass("lmux-tab-attention");
            }

            rail.append(runtime.button.as(gtk.Widget));
        }
    }

    fn refreshPaneStrip(self: *Controller) void {
        const strip = self.pane_strip orelse return;
        clearBox(strip);

        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        const pane_ctx = focusedPaneContextLocked(&self.state) orelse return;
        for (pane_ctx.tab.panes.items, 0..) |pane_id, index| {
            const pane = self.state.panes.getPtr(pane_id) orelse continue;
            const runtime = self.pane_runtimes.getPtr(pane_id) orelse continue;

            const label = paneChipLabelLocked(self.alloc, pane, index);
            defer self.alloc.free(label);
            setLabel(self.alloc, runtime.chip_label, label);
            runtime.chip_badge.as(gtk.Widget).setVisible(@intFromBool(pane.attention));

            resetClasses(runtime.chip_button.as(gtk.Widget), &.{
                "lmux-pane-chip-active",
                "lmux-pane-chip-attention",
            });
            if (pane_ctx.tab.focused_pane != null and uuidEq(pane_ctx.tab.focused_pane.?, pane_id)) {
                runtime.chip_button.as(gtk.Widget).addCssClass("lmux-pane-chip-active");
            }
            if (pane.attention) {
                runtime.chip_button.as(gtk.Widget).addCssClass("lmux-pane-chip-attention");
            }

            strip.append(runtime.chip_button.as(gtk.Widget));
        }
    }

    fn refreshVisibleTab(self: *Controller) void {
        const host = self.terminal_host orelse return;

        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        const workspace_id = self.state.focused_workspace orelse {
            host.setChild(null);
            self.current_tab = null;
            return;
        };
        const workspace = self.state.workspaces.getPtr(workspace_id) orelse {
            host.setChild(null);
            self.current_tab = null;
            return;
        };
        const tab_id = workspace.focused_tab orelse {
            host.setChild(null);
            self.current_tab = null;
            return;
        };

        if (self.current_tab != null and uuidEq(self.current_tab.?, tab_id)) return;
        if (self.current_tab != null) host.setChild(null);
        const runtime = self.tab_runtimes.get(tab_id) orelse return;
        host.setChild(runtime.widget.as(gtk.Widget));
        self.current_tab = tab_id;
    }

    fn refreshActiveHeading(self: *Controller) void {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        const pane_ctx = focusedPaneContextLocked(&self.state) orelse {
            setLabel(self.alloc, self.active_title_label, "Shell");
            setLabel(self.alloc, self.active_subtitle_label, "No active pane");
            return;
        };

        const title = pane_ctx.pane.title orelse pane_ctx.tab.title orelse pane_ctx.pane.metadata_snapshot.cwd_basename orelse "Shell";
        const subtitle = pane_ctx.pane.metadata_snapshot.cwd orelse pane_ctx.pane.cwd orelse "No working directory";
        setLabel(self.alloc, self.active_title_label, title);
        setLabel(self.alloc, self.active_subtitle_label, subtitle);
    }

    fn refreshContextCard(self: *Controller) void {
        const ports_box = self.ports_box orelse return;
        clearBox(ports_box);

        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        const pane_ctx = focusedPaneContextLocked(&self.state) orelse {
            setLabel(self.alloc, self.cwd_label, "Shell");
            setLabel(self.alloc, self.branch_label, "Not in a repository");
            setLabel(self.alloc, self.pr_label, "Unavailable");
            setLabel(self.alloc, self.pr_subtitle_label, "");
            self.pr_subtitle_label.?.as(gtk.Widget).setVisible(0);
            appendChipWithAlloc(self.alloc, ports_box, "None");
            setLabel(self.alloc, self.latest_notification_label, "No notifications");
            self.latest_notification_button.?.as(gtk.Widget).setSensitive(0);
            return;
        };

        setLabel(self.alloc, self.cwd_label, pane_ctx.pane.metadata_snapshot.cwd orelse pane_ctx.pane.cwd orelse "Shell");

        const branch = branchText(self.alloc, pane_ctx.pane.metadata_snapshot) catch null;
        defer if (branch) |value| self.alloc.free(value);
        setLabel(self.alloc, self.branch_label, if (branch) |value| value else "Not in a repository");

        const pr_value, const pr_detail = prDisplay(self.alloc, pane_ctx.pane.metadata_snapshot) catch .{ null, null };
        defer if (pr_value) |value| self.alloc.free(value);
        defer if (pr_detail) |value| self.alloc.free(value);
        setLabel(self.alloc, self.pr_label, if (pr_value) |value| value else "Unavailable");
        setLabel(self.alloc, self.pr_subtitle_label, if (pr_detail) |value| value else "");
        self.pr_subtitle_label.?.as(gtk.Widget).setVisible(@intFromBool(pr_detail != null));

        if (pane_ctx.pane.metadata_snapshot.ports_info.ports.len == 0) {
            appendChipWithAlloc(self.alloc, ports_box, "None");
        } else {
            const limit = @min(pane_ctx.pane.metadata_snapshot.ports_info.ports.len, 6);
            for (pane_ctx.pane.metadata_snapshot.ports_info.ports[0..limit]) |port| {
                const text = std.fmt.allocPrint(self.alloc, "{d}", .{port}) catch null;
                defer if (text) |value| self.alloc.free(value);
                appendChipWithAlloc(self.alloc, ports_box, if (text) |value| value else "port");
            }
            if (pane_ctx.pane.metadata_snapshot.ports_info.ports.len > limit) {
                const more = std.fmt.allocPrint(self.alloc, "+{d}", .{pane_ctx.pane.metadata_snapshot.ports_info.ports.len - limit}) catch null;
                defer if (more) |value| self.alloc.free(value);
                appendChipWithAlloc(self.alloc, ports_box, if (more) |value| value else "+");
            }
        }

        const latest = pane_ctx.tab.latest_notification orelse "No notifications";
        setLabel(self.alloc, self.latest_notification_label, latest);
        self.latest_notification_button.?.as(gtk.Widget).setSensitive(@intFromBool(pane_ctx.tab.latest_notification != null));
    }

    fn refreshNotificationDrawer(self: *Controller) void {
        const list = self.drawer_list orelse return;
        clearBox(list);

        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        var unread_count: usize = 0;
        for (self.state.notifications.items) |item| {
            if (item.unread) unread_count += 1;
        }

        const unread_text = std.fmt.allocPrint(self.alloc, "{d} unread", .{unread_count}) catch null;
        defer if (unread_text) |value| self.alloc.free(value);
        setLabel(self.alloc, self.drawer_summary_label, if (unread_text) |value| value else "0 unread");
        self.drawer_jump_button.?.as(gtk.Widget).setSensitive(@intFromBool(unread_count > 0));

        if (self.state.notifications.items.len == 0) {
            appendEmptyCard(list, "No notifications yet");
            return;
        }

        if (unread_count > 0) {
            appendSectionTitle(list, "Unread");
            for (self.state.notifications.items) |item| {
                if (!item.unread) continue;
                self.appendNotificationRowLocked(list, item, true) catch {};
            }
        } else {
            appendSectionTitle(list, "Unread");
            appendEmptyCard(list, "No unread notifications");
        }

        appendSectionTitle(list, "Recent");
        var shown_read: usize = 0;
        for (self.state.notifications.items) |item| {
            if (item.unread) continue;
            if (shown_read >= 10) break;
            self.appendNotificationRowLocked(list, item, false) catch {};
            shown_read += 1;
        }
        if (shown_read == 0) appendEmptyCard(list, "No recent read notifications");
    }

    fn refreshDrawerToggle(self: *Controller) void {
        var unread_count: usize = 0;
        self.state.mutex.lock();
        for (self.state.notifications.items) |item| {
            if (item.unread) unread_count += 1;
        }
        self.state.mutex.unlock();

        const badge = std.fmt.allocPrint(self.alloc, "{d}", .{unread_count}) catch null;
        defer if (badge) |value| self.alloc.free(value);
        setLabel(self.alloc, self.drawer_badge_label, if (badge) |value| value else "0");
        self.drawer_badge_label.?.as(gtk.Widget).removeCssClass("lmux-badge-empty");
        if (unread_count == 0) self.drawer_badge_label.?.as(gtk.Widget).addCssClass("lmux-badge-empty");

        const toggle = self.drawer_toggle_button orelse return;
        toggle.as(gtk.Widget).removeCssClass("lmux-toggle-attention");
        if (unread_count > 0) toggle.as(gtk.Widget).addCssClass("lmux-toggle-attention");
    }

    fn refreshAttentionClasses(self: *Controller) void {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        var it = self.state.panes.iterator();
        while (it.next()) |entry| {
            const pane = entry.value_ptr;
            const runtime = self.pane_runtimes.get(entry.key_ptr.*) orelse continue;
            runtime.surface.as(gtk.Widget).removeCssClass("lmux-pane-attention");
            if (pane.attention) runtime.surface.as(gtk.Widget).addCssClass("lmux-pane-attention");
        }
    }

    fn syncDrawerState(self: *Controller) void {
        const revealer = self.drawer_revealer orelse return;
        revealer.setRevealChild(@intFromBool(self.drawer_open));
    }

    fn focusPaneRuntime(self: *Controller, pane_id: UUID) !void {
        const runtime = self.pane_runtimes.get(pane_id) orelse return error.PaneRuntimeNotFound;
        ghostty.focusPane(runtime.surface);
    }

    fn updatePaneFromSurface(self: *Controller, surface: *GhosttySurface) void {
        const pane_id = self.surface_index.get(@intFromPtr(surface)) orelse return;
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        const pane = self.state.panes.getPtr(pane_id) orelse return;

        replaceOptionalString(self.alloc, &pane.cwd, if (surface.getPwd()) |value| std.mem.sliceTo(value, 0) else null);
        replaceOptionalString(self.alloc, &pane.title, if (surface.getEffectiveTitle()) |value| std.mem.sliceTo(value, 0) else null);
    }

    fn refreshPaneMetadata(self: *Controller, pane_id: UUID) void {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        const pane = self.state.panes.getPtr(pane_id) orelse return;
        const tab = self.state.tabs.getPtr(pane.tab_id) orelse return;

        pane.metadata_snapshot.deinit(self.alloc);
        pane.metadata_snapshot = metadata.collect(
            self.alloc,
            pane.cwd,
            pane.root_pid,
            self.state.config.github_enabled,
            self.state.config.listening_ports_enabled,
        );

        if (tab.metadata_summary) |value| self.alloc.free(value);
        tab.metadata_summary = summaryForSnapshot(self.alloc, pane.metadata_snapshot) catch null;
    }

    fn tabLabelLocked(
        self: *Controller,
        tab_id: UUID,
        tab: *const AppState.TabState,
    ) []u8 {
        _ = tab_id;

        if (tab.title) |value| return self.alloc.dupe(u8, value) catch self.alloc.dupe(u8, "Shell") catch unreachable;

        if (tab.focused_pane) |pane_id| {
            if (self.state.panes.getPtr(pane_id)) |pane| {
                if (pane.title) |value| return self.alloc.dupe(u8, value) catch self.alloc.dupe(u8, "Shell") catch unreachable;
                if (pane.metadata_snapshot.cwd_basename) |value| return self.alloc.dupe(u8, value) catch self.alloc.dupe(u8, "Shell") catch unreachable;
                if (pane.cwd) |value| return self.alloc.dupe(u8, std.fs.path.basename(value)) catch self.alloc.dupe(u8, "Shell") catch unreachable;
            }
        }

        if (tab.metadata_summary) |value| return self.alloc.dupe(u8, value) catch self.alloc.dupe(u8, "Shell") catch unreachable;
        return self.alloc.dupe(u8, "Shell") catch unreachable;
    }

    fn dispatchNotify(
        self: *Controller,
        pane_id: UUID,
        source: attention.Source,
        title: []const u8,
        body: []const u8,
    ) void {
        var params = std.json.ObjectMap.init(self.alloc);
        defer params.deinit();
        params.put("pane_id", .{ .string = ids.slice(&pane_id) }) catch return;
        params.put("title", .{ .string = title }) catch return;
        params.put("body", .{ .string = body }) catch return;
        params.put("sticky", .{ .bool = true }) catch return;
        params.put("source", .{ .string = switch (source) {
            .agent => "agent",
            .bell => "bell",
            .desktop_notification => "desktop_notification",
        } }) catch return;

        const result = self.state.dispatch(self.alloc, "pane.notify", .{ .object = params }) catch return;
        defer switch (result) {
            .success => |payload| self.alloc.free(payload),
            .failure => {},
        };
    }

    fn runAction(self: *Controller, method: []const u8, params: std.json.ObjectMap) void {
        const result = self.dispatchWithRuntime(self.alloc, method, .{ .object = params }) catch return;
        defer switch (result) {
            .success => |payload| self.alloc.free(payload),
            .failure => {},
        };
    }

    fn requestCreateTab(self: *Controller) void {
        var params = std.json.ObjectMap.init(self.alloc);
        defer params.deinit();
        self.runAction("tab.create", params);
    }

    fn requestFocusPane(self: *Controller, pane_id: UUID) void {
        var params = std.json.ObjectMap.init(self.alloc);
        defer params.deinit();
        params.put("pane_id", .{ .string = ids.slice(&pane_id) }) catch return;
        self.runAction("pane.focus", params);
    }

    fn requestSplit(self: *Controller, direction: []const u8) void {
        self.state.mutex.lock();
        const pane_id = focusedPaneLocked(&self.state);
        self.state.mutex.unlock();
        const target = pane_id orelse return;

        var params = std.json.ObjectMap.init(self.alloc);
        defer params.deinit();
        params.put("pane_id", .{ .string = ids.slice(&target) }) catch return;
        params.put("direction", .{ .string = direction }) catch return;
        self.runAction("pane.split", params);
    }

    fn requestJumpLatest(self: *Controller) void {
        var params = std.json.ObjectMap.init(self.alloc);
        defer params.deinit();
        self.runAction("notification.jump_latest", params);
    }

    fn requestActivateNotification(self: *Controller, notification_id: UUID) void {
        var params = std.json.ObjectMap.init(self.alloc);
        defer params.deinit();
        params.put("notification_id", .{ .string = ids.slice(&notification_id) }) catch return;
        self.runAction("notification.activate", params);
        self.drawer_open = false;
    }

    fn ensureNotificationAction(self: *Controller, notification_id: UUID) !*NotificationClickData {
        const gop = try self.notification_actions.getOrPut(self.alloc, notification_id);
        if (!gop.found_existing) {
            const data = try self.alloc.create(NotificationClickData);
            data.* = .{ .controller = self, .notification_id = notification_id };
            gop.value_ptr.* = data;
        }
        return gop.value_ptr.*;
    }

    fn appendNotificationRowLocked(
        self: *Controller,
        list: *gtk.Box,
        item: attention.Notification,
        highlight_unread: bool,
    ) !void {
        const button = gtk.Button.new();
        button.as(gtk.Widget).addCssClass("lmux-notification-row");
        if (highlight_unread) button.as(gtk.Widget).addCssClass("lmux-notification-unread");

        const content = gtk.Box.new(.vertical, 6);
        const top = gtk.Box.new(.horizontal, 8);
        content.append(top.as(gtk.Widget));

        const source = gtk.Label.new(sourceLabel(item.source));
        source.as(gtk.Widget).addCssClass("lmux-section-title");
        source.as(gtk.Widget).setHalign(.start);
        source.as(gtk.Widget).setHexpand(1);
        top.append(source.as(gtk.Widget));

        const time = relativeTimestamp(self.alloc, item.timestamp_ms) catch null;
        defer if (time) |value| self.alloc.free(value);
        const time_label = gtk.Label.new("now");
        setLabel(self.alloc, time_label, if (time) |value| value else "now");
        time_label.as(gtk.Widget).addCssClass("lmux-meta");
        top.append(time_label.as(gtk.Widget));

        const snippet = gtk.Label.new("");
        setLabel(self.alloc, snippet, item.snippet);
        snippet.setWrap(1);
        snippet.setXalign(0);
        snippet.as(gtk.Widget).setHalign(.start);
        content.append(snippet.as(gtk.Widget));

        const target_text = notificationTargetLabelLocked(self, item) catch null;
        defer if (target_text) |value| self.alloc.free(value);
        const target = gtk.Label.new("");
        setLabel(self.alloc, target, if (target_text) |value| value else "Unknown target");
        target.as(gtk.Widget).addCssClass("lmux-meta");
        target.as(gtk.Widget).setHalign(.start);
        content.append(target.as(gtk.Widget));

        button.setChild(content.as(gtk.Widget));
        const click_data = try self.ensureNotificationAction(item.id);
        _ = gtk.Button.signals.clicked.connect(button, *NotificationClickData, notificationClicked, click_data, .{});
        list.append(button.as(gtk.Widget));
    }
};

fn addContextValue(container: *gtk.Box, title: [:0]const u8, initial: [:0]const u8) !*gtk.Label {
    const title_label = gtk.Label.new(title);
    title_label.as(gtk.Widget).addCssClass("lmux-section-title");
    title_label.as(gtk.Widget).setHalign(.start);
    container.append(title_label.as(gtk.Widget));

    const value = gtk.Label.new(initial);
    value.setWrap(1);
    value.setXalign(0);
    value.as(gtk.Widget).addCssClass("lmux-context-value");
    value.as(gtk.Widget).setHalign(.start);
    container.append(value.as(gtk.Widget));
    return value;
}

fn addSubtleValue(container: *gtk.Box, initial: [:0]const u8) !*gtk.Label {
    const value = gtk.Label.new(initial);
    value.setWrap(1);
    value.setXalign(0);
    value.as(gtk.Widget).addCssClass("lmux-meta");
    value.as(gtk.Widget).setHalign(.start);
    container.append(value.as(gtk.Widget));
    return value;
}

fn addContextChips(container: *gtk.Box, title: [:0]const u8) !*gtk.Box {
    const title_label = gtk.Label.new(title);
    title_label.as(gtk.Widget).addCssClass("lmux-section-title");
    title_label.as(gtk.Widget).setHalign(.start);
    container.append(title_label.as(gtk.Widget));

    const row = gtk.Box.new(.horizontal, 8);
    row.as(gtk.Widget).setHalign(.start);
    container.append(row.as(gtk.Widget));
    return row;
}

fn addContextAction(
    container: *gtk.Box,
    title: [:0]const u8,
    initial: [:0]const u8,
    comptime callback: anytype,
    user_data: anytype,
) !struct { *gtk.Button, *gtk.Label } {
    const title_label = gtk.Label.new(title);
    title_label.as(gtk.Widget).addCssClass("lmux-section-title");
    title_label.as(gtk.Widget).setHalign(.start);
    container.append(title_label.as(gtk.Widget));

    const button = gtk.Button.new();
    button.as(gtk.Widget).addCssClass("lmux-latest-button");
    const label = gtk.Label.new(initial);
    label.setWrap(1);
    label.setXalign(0);
    label.as(gtk.Widget).setHalign(.start);
    label.as(gtk.Widget).addCssClass("lmux-context-value");
    button.setChild(label.as(gtk.Widget));
    _ = gtk.Button.signals.clicked.connect(button, @TypeOf(user_data), callback, user_data, .{});
    container.append(button.as(gtk.Widget));

    return .{ button, label };
}

fn addSplitButton(
    container: *gtk.Box,
    label_text: [:0]const u8,
    comptime callback: anytype,
    controller: *Controller,
) !void {
    const button = gtk.Button.new();
    button.setLabel(label_text);
    button.as(gtk.Widget).addCssClass("lmux-split-button");
    _ = gtk.Button.signals.clicked.connect(button, *Controller, callback, controller, .{});
    container.append(button.as(gtk.Widget));
}

fn appendChipWithAlloc(alloc: std.mem.Allocator, container: *gtk.Box, text: []const u8) void {
    const label = gtk.Label.new(null);
    label.as(gtk.Widget).addCssClass("lmux-chip");
    setLabel(alloc, label, text);
    container.append(label.as(gtk.Widget));
}

fn appendSectionTitle(container: *gtk.Box, text: [:0]const u8) void {
    const label = gtk.Label.new(text);
    label.as(gtk.Widget).addCssClass("lmux-section-title");
    label.as(gtk.Widget).setHalign(.start);
    container.append(label.as(gtk.Widget));
}

fn appendEmptyCard(container: *gtk.Box, text: [:0]const u8) void {
    const box = gtk.Box.new(.vertical, 0);
    box.as(gtk.Widget).addCssClass("lmux-notification-row");
    const label = gtk.Label.new(text);
    label.as(gtk.Widget).addCssClass("lmux-meta");
    label.as(gtk.Widget).setHalign(.start);
    box.append(label.as(gtk.Widget));
    container.append(box.as(gtk.Widget));
}

fn clearBox(box: *gtk.Box) void {
    var child = box.as(gtk.Widget).getFirstChild();
    while (child) |widget| {
        child = widget.getNextSibling();
        box.remove(widget);
    }
}

fn setLabel(
    alloc: std.mem.Allocator,
    label: ?*gtk.Label,
    text: []const u8,
) void {
    const widget = label orelse return;
    const text_z = alloc.dupeZ(u8, text) catch return;
    defer alloc.free(text_z);
    widget.setLabel(text_z);
}

fn resetClasses(widget: *gtk.Widget, classes: []const [:0]const u8) void {
    for (classes) |class_name| widget.removeCssClass(class_name);
}

fn uuidEq(a: UUID, b: UUID) bool {
    return std.mem.eql(u8, ids.slice(&a), ids.slice(&b));
}

fn tabHasAttentionLocked(controller: *const Controller, tab: *const AppState.TabState) bool {
    for (tab.panes.items) |pane_id| {
        const pane = controller.state.panes.getPtr(pane_id) orelse continue;
        if (pane.attention) return true;
    }
    return false;
}

fn paneChipLabelLocked(
    alloc: std.mem.Allocator,
    pane: *const AppState.PaneState,
    index: usize,
) []u8 {
    if (pane.title) |value| return alloc.dupe(u8, value) catch alloc.dupe(u8, "Pane") catch unreachable;
    if (pane.metadata_snapshot.cwd_basename) |value| return alloc.dupe(u8, value) catch alloc.dupe(u8, "Pane") catch unreachable;
    if (pane.cwd) |value| return alloc.dupe(u8, std.fs.path.basename(value)) catch alloc.dupe(u8, "Pane") catch unreachable;
    return std.fmt.allocPrint(alloc, "Pane {d}", .{index + 1}) catch alloc.dupe(u8, "Pane") catch unreachable;
}

fn branchText(
    alloc: std.mem.Allocator,
    snapshot: metadata.Snapshot,
) !?[]u8 {
    const branch = snapshot.git_info.branch orelse return null;
    if (snapshot.git_info.dirty) {
        return try std.fmt.allocPrint(alloc, "{s}*", .{branch});
    }
    return try alloc.dupe(u8, branch);
}

fn prDisplay(
    alloc: std.mem.Allocator,
    snapshot: metadata.Snapshot,
) !struct { ?[]u8, ?[]u8 } {
    const info = snapshot.github_info;
    const number = info.number orelse return .{ null, null };
    const status = info.status orelse "UNKNOWN";
    const compact = try std.fmt.allocPrint(alloc, "#{d} {s}", .{ number, status });

    if (info.summary) |summary| {
        if (std.mem.indexOf(u8, summary, ": ")) |index| {
            return .{ compact, try alloc.dupe(u8, summary[index + 2 ..]) };
        }
        return .{ compact, try alloc.dupe(u8, summary) };
    }
    return .{ compact, null };
}

fn summaryForSnapshot(
    alloc: std.mem.Allocator,
    snapshot: metadata.Snapshot,
) ![]const u8 {
    if (snapshot.git_info.branch) |branch| return try alloc.dupe(u8, branch);
    if (snapshot.cwd_basename) |cwd_basename| return try alloc.dupe(u8, cwd_basename);
    return try alloc.dupe(u8, "Shell");
}

fn replaceOptionalString(
    alloc: std.mem.Allocator,
    target: *?[]const u8,
    next: ?[]const u8,
) void {
    if (target.*) |current| alloc.free(current);
    target.* = if (next) |value| alloc.dupe(u8, value) catch null else null;
}

fn focusedPaneLocked(state: *AppState) ?UUID {
    const workspace_id = state.focused_workspace orelse return null;
    const workspace = state.workspaces.getPtr(workspace_id) orelse return null;
    const tab_id = workspace.focused_tab orelse return null;
    const tab = state.tabs.getPtr(tab_id) orelse return null;
    return tab.focused_pane;
}

fn focusedPaneContextLocked(state: *AppState) ?struct {
    workspace: *AppState.WorkspaceState,
    tab: *AppState.TabState,
    pane: *AppState.PaneState,
} {
    const workspace_id = state.focused_workspace orelse return null;
    const workspace = state.workspaces.getPtr(workspace_id) orelse return null;
    const tab_id = workspace.focused_tab orelse return null;
    const tab = state.tabs.getPtr(tab_id) orelse return null;
    const pane_id = tab.focused_pane orelse return null;
    const pane = state.panes.getPtr(pane_id) orelse return null;
    return .{
        .workspace = workspace,
        .tab = tab,
        .pane = pane,
    };
}

fn paneOptions(params: std.json.Value) ghostty.CreateOptions {
    return .{
        .cwd = paramString(params, "cwd"),
        .title = paramString(params, "title"),
    };
}

fn paramString(params: std.json.Value, key: []const u8) ?[]const u8 {
    if (params != .object) return null;
    const value = params.object.get(key) orelse return null;
    return switch (value) {
        .string => value.string,
        else => null,
    };
}

fn errorFromFailure(failure: AppState.Failure) anyerror {
    _ = failure;
    return error.DispatchFailed;
}

const SingleIdPayload = struct {
    value: UUID,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: SingleIdPayload) void {
        self.parsed.deinit();
    }
};

fn parseSingleIdPayload(
    alloc: std.mem.Allocator,
    payload: []const u8,
    key: []const u8,
) !SingleIdPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    errdefer parsed.deinit();
    const object = parsed.value.object;
    const value = object.get(key) orelse return error.InvalidPayload;
    if (value != .string) return error.InvalidPayload;
    return .{
        .value = try ids.parse(value.string),
        .parsed = parsed,
    };
}

const CreatedTabPayload = struct {
    workspace_id: UUID,
    tab_id: UUID,
    pane_id: UUID,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: CreatedTabPayload) void {
        self.parsed.deinit();
    }
};

fn parseCreateTabPayload(
    alloc: std.mem.Allocator,
    payload: []const u8,
) !CreatedTabPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    errdefer parsed.deinit();
    const object = parsed.value.object;
    const workspace_value = object.get("workspace_id") orelse return error.InvalidPayload;
    const tab_value = object.get("tab_id") orelse return error.InvalidPayload;
    const pane_value = object.get("pane_id") orelse return error.InvalidPayload;
    if (workspace_value != .string or tab_value != .string or pane_value != .string) return error.InvalidPayload;
    return .{
        .workspace_id = try ids.parse(workspace_value.string),
        .tab_id = try ids.parse(tab_value.string),
        .pane_id = try ids.parse(pane_value.string),
        .parsed = parsed,
    };
}

fn metadataRefreshTick(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Controller = @ptrCast(@alignCast(ud orelse return 0));
    self.state.mutex.lock();
    const pane_id = focusedPaneLocked(&self.state);
    self.state.mutex.unlock();
    if (pane_id) |value| {
        self.refreshPaneMetadata(value);
        self.refreshUi();
    }
    return 1;
}

fn tabClicked(_: *gtk.Button, data: *Controller.TabClickData) callconv(.c) void {
    data.controller.state.mutex.lock();
    const tab = data.controller.state.tabs.getPtr(data.tab_id) orelse {
        data.controller.state.mutex.unlock();
        return;
    };
    const workspace = data.controller.state.workspaces.getPtr(tab.workspace_id) orelse {
        data.controller.state.mutex.unlock();
        return;
    };
    workspace.focused_tab = tab.id;
    data.controller.state.focused_workspace = workspace.id;
    data.controller.state.mutex.unlock();
    data.controller.refreshUi();
}

fn paneClicked(_: *gtk.Button, data: *Controller.PaneClickData) callconv(.c) void {
    data.controller.requestFocusPane(data.pane_id);
}

fn notificationClicked(_: *gtk.Button, data: *Controller.NotificationClickData) callconv(.c) void {
    data.controller.requestActivateNotification(data.notification_id);
    data.controller.refreshUi();
}

fn createTabClicked(_: *gtk.Button, self: *Controller) callconv(.c) void {
    self.requestCreateTab();
}

fn latestNotificationClicked(_: *gtk.Button, self: *Controller) callconv(.c) void {
    self.drawer_open = true;
    self.syncDrawerState();
}

fn drawerToggleClicked(_: *gtk.Button, self: *Controller) callconv(.c) void {
    self.drawer_open = !self.drawer_open;
    self.syncDrawerState();
}

fn splitLeftClicked(_: *gtk.Button, self: *Controller) callconv(.c) void {
    self.requestSplit("left");
}

fn splitRightClicked(_: *gtk.Button, self: *Controller) callconv(.c) void {
    self.requestSplit("right");
}

fn splitUpClicked(_: *gtk.Button, self: *Controller) callconv(.c) void {
    self.requestSplit("up");
}

fn splitDownClicked(_: *gtk.Button, self: *Controller) callconv(.c) void {
    self.requestSplit("down");
}

fn jumpLatestClicked(_: *gtk.Button, self: *Controller) callconv(.c) void {
    self.requestJumpLatest();
}

fn surfacePwdChanged(
    surface: *GhosttySurface,
    _: *gobject.ParamSpec,
    self: *Controller,
) callconv(.c) void {
    self.updatePaneFromSurface(surface);
    const pane_id = self.surface_index.get(@intFromPtr(surface)) orelse return;
    self.refreshPaneMetadata(pane_id);
    self.refreshUi();
}

fn surfaceTitleChanged(
    surface: *GhosttySurface,
    _: *gobject.ParamSpec,
    self: *Controller,
) callconv(.c) void {
    self.updatePaneFromSurface(surface);
    const pane_id = self.surface_index.get(@intFromPtr(surface)) orelse return;
    self.refreshPaneMetadata(pane_id);
    self.refreshUi();
}

fn surfaceFocusedChanged(
    surface: *GhosttySurface,
    _: *gobject.ParamSpec,
    self: *Controller,
) callconv(.c) void {
    if (!surface.getFocused()) return;
    const pane_id = self.surface_index.get(@intFromPtr(surface)) orelse return;

    self.state.mutex.lock();
    const pane = self.state.panes.getPtr(pane_id) orelse {
        self.state.mutex.unlock();
        return;
    };
    const tab = self.state.tabs.getPtr(pane.tab_id) orelse {
        self.state.mutex.unlock();
        return;
    };
    const workspace = self.state.workspaces.getPtr(tab.workspace_id) orelse {
        self.state.mutex.unlock();
        return;
    };

    tab.focused_pane = pane_id;
    workspace.focused_tab = tab.id;
    self.state.focused_workspace = workspace.id;
    pane.attention = false;
    pane.attention_kind = .none;
    for (self.state.notifications.items) |*item| {
        const target_pane_id = item.pane_id orelse continue;
        if (!std.mem.eql(u8, target_pane_id, ids.slice(&pane_id))) continue;
        item.unread = false;
    }
    tab.unread_count = 0;
    for (self.state.notifications.items) |item| {
        if (!item.unread) continue;
        const target_tab_id = item.tab_id orelse continue;
        if (!std.mem.eql(u8, target_tab_id, ids.slice(&tab.id))) continue;
        tab.unread_count += 1;
    }
    self.state.mutex.unlock();
    self.refreshUi();
}

fn surfaceBell(surface: *GhosttySurface, self: *Controller) callconv(.c) void {
    const pane_id = self.surface_index.get(@intFromPtr(surface)) orelse return;
    self.dispatchNotify(pane_id, .bell, "Bell received", surface.getEffectiveTitle() orelse "Attention requested");
    self.refreshUi();
}

fn surfaceChildExitedChanged(
    surface: *GhosttySurface,
    _: *gobject.ParamSpec,
    self: *Controller,
) callconv(.c) void {
    var child_exited_value = gobject.ext.Value.new(c_int);
    surface.as(gobject.Object).getProperty("child-exited", &child_exited_value);
    if (gobject.ext.Value.get(&child_exited_value, c_int) == 0) return;
    const pane_id = self.surface_index.get(@intFromPtr(surface)) orelse return;
    self.dispatchNotify(pane_id, .agent, "Process exited", surface.getEffectiveTitle() orelse "Child process exited");
    self.refreshUi();
}

fn relativeTimestamp(alloc: std.mem.Allocator, timestamp_ms: i64) !?[]u8 {
    const now = std.time.milliTimestamp();
    const delta_ms = @max(@as(i64, 0), now - timestamp_ms);
    const seconds = @divTrunc(delta_ms, std.time.ms_per_s);
    if (seconds < 60) return try std.fmt.allocPrint(alloc, "{d}s ago", .{seconds});
    const minutes = @divTrunc(seconds, 60);
    if (minutes < 60) return try std.fmt.allocPrint(alloc, "{d}m ago", .{minutes});
    const hours = @divTrunc(minutes, 60);
    if (hours < 24) return try std.fmt.allocPrint(alloc, "{d}h ago", .{hours});
    const days = @divTrunc(hours, 24);
    return try std.fmt.allocPrint(alloc, "{d}d ago", .{days});
}

fn sourceLabel(source: attention.Source) [:0]const u8 {
    return switch (source) {
        .agent => "Agent",
        .bell => "Bell",
        .desktop_notification => "Desktop",
    };
}

fn notificationTargetLabelLocked(controller: *const Controller, item: attention.Notification) !?[]u8 {
    if (item.tab_id) |tab_id_text| {
        const tab_id = ids.parse(tab_id_text) catch return null;
        if (controller.state.tabs.getPtr(tab_id)) |tab| {
            if (tab.title) |value| return try controller.alloc.dupe(u8, value);
            if (tab.metadata_summary) |value| return try controller.alloc.dupe(u8, value);
            return try controller.alloc.dupe(u8, "Shell");
        }
    }
    return null;
}
