const std = @import("std");
const c_allocator = std.heap.c_allocator;
const ObjectPool = @import("ObjectPool.zig").ObjectPool;
const TCPServer = @import("TCPServer.zig");

threadlocal var http_state_pool: ObjectPool(HTTPState, 64, null) = undefined;

pub fn statePoolSize() usize {
    return http_state_pool.size();
}

pub const HTTPState = struct {
    response_string: ?*([TCPServer.WRITE_BUFFER_SIZE]u8) = null,

    pub fn threadLocalInit() void {
        http_state_pool = ObjectPool(HTTPState, 64, null).init(c_allocator, c_allocator);
    }

    pub fn new() !usize {
        const state = try http_state_pool.alloc();
        state.* = HTTPState{};
        return @ptrToInt(state);
    }

    pub fn get(user_data: usize) !*HTTPState {
        if (user_data == 0) {
            return error.NoUserData;
        }
        return @intToPtr(*HTTPState, user_data);
    }

    pub fn free(self: *HTTPState, conn: usize) void {
        if (self.response_string != null) {
            TCPServer.write_buffer_pool.free(self.response_string.?);
        }
        http_state_pool.free(self);
    }

    pub fn free2(user_data: usize, conn: usize) void {
        @intToPtr(*HTTPState, user_data).free(conn);
    }
};
