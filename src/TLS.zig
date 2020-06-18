const std = @import("std");
const assert = std.debug.assert;
const log_ = @import("Log.zig");
const errLog_ = log_.errLog;
const dbgLog_ = log_.dbgLog;
const TCPServer = @import("TCPServer.zig");
const c_allocator = std.heap.c_allocator;
const page_allocator = std.heap.page_allocator;
const ObjectPool = @import("ObjectPool.zig").ObjectPool;
const openssl = @import("OpenSSL.zig").openssl;
const tlsCustomBIO = @import("TLSCustomBIO.zig");
const CustomBIO = tlsCustomBIO.CustomBIO;
const builtin = @import("builtin");
const LinkedBuffers = @import("LinkedBuffers.zig").LinkedBuffers;
const config = @import("Config.zig").config;

pub fn dbgLog(comptime s: []const u8, args: var) void {
    dbgLog_("TLS: " ++ s, args);
}
pub fn errLog(comptime s: []const u8, args: var) void {
    errLog_("TLS: " ++ s, args);
}

pub const BUFFER_SIZE = 16384; // 4096/8192/16384
pub threadlocal var linked_buffer_obj: LinkedBuffers(BUFFER_SIZE, 256) = undefined;

pub fn writeBufferPoolSize() usize {
    return linked_buffer_obj.size();
}

var ssl_context: *openssl.SSL_CTX = undefined;

export fn doErrPrint(str: [*c]const u8, len: usize, d: ?*c_void) c_int {
    errLog("{}", .{str[0..len]});
    return 1;
}

fn printErrors() void {
    if (builtin.mode == .Debug) {
        var data: [256]u8 = undefined;
        openssl.ERR_print_errors_cb(doErrPrint, null);
    }
}

pub fn init() !void {
    const method = openssl.TLS_server_method();

    const ctx = openssl.SSL_CTX_new(method);
    if (ctx == null) {
        return error.OpenSSLError;
    }
    ssl_context = ctx.?;

    // _ = openssl.SSL_CTX_ctrl(ssl_context, openssl.SSL_CTRL_SET_MIN_PROTO_VERSION, openssl.TLS1_3_VERSION, null);
    _ = openssl.SSL_CTX_ctrl(ssl_context, openssl.SSL_CTRL_SET_MIN_PROTO_VERSION, openssl.TLS1_2_VERSION, null);

    _ = openssl.SSL_CTX_ctrl(ssl_context, openssl.SSL_CTRL_MODE, openssl.SSL_MODE_RELEASE_BUFFERS, null);

    if (openssl.SSL_CTX_use_certificate_file(ssl_context, config().certificate_file_path, openssl.SSL_FILETYPE_PEM) <= 0) {
        return error.OpenSSLError;
    }

    if (openssl.SSL_CTX_use_PrivateKey_file(ssl_context, config().certificate_key_file_path, openssl.SSL_FILETYPE_PEM) <= 0) {
        return error.OpenSSLError;
    }

    try tlsCustomBIO.init();
}

pub fn threadLocalInit() void {
    // tlsCustomBIO.threadLocalInit();
    linked_buffer_obj = LinkedBuffers(BUFFER_SIZE, 256).init(c_allocator, page_allocator);
}

