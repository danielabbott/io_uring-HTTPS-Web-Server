const std = @import("std");
const builtin = @import("builtin");

pub fn fatalErrorLog(comptime s: []const u8, args: var) void {
    std.debug.warn("FATAL ERROR: " ++ s ++ "\n", args);
}
pub fn errLog(comptime s: []const u8, args: var) void {
    std.debug.warn(s ++ "\n", args);
}
pub fn dbgLog(comptime s: []const u8, args: var) void {
    if (builtin.mode == .Debug) {
        std.debug.warn(s ++ "\n", args);
    }
}
