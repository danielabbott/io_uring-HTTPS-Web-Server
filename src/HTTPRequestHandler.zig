const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const dbgLog_ = @import("Log.zig").dbgLog;
const HTTPMessageParser = @import("HTTPMessageParser.zig");
const parse = @import("Parse.zig");
const Files = @import("Files.zig");
const TCPServer = @import("TCPServer.zig");
const TLSConnection = @import("TLS.zig").TLSConnection;
const httpExtraHeaders = @import("Config.zig").httpExtraHeaders;

pub fn dbgLog(comptime s: []const u8, args: var) void {
    dbgLog_("HTTPS: " ++ s, args);
}

const c = @cImport({
    @cInclude("stdio.h");
});

pub const RequestResponseState = struct {
    http_version: u1, keep_alive: bool, request_type: ?HTTPMessageParser.RequestType, // null -> invalid request, sends http error in sendResponse()
        file: ?[]const u8, // Only valid if request_type != null. null -> file not found
        mime_type: ?[]const u8, response_headers_sent: bool = false, data_sent: u32 = 0
};

fn doParse(request: []const u8, http_version: *u1, request_type: *HTTPMessageParser.RequestType, url: *([]const u8), keep_alive: *bool) !u32 {
    var s = request;

    request_type.* = try HTTPMessageParser.getRequestType(&s);
    url.* = try HTTPMessageParser.getRequestURL(&s);
    http_version.* = try HTTPMessageParser.verifyHTTPVersion(&s);
    dbgLog("http request [{}], url [{}]", .{ request_type.*, url.* });

    // Default keep-alive setting
    keep_alive.* = http_version.* == 1;

    while (true) {
        const header = try HTTPMessageParser.getNextHeaderField(&s);
        if (header == null) {
            break;
        }
        dbgLog("header: [{}]", .{header.?[0..std.math.min(256, header.?.len)]});

        var header_data = HTTPMessageParser.getHeader(header.?, "connection");
        if (header_data != null) {
            if (parse.caseInsensitiveCompareIgnoreEndWhitespace(header_data.?, "keep-alive")) {
                keep_alive.* = true;
            } else if (parse.caseInsensitiveCompareIgnoreEndWhitespace(header_data.?, "close")) {
                keep_alive.* = false;
            }
        }
    }
    dbgLog("-- Header ends --\n", .{});

    // Skip any extra whitespace between requests.
    parse.skipWhitespace(&s) catch {
        return @intCast(u32, request.len);
    };

    return @intCast(u32, request.len - s.len);
}

test "HTTP Parse" {
    const http_request = "GET /a HTTP/1.0\r\nhost:b\r\ncoNNection: keep-alive  \r\n\r\n";
    var http_version: u1 = undefined;
    var request_type: HTTPMessageParser.RequestType = undefined;
    var url: []const u8 = undefined;
    var keep_alive: bool = undefined;
    const bytes_read = try doParse(http_request, &http_version, &request_type, &url, &keep_alive);
    testing.expect(http_version == 0);
    testing.expect(request_type == .GET);
    testing.expect(std.mem.eql(u8, url, "/a"));
    testing.expect(keep_alive);
    testing.expect(bytes_read == http_request.len);
}

// Returns false if only part of the header has been sent (no response is sent)
// Returns true if the response has been delt with
pub fn parseRequest(request: *([]const u8)) !(?RequestResponseState) {
    var http_version: u1 = undefined;
    var request_type: HTTPMessageParser.RequestType = undefined;
    var url: []const u8 = undefined;
    var keep_alive: bool = undefined;
    const bytes_read = doParse(request.*, &http_version, &request_type, &url, &keep_alive) catch |e| {
        if (e == error.EndOfString or e == error.EmptyString) {
            dbgLog("End of data {}\n", .{e});
            return null;
        } else {
            dbgLog("Parse error: {}\n", .{e});
            return e;
        }
    };
    request.* = request.*[bytes_read..];

    if (request_type == HTTPMessageParser.RequestType.GET) {
        var mime_type: ?[]const u8 = undefined;
        const file_data = Files.getFile(url, &mime_type);
        if (file_data == null) {
            dbgLog("File not found: [{}]\n", .{url});
            return RequestResponseState{
                .http_version = http_version,
                .keep_alive = keep_alive,
                .request_type = HTTPMessageParser.RequestType.GET,
                .file = null,
                .mime_type = null,
            };
        } else {
            return RequestResponseState{
                .http_version = http_version,
                .keep_alive = keep_alive,
                .request_type = HTTPMessageParser.RequestType.GET,
                .file = file_data,
                .mime_type = mime_type,
            };
        }
    } else {
        dbgLog("Not a get. Sending 400 bad request.\n", .{});
        return RequestResponseState{
            .http_version = http_version,
            .keep_alive = keep_alive,
            .request_type = null,
            .file = undefined,
            .mime_type = null,
        };
    }
}

