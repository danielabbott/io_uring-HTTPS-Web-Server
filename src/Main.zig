const std = @import("std");
const HTTP = @import("HTTP.zig");
const Files = @import("Files.zig");
const Config = @import("Config.zig");
const c_allocator = std.heap.c_allocator;

pub fn main() anyerror!void {
    std.debug.warn("Web server started...\n", .{});
    Files.init();
    try Config.init();
    try HTTP.start();
}

test "All" {
    _ = @import("Parse.zig");
    _ = @import("Atoi.zig");
    _ = @import("Config.zig");
    _ = @import("ObjectPool.zig");
    _ = @import("LinkedBuffers.zig");
    _ = @import("Queue.zig");
    _ = @import("HTTPRequestHandler.zig");
}
