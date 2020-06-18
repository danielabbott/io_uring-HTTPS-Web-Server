const std = @import("std");
const testing = std.testing;
const c_allocator = std.heap.c_allocator;
const parse = @import("Parse.zig");
const Files = @import("Files.zig");
const atoi = @import("Atoi.zig").atoi;
const ArrayList = std.ArrayList;

pub const Config = struct {
    threads: u32 = 0, // 0 = auto
    enable_statistics: bool = true,
    http_port: u16 = 80,
    https_port: u16 = 443,

    // Both are null terminated
    certificate_file_path: [*c]const u8 = "cert.pem",
    certificate_key_file_path: [*c]const u8 = "key.pem",
};

var config_ = Config{};

pub fn config() Config {
    return config_;
}

var http_extra_headers: []const u8 = "Strict-Transport-Security: max-age=63072000; includeSubDomains\r\n" ++
    "Content-Security-Policy: default-src 'none'; script-src 'self'; img-src 'self'; font-src 'self'; style-src 'self'; frame-ancestors 'none'\r\n" ++
    "Cache-Control: public, max-age=604800, immutable\r\n" ++
    "Referrer-Policy: strict-origin-when-cross-origin\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "X-Frame-Options: DENY\r\n" ++
    "X-XSS-Protection: 1; mode=block\r\n";

pub fn httpExtraHeaders() []const u8 {
    return http_extra_headers;
}

fn clamp(i: isize, low: isize, high: isize) isize {
    if (i < low) {
        return low;
    }
    if (i > high) {
        return high;
    }
    return i;
}

fn parseLine(line: []u8) !void {
    if (line.len == 0 or line[0] == '#') {
        return;
    }

    if (parse.caseInsensitiveStartsWith(line, "threads:")) {
        var value = line["threads:".len..];
        parse.skipWhitespace(&value) catch return;
        config_.threads = @intCast(u32, clamp(try atoi(value), 0, 1024));
    } else if (parse.caseInsensitiveStartsWith(line, "statistics:")) {
        var value = line["statistics:".len..];
        parse.skipWhitespace(&value) catch return;
        if (parse.caseInsensitiveCompareIgnoreEndWhitespace(value, "on")) {
            config_.enable_statistics = true;
        } else {
            config_.enable_statistics = false;
        }
    } else if (parse.caseInsensitiveStartsWith(line, "http port:")) {
        // TODO check http and https port numbers are not the same
        var value = line["http port:".len..];
        parse.skipWhitespace(&value) catch return;
        config_.http_port = @intCast(u16, clamp(try atoi(value), 0, 65535));
    } else if (parse.caseInsensitiveStartsWith(line, "https port:")) {
        var value = line["https port:".len..];
        parse.skipWhitespace(&value) catch return;
        config_.https_port = @intCast(u16, clamp(try atoi(value), 0, 65535));
    } else if (parse.caseInsensitiveStartsWith(line, "cert:")) {
        var value = line["cert:".len..];
        parse.skipWhitespace(&value) catch return;
        const path = value[0 .. parse.getLineLen(value) catch value.len];
        var i: usize = path.len - 1;
        while (i > 0) : (i -= 1) {
            if (path[i] != ' ' and path[i] != '\t') {
                break;
            }
            path[i] = 0;
        }
        config_.certificate_file_path = value.ptr; // Line was null terminated already
    } else if (parse.caseInsensitiveStartsWith(line, "cert key:")) {
        var value = line["cert key:".len..];
        parse.skipWhitespace(&value) catch return;
        const path = value[0 .. parse.getLineLen(value) catch value.len];
        var i: usize = path.len - 1;
        while (i > 0) : (i -= 1) {
            if (path[i] != ' ' and path[i] != '\t') {
                break;
            }
            path[i] = 0;
        }
        config_.certificate_key_file_path = value.ptr;
    }
}

