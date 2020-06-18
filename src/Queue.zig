const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Queue that stores data in a contiguous array
/// Does *not* dynamically allocate memory.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        max_size: u32,
        items: []T,

        first: u32 = 0,
        size: u32 = 0,

        allocator: *Allocator,

        pub fn init(allocator: *Allocator, max_size: u32) !Self {
            return Self{
                .max_size = max_size,
                .items = try allocator.alloc(T, max_size),
                .allocator = allocator,
            };
        }

        pub fn enqueue(self: *Self, e: T) !void {
            if (self.size >= self.max_size) {
                return error.Full;
            }
            self.items[(self.first + self.size) % self.max_size] = e;
            self.size += 1;
        }

        pub fn dequeue(self: *Self) !T {
            if (self.size == 0) {
                return error.Empty;
            }
            const e = self.items[self.first % self.max_size];
            self.first = (self.first + 1) % self.max_size;
            self.size -= 1;
            return e;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }
    };
}

test "Queue init" {
    var queue = try Queue(i32).init(testing.allocator, 6);
    defer queue.deinit();

    testing.expect(queue.items.len == 6);
    testing.expect(queue.size == 0);
}

test "Queue enqueue, dequeue" {
    var queue = try Queue(i32).init(testing.allocator, 2);
    defer queue.deinit();

    try queue.enqueue(3);
    try queue.enqueue(6);
    testing.expectError(error.Full, queue.enqueue(3));

    testing.expect((try queue.dequeue()) == 3);
    testing.expect((try queue.dequeue()) == 6);
    testing.expectError(error.Empty, queue.dequeue());
}
