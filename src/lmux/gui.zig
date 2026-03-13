const std = @import("std");
const glib = @import("glib");

const Controller = @import("Controller.zig").Controller;
const GhosttyCoreApp = @import("../App.zig");
const GhosttyGlobal = @import("../global.zig");
const GhosttyGtkApp = @import("../apprt/gtk/App.zig");

pub fn run(alloc: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;

    try GhosttyGlobal.state.init();
    defer GhosttyGlobal.state.deinit();

    const core_app = try GhosttyCoreApp.create(alloc);
    defer core_app.destroy();

    var gtk_app: GhosttyGtkApp = undefined;
    try gtk_app.init(core_app, .{});
    defer gtk_app.terminate();

    const app = gtk_app.app;
    {
        const config_obj = app.getConfig();
        defer config_obj.unref();
        const config = config_obj.getMut();
        config.@"initial-window" = false;
        config.@"quit-after-last-window-closed" = true;
    }

    const controller = try Controller.create(alloc, app);
    _ = glib.idleAdd(bootstrap, controller);
    try gtk_app.run();
    controller.deinit();
}

fn bootstrap(ud: ?*anyopaque) callconv(.c) c_int {
    const controller: *Controller = @ptrCast(@alignCast(ud orelse return 0));
    controller.build() catch return 0;
    return 0;
}
