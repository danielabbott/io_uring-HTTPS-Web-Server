const std = @import("std");
const assert = std.debug.assert;
const c_allocator = std.heap.c_allocator;
const page_allocator = std.heap.page_allocator;
const Allocator = std.mem.Allocator;
const ObjectPool = @import("ObjectPool.zig").ObjectPool;

pub fn LinkedBuffers(comptime buffer_size: u32, comptime sub_pool_size: u32) type {
    return struct {
        const Self = @This();

        pub const Buffer = struct {
            next: ?*Buffer = null,
            data: *[buffer_size]u8,
        };

        buffer_pool: ObjectPool([buffer_size]u8, sub_pool_size, null),
        meta_pool: ObjectPool(Buffer, sub_pool_size, null),

        // allocator_lists is for object pool metadata and for Buffer linked lists
        pub fn init(allocator_lists: *Allocator, allocator_data: *Allocator) Self {
            return Self{
                .buffer_pool = ObjectPool([buffer_size]u8, sub_pool_size, null).init(allocator_lists, allocator_data),
                .meta_pool = ObjectPool(Buffer, sub_pool_size, null).init(allocator_lists, allocator_lists),
            };
        }

        // First Buffer object is created on stack, subsequent Buffer objects in chain are allocated
        // (Buffer is metadata not the buffer data itself)
        pub fn newBufferChain(self: *Self) !Buffer {
            return Buffer{ .data = try self.buffer_pool.alloc() };
        }

        pub fn freeBufferChain(self: *Self, first_buffer: *const Buffer) void {
            self.buffer_pool.free(first_buffer.data);

            var buffer: ?*Buffer = first_buffer.next;
            while (buffer != null) {
                self.buffer_pool.free(buffer.?.data);

                const next = buffer.?.next;
                self.meta_pool.free(buffer.?);
                buffer = next;
            }
        }

        pub fn addToChain(self: *Self, last_in_chain: *Buffer) !*Buffer {
            var next = try self.meta_pool.alloc();
            errdefer self.meta_pool.free(next);

            next.* = Buffer{ .data = try self.buffer_pool.alloc() };
            last_in_chain.next = next;
            return next;
        }

        pub fn getLastBuffer(self: *Self, first_buffer: *Buffer) *Buffer {
            var buffer: *Buffer = first_buffer;
            while (true) {
                if (buffer.next != null) {
                    buffer = buffer.next.?;
                } else {
                    break;
                }
            }
            return buffer;
        }

        pub fn addData(self: *Self, first_buffer: *?Buffer, data_length: *u32, data: []const u8) !void {
            if (first_buffer.* == null) {
                first_buffer.* = try self.newBufferChain();
                assert(data_length.* == 0);
            }

            var buffer = self.getLastBuffer(&first_buffer.*.?);
            var data_left = data[0..];

            // Fill up to end of first buffer

            const data_already_in_buffer_len = (data_length.* % buffer_size);

            var space_left_in_buffer = buffer_size - data_already_in_buffer_len;
            var l = space_left_in_buffer;
            if (l > data_left.len) {
                l = @intCast(u32, data_left.len);
            }
            std.mem.copy(u8, buffer.*.data[data_already_in_buffer_len .. data_already_in_buffer_len + l], data_left[0..l]);
            data_left = data_left[l..];
            data_length.* += @intCast(u32, l);

            if (data_left.len > 0) {
                buffer = try self.addToChain(buffer);
            } else {
                return;
            }

            // Fill subsequent buffers

            while (data_left.len > 0) {
                l = @intCast(u32, data_left.len);
                if (l > buffer_size) {
                    l = buffer_size;
                }
                std.mem.copy(u8, buffer.*.data[0..l], data_left[0..l]);
                data_left = data_left[l..];
                data_length.* += @intCast(u32, l);

                if (data_left.len > 0) {
                    buffer = try self.addToChain(buffer);
                }
            }
        }

        pub fn size(self: Self) usize {
            return self.buffer_pool.size();
        }
    };
}

test "Linked buffer" {
    var linked_buffer_obj = LinkedBuffers(4096, 1024).init(c_allocator, page_allocator);
    var chain1 = try linked_buffer_obj.newBufferChain();
    var chain2 = try linked_buffer_obj.newBufferChain();
    var chain3 = try linked_buffer_obj.newBufferChain();
    chain1.data[55] = 3;
    chain2.data[55] = 3;
    chain3.data[4096 - 1] = 3;
    var chain2_2 = try linked_buffer_obj.addToChain(&chain2);
    chain2_2.data[4096 - 1] = 66;
    linked_buffer_obj.freeBufferChain(&chain1);
    linked_buffer_obj.freeBufferChain(&chain2);
    linked_buffer_obj.freeBufferChain(&chain3);
}
