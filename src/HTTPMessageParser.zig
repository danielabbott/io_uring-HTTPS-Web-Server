const std = @import("std");
const dbgLog_ = @import("Log.zig").dbgLog;
const startsWith = std.mem.startsWith;
const eql = std.mem.eql;
const parse = @import("Parse.zig");

pub fn dbgLog(comptime s: []const u8, args: var) void {
    dbgLog_("HTTPS: " ++ s, args);
}

pub const RequestType = enum(u32) {
    OPTIONS, GET, HEAD, POST, PUT, DELETE, TRACE, CONNECT
};

const request_type_strings = [_]([]const u8){
    "OPTIONS ",
    "GET ",
    "HEAD ",
    "POST ",
    "PUT ",
    "DELETE ",
    "TRACE ",
    "CONNECT ",
};

pub fn getRequestType(s: *([]const u8)) !RequestType {
    var i: u32 = 0;
    while (i < request_type_strings.len) : (i += 1) {
        if (startsWith(u8, s.*, request_type_strings[i])) {
            s.* = s.*[request_type_strings[i].len..];
            return @intToEnum(RequestType, i);
        }
    }
    dbgLog("Unknown HTTP request type: {}", .{s.*[0..std.math.min(10, s.*.len)]});
    return error.RequestTypeNotRecognised;
}

pub fn getRequestURL(s: *([]const u8)) ![]const u8 {
    try parse.skipWhitespace(s);

    const url_length = try parse.strLenNonWhitespace(s.*);
    const url = s.*[0..url_length];

    s.* = s.*[url_length..];

    return url;
}

// Returns HTTP version (0 = 1.0, 1 = 1.1)
pub fn verifyHTTPVersion(s: *([]const u8)) !u1 {
    try parse.skipWhitespace(s);

    const http_version_length = try parse.strLenNonWhitespace(s.*);
    const http_version = s.*[0..http_version_length];

    var v: u1 = 1;

    if (eql(u8, http_version, "HTTP/1.1")) {
        v = 1;
    } else if (eql(u8, http_version, "HTTP/1.0")) {
        v = 0;
    } else {
        dbgLog("Expected HTTP/1.1 or HTTP/1.0, got {}", .{http_version});
        return error.InvalidHTTPVersion;
    }

    s.* = s.*[http_version_length..];
    return v;
}

// Returns null when the end of the request is reached (or if reached end of buffer)
// Whitespace is not removed
pub fn getNextHeaderField(s: *([]const u8)) !?[]const u8 {
    try parse.skipNewline(s);

    const line_length = try parse.getLineLen(s.*);
    if (line_length == 0) {
        s.* = s.*[1..];
        return null;
    }

    const line = s.*[0..line_length];
    s.* = s.*[line_length..];

    return line;
}

// E.g.
// header: "Connection: close"
// expected_header_name: "connection"
// Returns: "close"
pub fn getHeader(header_: []const u8, expected_header_name: []const u8) ?[]const u8 {
    var header = header_;

    if (header.len < expected_header_name.len + 2) {
        return null;
    }

    if (!parse.caseInsensitiveStartsWith(header, expected_header_name)) {
        return null;
    }

    header = header[expected_header_name.len..];
    if (header[0] != ':') {
        return null;
    }

    header = header[1..];
    parse.skipWhitespace(&header) catch {};

    return header;
}