fn parseConfigFile(s_: []u8) void {
    var s = s_;
    while (true) {
        parse.skipWhitespace(&s) catch return;

        const line_length = parse.getLineLen(s) catch s.len;
        if (line_length < 2) {
            break;
        }

        const line = s[0..line_length];
        s[line_length] = 0; // Null terminator hack for openSSL file name strings

        parseLine(line) catch |e| {
            std.debug.warn("Error parsing configuration file: {} on line: {}\n", .{
                e,
                line[0..std.math.min(512, line.len)],
            });
        };

        // Guaranteed to have the extra byte
        s = s[line_length + 1 ..];
    }
}

fn loadConfigFile() !void {
    var file = try std.fs.cwd().openFile("settings.conf", std.fs.File.OpenFlags{});
    defer file.close();

    var size: usize = try file.getEndPos();

    // File stays in memory
    var s: []u8 = try c_allocator.alloc(u8, size + 1);

    const bytesRead = try file.read(s[0..size]);
    if (bytesRead != size) {
        return error.IOError;
    }
    s[s.len - 1] = '\n'; // Extra newline needed for null terminator hack
    parseConfigFile(s);

    std.debug.warn("Config file loaded\n", .{});
}

fn loadHeadersFile() !void {
    var file = try std.fs.cwd().openFile("extra_headers.http", std.fs.File.OpenFlags{});
    defer file.close();

    var size: usize = try file.getEndPos();

    // File stays in memory
    var s: []u8 = try c_allocator.alloc(u8, size + 2);

    const bytesRead = try file.read(s[0..size]);
    if (bytesRead != size) {
        return error.IOError;
    }

    // Add final newline
    if (s[size - 1] == '\n') {
        s = s[0..size];
    } else {
        s[size] = '\r';
        s[size + 1] = '\n';
    }

    http_extra_headers = s;

    std.debug.warn("Config file loaded\n", .{});
}

fn parseFilesFile(s_: []const u8) !void {
    var s = s_;
    while (true) {
        parse.skipWhitespace(&s) catch return;

        const url = (parse.getCSVField(&s) catch return) orelse continue;
        const file_path = (parse.getCSVField(&s) catch return) orelse continue;
        const mime_type = parse.getCSVField(&s) catch return;

        const data = loadFile(file_path) catch |e| {
            std.debug.warn("Error loading file {}: {}", .{ file_path, e });
            break;
        };

        try Files.addStaticFile(url, data, mime_type);
    }
}

fn loadFile(path: []const u8) ![]const u8 {
    var file = try std.fs.cwd().openFile(path, std.fs.File.OpenFlags{});
    defer file.close();

    var size: usize = try file.getEndPos();

    // File stays in memory
    var s: []u8 = try c_allocator.alloc(u8, size);

    const bytesRead = try file.read(s);
    if (bytesRead != size) {
        return error.IOError;
    }
    return s;
}

fn loadStaticFiles() !void {
    var file = try std.fs.cwd().openFile("files.csv", std.fs.File.OpenFlags{});
    defer file.close();

    var size: usize = try file.getEndPos();

    // File stays in memory
    var s: []u8 = try c_allocator.alloc(u8, size + 1);

    const bytesRead = try file.read(s[0..size]);
    if (bytesRead != size) {
        return error.IOError;
    }

    s[size] = '\n';

    try parseFilesFile(s);
}

pub fn init() !void {
    loadConfigFile() catch {};
    loadHeadersFile() catch {};
    try loadStaticFiles();
}

test "Config" {
    const s = "threads:  4\n\n\nstatistics:on \nhttp port:80\nhttps port:443\ncert:a \ncert key:b   \t\n#a\n";
    var s2 = try testing.allocator.alloc(u8, s.len);

    std.mem.copy(u8, s2, s);
    parseConfigFile(s2);
    testing.expect(config().threads == 4);
    testing.expect(config().enable_statistics);
    testing.expect(config().http_port == 80);
    testing.expect(config().https_port == 443);
    testing.expect(config().certificate_file_path[0] == 'a' and config().certificate_file_path[1] == 0);
    testing.expect(config().certificate_key_file_path[0] == 'b' and config().certificate_key_file_path[1] == 0);

    testing.allocator.free(s2);
}
