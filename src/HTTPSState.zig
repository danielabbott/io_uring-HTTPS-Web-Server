const std = @import("std");
const dbgLog = @import("Log.zig").dbgLog;
const c_allocator = std.heap.c_allocator;
const tls_ = @import("TLS.zig");
const TLSConnection = tls_.TLSConnection;
const HTTPRequestHandler = @import("HTTPRequestHandler.zig");
const ObjectPool = @import("ObjectPool.zig").ObjectPool;

const MAX_HEADER_SIZE = std.math.min(8192, tls_.BUFFER_SIZE);

threadlocal var http_state_pool: ObjectPool(HTTPSState, 4096, null) = undefined;

pub fn statePoolSize() usize {
    return http_state_pool.size();
}

// Per-connection state. Not persistent.
pub const HTTPSState = struct {
    tls: TLSConnection,
    request_response_state: ?HTTPRequestHandler.RequestResponseState = null,

    // Used for keeping track of position in decrypted read buffer
    read_buffer_index: u32 = 0,

    pub fn threadLocalInit() void {
        http_state_pool = ObjectPool(HTTPSState, 4096, null).init(c_allocator, c_allocator);
    }

    pub fn new() !usize {
        const state = try http_state_pool.alloc();
        errdefer http_state_pool.free(state);
        state.* = HTTPSState{
            .tls = TLSConnection{},
        };
        try state.*.tls.startConnection();
        return @ptrToInt(state);
    }

    pub fn get(user_data: usize) !*HTTPSState {
        if (user_data == 0) {
            return error.NoUserData;
        }
        return @intToPtr(*HTTPSState, user_data);
    }

    pub fn free(self: *HTTPSState, conn: usize) void {
        self.tls.deinit(conn);
        http_state_pool.free(self);
    }

    pub fn free2(user_data: usize, conn: usize) void {
        @intToPtr(*HTTPSState, user_data).free(conn);
    }

    pub fn read(self: *HTTPSState, conn: usize, encrypted_data: []const u8) !void {
        const data_in = try self.tls.read(conn, encrypted_data);

        if (data_in == 0) {
            // SSL handshake, nothing to be done
            return;
        }

        var decrypted_data = self.tls.read_buffer.?.data[self.read_buffer_index..std.math.min(tls_.BUFFER_SIZE, data_in)];
        var this_header = decrypted_data;

        while (this_header.len > 0) {
            if (self.request_response_state == null) {
                self.request_response_state = try HTTPRequestHandler.parseRequest(&this_header);

                if (self.request_response_state != null) {
                    // Header fully received.
                    if (this_header.len == 0 or self.request_response_state.?.http_version == 0) {
                        // Nothing else in the read buffer, clear the read buffer.
                        self.tls.resetRead();
                        self.read_buffer_index = 0;
                    } else {
                        // Another header is in the read buffer
                        self.read_buffer_index += @intCast(u32, decrypted_data.len - this_header.len);
                    }
                } else {
                    if (data_in >= tls_.BUFFER_SIZE and self.read_buffer_index > 0) {
                        // TLS read buffer is full, move the data to the start of the buffer to make space
                        std.mem.copy(u8, self.tls.read_buffer.?.data[0..decrypted_data.len], decrypted_data);
                        self.read_buffer_index = 0;
                        break;
                    }

                    // Don't call tls.resetRead. Data will be read again next time, hopefully with the full headers
                    if (data_in >= tls_.BUFFER_SIZE) {
                        // TODO: Support request headers bigger than 1 buffer?
                        return error.HeadersTooLarge;
                    }
                    break;
                }
            }
            // Now sending response headers and data
            if (!self.request_response_state.?.response_headers_sent and
                tls_.BUFFER_SIZE - self.tls.write_tmp_buffer_len < MAX_HEADER_SIZE)
            {
                // Not enough buffer space to store biggest possible headers
                // Do it later (in writeDone())
                break;
            }
            try HTTPRequestHandler.sendResponse(conn, &self.tls, &self.request_response_state);
            if (self.request_response_state != null) {
                break;
            }
        }
        try self.tls.flushWrite(conn);
    }

    pub fn writeDone(self: *HTTPSState, conn: usize, data: []const u8) !void {
        try self.tls.writeDone(conn, data);
        if (self.request_response_state != null) {
            if (self.request_response_state.?.response_headers_sent or tls_.BUFFER_SIZE - self.tls.write_tmp_buffer_len < MAX_HEADER_SIZE) {
                // Can send headers and data now.
                try HTTPRequestHandler.sendResponse(conn, &self.tls, &self.request_response_state);
                try self.tls.flushWrite(conn);
            }
        }
    }
};