// N.B. If a function returns an error then the TLS connection is closed (underlying TCP connection remains open)
pub const TLSConnection = struct {
    // Undefined variables initialised in startConnection
    ssl: ?*openssl.SSL = null,
    ssl_accept_finished: bool = false,

    bio: CustomBIO = undefined,

    // Not persistent, new buffer acquired for each read
    read_buffer: ?LinkedBuffers(BUFFER_SIZE, 256).Buffer = null,
    data_read: u32 = 0,

    // Only ever has 1 buffer object
    // Data is unencrypted
    // Encrypted buffer is in the BIO object
    write_tmp_buffer: ?LinkedBuffers(BUFFER_SIZE, 256).Buffer = null,
    write_tmp_buffer_len: u32 = 0,

    fatal_error: bool = false,
    trying_to_flush: bool = false, // true -> not accepting new data until flushWrite() succeeds
    shutdown_in_progress: bool = false,

    // for retrying writes
    prev_write_command_fail: ?[]const u8 = null,

    pub fn startConnection(self: *TLSConnection) !void {
        const ssl_ = openssl.SSL_new(ssl_context);
        if (ssl_ == null) {
            return error.OpenSSLError;
        }
        self.ssl = ssl_.?;

        errdefer {
            openssl.SSL_free(self.ssl.?);
            self.ssl = null;
        }

        openssl.SSL_set_accept_state(self.ssl.?);

        try self.bio.init();
        openssl.SSL_set_bio(self.ssl.?, self.bio.bio, self.bio.bio);

        dbgLog("OpenSSL init okay", .{});
    }

    fn checkFatalError(self: *TLSConnection, e: c_int) bool {
        if (e == openssl.SSL_ERROR_SYSCALL or e == openssl.SSL_ERROR_SSL) {
            // These 2 errors are unrecoverable
            // If either of these errors occur then SSL_shutdown() must not be called
            self.fatal_error = true;
            return true;
        }
        return false;
    }

    // N.B. Best not to mix calls to bufferedWrite and sendData - the data will be out of order
    // flushStream is called every BUFFER_SIZE bytes
    // call flushStream when all data is written to send the last bit of data
    // Returns number of bytes written to the buffer
    // N.B. If the returned value < data_.len then the write /must/ be completed later.
    //      OpenSSL expects the same parameters to OpenSSL_Write()
    pub fn bufferedWrite(self: *TLSConnection, conn: usize, data_: []const u8) !u32 {
        if (self.shutdown_in_progress) {
            try self.shutdown(conn);
            return 0;
        }

        if (self.trying_to_flush) {
            try self.flushWrite(conn);
            if (self.trying_to_flush) {
                return 0;
            }
        }

        var data = data_;
        if (self.write_tmp_buffer_len >= BUFFER_SIZE) {
            dbgLog("buffer is full", .{});
            return 0;
        }
        dbgLog("bufferedWrite ptr {}, len {}", .{ data_.ptr, data_.len });

        var written: u32 = 0;

        if (self.write_tmp_buffer_len > 0 and self.write_tmp_buffer_len + data.len >= BUFFER_SIZE) {
            // About to go over BUFFER_SIZE bytes

            // Write up to the end of the buffer
            const l = BUFFER_SIZE - self.write_tmp_buffer_len;
            try linked_buffer_obj.addData(&self.write_tmp_buffer, &self.write_tmp_buffer_len, data[0..l]);
            written += l;
            data = data[l..];
            try self.flushWrite(conn);

            if (self.trying_to_flush) {
                // Data is still in buffer. Cannot write any more just yet.
                dbgLog("Waiting on TCP send.", .{});
                return written;
            }
        }

        if (self.write_tmp_buffer_len == 0) {
            while (data.len >= BUFFER_SIZE) {
                dbgLog("Sending [BUFFER_SIZE={}] bytes of data.", .{BUFFER_SIZE});
                if (!(try self.sendData(conn, data[0..BUFFER_SIZE]))) {
                    dbgLog("Waiting on TCP send.", .{});
                    return written;
                }
                written += BUFFER_SIZE;
                data = data[BUFFER_SIZE..];
            }
        }

        if (data.len > 0 and data.len < BUFFER_SIZE) {
            dbgLog("Storing {} bytes of data in TLS buffer", .{data.len});
            try linked_buffer_obj.addData(&self.write_tmp_buffer, &self.write_tmp_buffer_len, data);
            written += @intCast(u32, data.len);
        }

        return written;
    }

    pub fn bufferedWriteG(self: *TLSConnection, conn: usize, data: []const u8) !void {
        const success = (try self.bufferedWrite(conn, data)) == data.len;
        assert(success);
        if (!success) {
            return error.BufferedWriteGError;
        }
    }

    // returns true if data is now being sent, false if need to wait for data to be received (data is not sent)
    // data slice does not need to remain valid. It is encrypted and stored.
    // failed writes must be retried
    // Do not call this. Use bufferedWrite()
    fn sendData(self: *TLSConnection, conn: usize, data: []const u8) !bool {
        if (self.ssl == null) {
            assert(false);
            return error.SSLConnFreed;
        }

        if (!self.bio.canSendData(@intCast(u32, data.len))) {
            dbgLog("Cannot send right now, waiting on BIO", .{});
            return false;
        }

        dbgLog("send len={} ptr = {}\n", .{ data.len, data.ptr });
        dbgLog("send: {}\n", .{data[0..std.math.min(450, data.len)]});

        if (!(self.prev_write_command_fail == null or
            (self.prev_write_command_fail.?.ptr == data.ptr and self.prev_write_command_fail.?.len == data.len)))
        {
            assert(false);
            return error.InvalidWriteRetry;
        }

        assert(self.prev_write_command_fail == null or
            (self.prev_write_command_fail.?.ptr == data.ptr and self.prev_write_command_fail.?.len == data.len));
        self.prev_write_command_fail = null;

        errdefer self.deinit(conn);

        openssl.ERR_clear_error();
        const w = openssl.SSL_write(self.ssl.?, data.ptr, @intCast(c_int, data.len));

        if (w != data.len) {
            const e = openssl.SSL_get_error(self.ssl.?, w);
            if (e == openssl.SSL_ERROR_WANT_READ or e == openssl.SSL_ERROR_WANT_WRITE) {
                dbgLog("SSL_Write SSL_ERROR_WANT_READ or SSL_ERROR_WANT_WRITE w={}, e={}", .{ w, e });
                self.prev_write_command_fail = data;
                return false;
            } else {
                errLog("ssl write error = {}, return val was {}", .{ e, w });
                printErrors();
                _ = self.checkFatalError(e);
                return error.OpenSSLError;
            }
        }
        return true;
    }

    fn flushWrite_(self: *TLSConnection, conn: usize) !void {
        if (self.ssl == null) {
            assert(false);
            return error.SSLConnFreed;
        }
        errdefer self.deinit(conn);

        dbgLog("flushWrite. self.write_tmp_buffer_len={}", .{self.write_tmp_buffer_len});

        if (self.write_tmp_buffer_len > 0) {
            assert(self.write_tmp_buffer.?.next == null);
            if (try self.sendData(conn, self.write_tmp_buffer.?.data[0..self.write_tmp_buffer_len])) {
                dbgLog("flushWrite data sent success", .{});
                self.write_tmp_buffer_len = 0;
                linked_buffer_obj.freeBufferChain(&self.write_tmp_buffer.?);
                self.write_tmp_buffer = null;
                self.trying_to_flush = false;
            } else {
                self.trying_to_flush = true;
            }
        } else {
            self.trying_to_flush = false;
        }
    }

    pub fn flushWriteAndShutdown(self: *TLSConnection, conn: usize) !void {
        try self.flushWrite_(conn);

        if (!self.trying_to_flush) {
            try self.shutdown(conn);
        }
    }

    pub fn flushWrite(self: *TLSConnection, conn: usize) !void {
        try self.flushWrite_(conn);
        self.bio.flush(conn) catch {};
    }

    // Called when a write on the TCP stream has completed successfully
    pub fn writeDone(self: *TLSConnection, conn: usize, data: []const u8) !void {
        if (self.ssl == null) {
            assert(false);
        }

        dbgLog("write done", .{});

        self.bio.writeDone(conn, data);
        try self.flushWrite(conn);

        if (self.shutdown_in_progress) {
            try self.shutdown(conn);
        }
    }

    // data_in is the encrypted data (from TCPServer.zig)
    // Remember to call readReset() or buffer won't be emptied
    // Data is in self.read_buffer
    // Returns number of bytes read into self.read_buffer or 0 if handshake is being done
    // Returns error.ConnectionClosed if connection is closed.
    pub fn read(self: *TLSConnection, conn: usize, data_in: []const u8) !u32 {
        if (self.ssl == null) {
            assert(false);
            return error.SSLConnFreed;
        }

        if (self.shutdown_in_progress) {
            try self.shutdown(conn);
            return 0;
        }

        errdefer self.deinit(conn);

        self.bio.next_read_data = data_in;

        if (!self.ssl_accept_finished) {
            openssl.ERR_clear_error();
            const accept_result = openssl.SSL_accept(self.ssl.?);
            if (accept_result == 0) {
                errLog("ssl accept error", .{});
                return error.OpenSSLError;
            }
            self.ssl_accept_finished = accept_result == 1;

            if (!self.ssl_accept_finished) {
                // accept_result < 0
                const e = openssl.SSL_get_error(self.ssl.?, accept_result);
                if (e != openssl.SSL_ERROR_WANT_READ and e != openssl.SSL_ERROR_WANT_WRITE) {
                    errLog("ssl accept error = {}, return val was {}", .{ e, accept_result });
                    printErrors();
                    _ = self.checkFatalError(e);
                    return error.OpenSSLError;
                }
            }
        }

        if (self.ssl_accept_finished and self.bio.next_read_data != null) {
            self.read_buffer = try linked_buffer_obj.newBufferChain();
            var buffer = &self.read_buffer.?;

            while (true) {
                openssl.ERR_clear_error();
                const dst = buffer.data[(self.data_read % BUFFER_SIZE)..];
                const r = openssl.SSL_read(self.ssl.?, dst.ptr, @intCast(c_int, dst.len));
                if (r <= 0) {
                    const e = openssl.SSL_get_error(self.ssl.?, r);
                    if (e == openssl.SSL_ERROR_ZERO_RETURN) {
                        return error.ConnectionClosed;
                    }
                    if (e != openssl.SSL_ERROR_WANT_READ and e != openssl.SSL_ERROR_WANT_WRITE) {
                        errLog("ssl read error = {}, return val was {}", .{ e, r });
                        printErrors();
                        _ = self.checkFatalError(e);
                        return error.OpenSSLError;
                    } else if (e == openssl.SSL_ERROR_WANT_READ) {
                        dbgLog("SSL_read SSL_ERROR_WANT_READ", .{});
                    } else if (e == openssl.SSL_ERROR_WANT_WRITE) {
                        dbgLog("SSL_read SSL_ERROR_WANT_WRITE", .{});
                    }
                    break;
                } else {
                    // No error
                    self.data_read += @intCast(u32, r);

                    if (self.bio.next_read_data == null) {
                        // No more data
                        break;
                    }

                    // More data to go

                    if (self.data_read % BUFFER_SIZE == 0) {
                        buffer = try linked_buffer_obj.addToChain(buffer);
                    }
                }
            }
            try self.flushWrite(conn);
            assert(self.bio.next_read_data == null or self.bio.next_read_data.?.len == 0);
            return self.data_read;
        }
        try self.flushWrite(conn);
        assert(self.bio.next_read_data == null or self.bio.next_read_data.?.len == 0);
        return 0;
    }

    // Call when done with the data from read()
    pub fn resetRead(self: *TLSConnection) void {
        if (self.ssl == null) {
            assert(false);
        }

        if (self.read_buffer != null) {
            linked_buffer_obj.freeBufferChain(&self.read_buffer.?);
            self.read_buffer = null;
            self.data_read = 0;
        }
    }

    // Server-initiated shutdown
    pub fn shutdown(self: *TLSConnection, conn: usize) !void {
        if (self.ssl == null) {
            assert(false);
        }
        self.shutdown_in_progress = true;

        if (self.trying_to_flush) {
            try self.flushWrite(conn);
            if (self.trying_to_flush) {
                return;
            }
        }

        const r = openssl.SSL_shutdown(self.ssl.?);
        self.bio.flush(conn) catch {};
        return error.TLSShutDown;
    }

    pub fn deinit(self: *TLSConnection, conn: usize) void {
        if (self.ssl != null) {
            self.resetRead();
            if (self.write_tmp_buffer != null) {
                linked_buffer_obj.freeBufferChain(&self.write_tmp_buffer.?);
                self.write_tmp_buffer = null;
            }
            openssl.SSL_free(self.ssl.?);
            self.ssl = null;
        }
    }
};
