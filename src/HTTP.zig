const std = @import("std");
const builtin = @import("builtin");
const log_ = @import("Log.zig");
const errLog_ = log_.errLog;
const dbgLog_ = log_.dbgLog;
const c_allocator = std.heap.c_allocator;
const TCPServer = @import("TCPServer.zig");
const HTTPSState = @import("HTTPSState.zig").HTTPSState;
const HTTPState = @import("HTTPState.zig").HTTPState;
pub const Files = @import("Files.zig");
const HTTPMessageParser = @import("HTTPMessageParser.zig");
const startsWith = std.mem.startsWith;
const TLS = @import("TLS.zig");
const config = @import("Config.zig").config;

usingnamespace @cImport({
    @cInclude("unistd.h");
});

pub fn dbgLog(comptime s: []const u8, args: var) void {
    dbgLog_("HTTP(S): " ++ s, args);
}
pub fn errLog(comptime s: []const u8, args: var) void {
    errLog_("HTTP(S): " ++ s, args);
}

fn newConnection(port: u16, conn: usize, ip: u128) ?usize {
    var ip_string: [46]u8 = undefined;
    ip_string[0] = 0;
    TCPServer.ipToString(ip, ip_string[0..]) catch {};

    if (port == config().http_port) {
        dbgLog("New HTTP Connection. IP: {}. conn = {}", .{ ip_string, conn });
        return HTTPState.new() catch |e| {
            errLog("Error creating HTTP state: {}", .{e});
            return null;
        };
    }

    dbgLog("New HTTPS IP: {}. conn = {}", .{ ip_string, conn });
    return HTTPSState.new() catch |e| {
        errLog("Error creating HTTPS state: {}", .{e});
        return null;
    };
}

fn dataIn_(port: u16, user_data: usize, conn: usize, data: []const u8) !void {
    var reponseSent = false;

    if (port == config().http_port) {
        // HTTP
        const state = try HTTPState.get(user_data);
        dbgLog("*** HTTP data ***\n{}******", .{data[0..std.math.min(150, data.len)]});

        // HTTP server just sends a permanent redirect
        if (try sendRedirect(conn, state, data)) {
            TCPServer.closeSocket(conn);
        }
    } else {
        // HTTPS
        const state = try HTTPSState.get(user_data);
        try state.*.read(conn, data);
    }
}

fn dataIn(port: u16, user_data: usize, conn: usize, data: []const u8) void {
    return dataIn_(port, user_data, conn, data) catch |e| {
        if (e != error.TLSShutDown and e != error.ConnectionClosed) {
            errLog("HTTP(S) read error: {}", .{e});
        }
        TCPServer.closeSocket(conn);
    };
}

fn writeDone(port: u16, user_data: usize, conn: usize, data: []const u8, meta_data: u64) void {
    if (port == config().http_port) {
        // HTTP
        TCPServer.closeSocket(conn);
    } else {
        // HTTPS
        const state = HTTPSState.get(user_data) catch return;
        state.writeDone(conn, data) catch |e| {
            errLog("HTTP writeDone error: {}", .{e});
            TCPServer.closeSocket(conn);
        };
    }
}

fn connLost(port: u16, user_data: usize, conn: usize) void {
    if (port == config().http_port) {
        dbgLog("HTTP Connection {} closed", .{conn});
        HTTPState.free2(user_data, conn);
    } else {
        dbgLog("HTTPS Connection {} closed", .{conn});
        HTTPSState.free2(user_data, conn);
    }
}

fn parseHTTPRequest(data: []const u8, http_version: *u1, host: *(?[]const u8)) !void {
    host.* = null;
    var s = data;

    _ = try HTTPMessageParser.getRequestType(&s);
    _ = try HTTPMessageParser.getRequestURL(&s);
    http_version.* = try HTTPMessageParser.verifyHTTPVersion(&s);

    while (true) {
        const field = try HTTPMessageParser.getNextHeaderField(&s);
        if (field == null) {
            return error.NoHost;
        }
        if (startsWith(u8, field.?, "Host: ")) {
            host.* = field.?[6..];
            break;
        }
    }
}

// Returns true if sent redirect message, false if headers haven't fully sent yet
fn sendRedirect(conn: usize, state: *HTTPState, data: []const u8) !bool {
    var http_version: u1 = undefined;
    var host: ?[]const u8 = null;
    parseHTTPRequest(data, &http_version, &host) catch |e| {
        if (e == error.EndOfString or e == error.EmptyString) {
            // TODO If entire request is not received then the redirect does not get sent
            return false;
        } else {
            return e;
        }
    };

    if (host == null) {
        return error.NoHostHeader;
    }
    host = host.?[0..std.math.min(255, host.?.len)];

    const S_HTTP_VER = "HTTP/1.";
    const S_HEADER = " 301 Moved Permanently\r\nLocation: https://";

    state.response_string = try TCPServer.write_buffer_pool.alloc();
    var string = state.response_string.?.*[0 .. S_HTTP_VER.len + 1 + S_HEADER.len + host.?.len + 4];

    var i: usize = 0;

    std.mem.copy(u8, string[i .. i + S_HTTP_VER.len], S_HTTP_VER);
    i += S_HTTP_VER.len;

    string[i] = '0' + @intCast(u8, http_version);
    i += 1;

    std.mem.copy(u8, string[i .. i + S_HEADER.len], S_HEADER);
    i += S_HEADER.len;

    std.mem.copy(u8, string[i .. i + host.?.len], host.?);
    i += host.?.len;

    string[i] = '\r';
    string[i + 1] = '\n';
    string[i + 2] = '\r';
    string[i + 3] = '\n';

    dbgLog("http response: {}", .{string});

    try TCPServer.sendData(conn, string, 0);

    return true;
}

threadlocal var thread_id: u32 = undefined;
pub fn getThreadID() u32 {
    return thread_id;
}

fn serverThread(threadN: u32) void {
    thread_id = threadN;

    TLS.threadLocalInit();
    HTTPSState.threadLocalInit();
    HTTPState.threadLocalInit();
    TCPServer.start(&[_]TCPServer.SocketInitInfo{
        TCPServer.SocketInitInfo{ .port = config().http_port },
        TCPServer.SocketInitInfo{ .port = config().https_port },
    }, newConnection, dataIn, connLost, writeDone) catch |e| {
        errLog("ERROR: {}", .{e});
    };
}

pub fn start() !void {
    try TLS.init();
    try TCPServer.oneTimeInit();

    if (builtin.mode == .Debug) {
        std.debug.warn("Debug build, running single threaded.\n", .{});
        serverThread(0);
    } else {
        var threads: [128]*std.Thread = undefined;

        var num_threads = config().threads;
        if (num_threads == 0) {
            num_threads = @intCast(u32, std.math.min(@intCast(c_long, threads.len), sysconf(_SC_NPROCESSORS_ONLN)));
        }

        std.debug.warn("Using {} threads\n", .{num_threads});

        var i: u32 = 0;
        while (i < num_threads - 1) : (i += 1) {
            threads[i] = try std.Thread.spawn(@as(u32, 1), serverThread);
        }
        serverThread(0);

        // This will only run if something goes wrong on the main thread
        i = 0;
        while (i < num_threads - 1) : (i += 1) {
            threads[i].wait();
        }
    }
}