// Assumes the TLS buffer has enough room to store the maximum header size
pub fn sendResponse(conn: usize, tls: *TLSConnection, request_response_state: *?RequestResponseState) !void {
    assert(request_response_state.* != null);

    const http_version = request_response_state.*.?.http_version;
    const keep_alive = request_response_state.*.?.keep_alive;

    if (!request_response_state.*.?.response_headers_sent) {
        // Write buffer has been cleared (or has enough space) (HTTPSState.zig) so buffered writes are guaranteed to work
        if (request_response_state.*.?.request_type == null) {
            dbgLog("Sending: 400 Bad Request", .{});
            try tls.bufferedWriteG(conn, "HTTP/1.");
            try tls.bufferedWriteG(conn, if (request_response_state.*.?.http_version == 1) "1" else "0");
            try tls.bufferedWriteG(conn, " 400 Bad Request\r\nContent-Length: 19\r\n\r\n<h1>400 Bad Request");
            try tls.flushWrite(conn);
            request_response_state.* = null;
        } else if (request_response_state.*.?.file == null) {
            dbgLog("Sending: 404 Not Found", .{});
            try tls.bufferedWriteG(conn, "HTTP/1.");
            try tls.bufferedWriteG(conn, if (request_response_state.*.?.http_version == 1) "1" else "0");
            try tls.bufferedWriteG(conn, " 404 Not Found\r\nContent-Length: 22\r\n\r\n<h1>404 Page Not Found");
            try tls.flushWrite(conn);
            request_response_state.* = null;
        } else {
            dbgLog("Sending: 200 OK", .{});
            try tls.bufferedWriteG(conn, "HTTP/1.");
            try tls.bufferedWriteG(conn, if (request_response_state.*.?.http_version == 1) "1" else "0");
            try tls.bufferedWriteG(conn, " 200 OK\r\n" ++
                "Content-Length: ");
            var length_string = [_]u8{0} ** 20;
            const length_string_len = c.snprintf(length_string[0..], length_string.len, "%d", @intCast(u32, request_response_state.*.?.file.?.len));
            if (length_string_len < 1) {
                return error.SnprintfError;
            }
            dbgLog("content-length {}", .{length_string[0..@intCast(u32, length_string_len)]});
            try tls.bufferedWriteG(conn, length_string[0..@intCast(u32, length_string_len)]);

            const mime_type = request_response_state.*.?.mime_type;
            if (mime_type != null) {
                try tls.bufferedWriteG(conn, "\r\nContent-Type: ");
                try tls.bufferedWriteG(conn, mime_type.?);
            }

            if (request_response_state.*.?.keep_alive) {
                try tls.bufferedWriteG(conn, "\r\nConnection: keep-alive\r\n");
            } else {
                try tls.bufferedWriteG(conn, "\r\nConnection: close\r\n");
            }

            try tls.bufferedWriteG(conn, httpExtraHeaders());
            try tls.bufferedWriteG(conn, "\r\n");
            request_response_state.*.?.response_headers_sent = true;
        }
    }

    if (request_response_state.* != null) {
        if (request_response_state.*.?.file == null) {
            request_response_state.* = null;
        } else {
            dbgLog("Sending file data. Data sent so far: {}", .{request_response_state.*.?.data_sent});
            request_response_state.*.?.data_sent += try tls.bufferedWrite(conn, request_response_state.*.?.file.?[request_response_state.*.?.data_sent..]);
            dbgLog("Data sent so far now: {}", .{request_response_state.*.?.data_sent});

            if (request_response_state.*.?.data_sent == request_response_state.*.?.file.?.len) {
                dbgLog("Sending file data. Finished sending data", .{});
                request_response_state.* = null;
            }
        }
    }

    if (!keep_alive and
        request_response_state.* == null)
    {
        try tls.flushWriteAndShutdown(conn);
    }
}
