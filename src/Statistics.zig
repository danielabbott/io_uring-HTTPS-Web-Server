const std = @import("std");
const warn = std.debug.warn;
const TCPServer = @import("TCPServer.zig");
const HTTPSState = @import("HTTPSState.zig");
const HTTPState = @import("HTTPState.zig");
const HTTP = @import("HTTP.zig");
const TLS = @import("TLS.zig");

pub fn printStatistics() void {
    warn("*************************************\n** Statistics for thread {}\n", .{HTTP.getThreadID()});
    warn("Allocated objects are not necessarily being used at this exact instant\n", .{});
    warn("Connection objects allocated: {}\n", .{TCPServer.connectionPoolSize()});
    warn("Connections: {}\n", .{TCPServer.numConnections()});
    warn("Peak connections: {}\n", .{TCPServer.peakConnections()});
    warn("Event objects allocated: {}\n", .{TCPServer.eventPoolSize()});
    warn("Pending events: {}\n", .{TCPServer.numPendingEvents()});
    warn("HTTPS state objects allocated: {}\n", .{HTTPSState.statePoolSize()});
    warn("HTTP state objects allocated: {}\n", .{HTTPState.statePoolSize()});
    warn("Temporary write buffer objects allocated: {}\n", .{TLS.writeBufferPoolSize()});
    warn("Bytes received (KiB): {}\n", .{TCPServer.bytesRecievedTotal() / 1024});
    warn("Bytes sent (KiB): {}\n", .{TCPServer.bytesSentTotal() / 1024});
    warn("*************************************\n", .{});
}
