const std = @import("std");
const testing = std.testing;

pub fn atoi(s: []const u8) !isize {
    if (s.len < 1) {
        return error.EmptyString;
    }

    var sign: isize = 1;
    var i: usize = 0;

    if (s[0] == '+') {
        i += 1;
    } else if (s[0] == '-') {
        sign = -1;
        i += 1;
    }

    if (s.len - i < 1) {
        return error.InvalidNumber;
    }

    var value: isize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') {
            while (i < s.len) : (i += 1) {
                if (s[i] != ' ' and s[i] != '\t' and s[i] != '\r' and s[i] != '\n') {
                    return error.InvalidNumber;
                }
            }
            break;
        }

        value *= 10;
        value += @intCast(isize, s[i]) - '0';
    }

    return value * sign;
}

test "atoi" {
    testing.expect((try atoi("00034")) == 34);
    testing.expectError(error.InvalidNumber, atoi("034 :)"));
    testing.expect((try atoi("-5675676358568")) == -5675676358568);
}
