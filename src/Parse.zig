const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

// Returns an error if the end of the string is reached

pub fn skipWhitespace(s: *([]const u8)) !void {
    var i: u32 = 0;
    while (i < s.*.len and (s.*[i] == ' ' or s.*[i] == '\t' or s.*[i] == '\n' or s.*[i] == '\r')) {
        i += 1;
    }
    if (i == s.*.len) {
        return error.EndOfString;
    }
    s.* = s.*[i..];
}

test "skipWhitespace" {
    var s: []const u8 = "  \nabc ";
    try skipWhitespace(&s);
    testing.expect(std.mem.eql(u8, s, "abc "));
}

pub fn skipNewline(s: *([]const u8)) !void {
    if (s.*.len == 0) {
        return error.EmptyString;
    }
    if (s.*[0] == '\n') {
        s.* = s.*[1..];
    } else {
        if (s.*.len == 1) {
            if (s.*[0] == '\r') {
                return error.InvalidNewLine;
            }
        } else {
            // len > 1, first char != '\n'
            if (s.*[0] == '\r' and s.*[1] == '\n') {
                s.* = s.*[2..];
            }
        }
    }
}

test "skipNewline" {
    var s: []const u8 = "\nb";
    try skipNewline(&s);
    testing.expect(std.mem.eql(u8, s, "b"));

    s = "\r\nb";
    try skipNewline(&s);
    testing.expect(std.mem.eql(u8, s, "b"));

    s = "a\r\nb";
    try skipNewline(&s);
    testing.expect(std.mem.eql(u8, s, "a\r\nb"));
}

// Returns an error if the rest of the string is non-whitespace
pub fn strLenNonWhitespace(s: []const u8) !u32 {
    var i: u32 = 0;
    while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != '\n' and s[i] != '\r') {
        i += 1;
    }
    if (i == s.len) {
        return error.EndOfString;
    }
    return i;
}

test "strLenNonWhitespace" {
    testing.expect((try strLenNonWhitespace("abc\t    \t")) == 3);
}

// Returns bytes until next \n or \r\n
pub fn getLineLen(s: []const u8) !u32 {
    var i: u32 = 0;
    while (i < s.len and s[i] != '\n' and s[i] != '\r') {
        i += 1;
    }
    if (i == s.len) {
        return error.EndOfString;
    }
    return i;
}

test "getLineLen" {
    testing.expect((try getLineLen("abc\n")) == 3);
}

pub fn caseInsensitiveStartsWith(s: []const u8, prefix: []const u8) bool {
    assert(prefix.len != 0 and s.len != 0);
    if (prefix.len > s.len or prefix.len == 0 or s.len == 0) {
        return false;
    }

    var i: u32 = 0;
    while (i < prefix.len) : (i += 1) {
        if (s[i] == prefix[i]) {
            continue;
        }

        if (s[i] >= 'a' and s[i] < 'z') {
            if (prefix[i] != s[i] - ('a' - 'A')) {
                return false;
            }
        } else if (s[i] >= 'A' and s[i] < 'Z') {
            if (prefix[i] != s[i] + ('a' - 'A')) {
                return false;
            }
        } else {
            return false;
        }
    }

    return true;
}

test "caseInsensitiveStartsWith" {
    testing.expect(caseInsensitiveStartsWith("abc\n", "aBc"));
    testing.expect(!caseInsensitiveStartsWith("abc\n", "5"));
    testing.expect(!caseInsensitiveStartsWith("abc\n", "long string"));
    testing.expect(!caseInsensitiveStartsWith("abc\n", " a"));
    testing.expect(!caseInsensitiveStartsWith("abc a: def\n", "abc:"));
}

// Ignores end whitespace on s
pub fn caseInsensitiveCompareIgnoreEndWhitespace(s: []const u8, b: []const u8) bool {
    if (!caseInsensitiveStartsWith(s, b)) {
        return false;
    }

    if (s.len == b.len) {
        return true;
    }

    var s2 = s[b.len..];
    var i: u32 = 0;
    while (i < s2.len) : (i += 1) {
        if (s2[i] != ' ' and s2[i] != '\t' and s2[i] != '\r' and s2[i] != '\n') {
            return false;
        }
    }
    return true;
}

test "caseInsensitiveCompareIgnoreEndWhitespace" {
    testing.expect(caseInsensitiveCompareIgnoreEndWhitespace("abc   ", "aBc"));
    testing.expect(!caseInsensitiveCompareIgnoreEndWhitespace("abc   a", "aBc"));
    testing.expect(!caseInsensitiveCompareIgnoreEndWhitespace("abcd  ", "aBc "));
}

// Returns error when end of string is reached
// Returns null when end of line is reached
// Moves slice to start of next field/line
pub fn getCSVField(s_: *([]const u8)) !?[]const u8 {
    if (s_.*.len == 0) {
        return error.EndOfString;
    }

    if (s_.*[0] == '\n') {
        s_.* = s_.*[1..];
        return null;
    }

    if (s_.*[0] == '\r') {
        if (s_.*.len > 1 and s_.*[1] == '\n') {
            s_.* = s_.*[2..];
        } else {
            s_.* = s_.*[1..];
        }
        return null;
    }

    const s = s_.*;

    var i: u32 = 0;
    while (i < s.len and s[i] != ',' and s[i] != '\n' and s[i] != '\r') {
        i += 1;
    }
    if (i == s.len) {
        s_.* = s[s.len - 1 .. s.len - 1];
        assert(s_.*.len == 0);
        return s;
    }

    s_.* = s[i..];
    if (s_.*[0] == ',') {
        s_.* = s_.*[1..];
    }

    return s[0..i];
}

test "csv" {
    var s: []const u8 = "a,b,c\nc,d,eee\n,,f,\n";
    testing.expect(std.mem.eql(u8, (try getCSVField(&s)).?, "a"));
    testing.expect(std.mem.eql(u8, (try getCSVField(&s)).?, "b"));
    testing.expect(std.mem.eql(u8, (try getCSVField(&s)).?, "c"));
    testing.expect((try getCSVField(&s)) == null);
    try skipWhitespace(&s);
    testing.expect(std.mem.eql(u8, (try getCSVField(&s)).?, "c"));
    testing.expect(std.mem.eql(u8, (try getCSVField(&s)).?, "d"));
    testing.expect(std.mem.eql(u8, (try getCSVField(&s)).?, "eee"));
    testing.expect((try getCSVField(&s)) == null);
    try skipWhitespace(&s);
    testing.expect(std.mem.eql(u8, (try getCSVField(&s)).?, ""));
    testing.expect(std.mem.eql(u8, (try getCSVField(&s)).?, ""));
    testing.expect(std.mem.eql(u8, (try getCSVField(&s)).?, "f"));
    testing.expect((try getCSVField(&s)) == null);
    testing.expectError(error.EndOfString, getCSVField(&s));
}
