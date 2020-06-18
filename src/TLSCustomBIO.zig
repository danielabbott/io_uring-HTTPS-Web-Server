const std = @import("std");
const log_ = @import("Log.zig");
const errLog_ = log_.errLog;
const dbgLog_ = log_.dbgLog;
const assert = std.debug.assert;
const openssl = @import("OpenSSL.zig").openssl;
const c_allocator = std.heap.c_allocator;
const page_allocator = std.heap.page_allocator;
const ObjectPool = @import("ObjectPool.zig").ObjectPool;
const TCPServer = @import("TCPServer.zig");
const tls = @import("TLS.zig");

const MAX_BUFFER_SIZE = TCPServer.WRITE_BUFFER_SIZE;

pub fn dbgLog(comptime s: []const u8, args: var) void {
    dbgLog_("TLSCustomBIO: " ++ s, args);
}
pub fn errLog(comptime s: []const u8, args: var) void {
    errLog_("TLSCustomBIO: " ++ s, args);
}

var bio_method: *openssl.BIO_METHOD = undefined;

pub fn init() !void {
    const meth = openssl.BIO_meth_new(openssl.BIO_get_new_index() | openssl.BIO_TYPE_SOURCE_SINK, "Custom BIO");
    if (meth == null) {
        return error.OutOfMemory;
    }
    bio_method = meth.?;

    _ = openssl.BIO_meth_set_write(bio_method, bioWrite);
    _ = openssl.BIO_meth_set_read(bio_method, bioRead);
    // _ = openssl.BIO_meth_set_puts(bio_method, bioPuts);
    // _ = openssl.BIO_meth_set_gets(bio_method, bioGets);
    _ = openssl.BIO_meth_set_create(bio_method, bioCreate);
    _ = openssl.BIO_meth_set_ctrl(bio_method, bioCtrl);
    _ = openssl.BIO_meth_set_destroy(bio_method, bioDestroy);
    // _ = openssl.BIO_meth_set_callback_ctrl(bio_method, bioCallbackCtrl);
}

// pub fn threadLocalInit() void {
// }

pub const CustomBIO = struct {
    bio: *openssl.BIO,

    // Not persistent, new buffer acquired for each write
    write_buffer: ?*([MAX_BUFFER_SIZE]u8) = null,

    data_length: u32 = 0,
    data_outgoing: bool = false,
    data_sent_confirmed: u32 = 0,

    next_read_data: ?[]const u8 = null,

    pub fn init(self: *CustomBIO) !void {
        const bio_ = openssl.BIO_new(bio_method);
        if (bio_ == null) {
            return error.OpenSSLError;
        }

        // _ = openssl.BIO_set_ex_data(bio_.?, 0, self);
        _ = openssl.BIO_set_data(bio_.?, self);

        self.* = CustomBIO{ .bio = bio_.? };
    }

    pub fn canSendData(self: *CustomBIO, l: u32) bool {
        return !self.data_outgoing and self.data_length + l <= MAX_BUFFER_SIZE;
    }

    pub fn flush(self: *CustomBIO, conn: usize) !void {
        if (self.write_buffer == null) {
            return;
        }

        if (self.data_outgoing) {
            return error.WaitingOnPrevWrite;
        }

        self.data_outgoing = true;

        dbgLog("Sending {} bytes", .{self.data_length});
        try TCPServer.sendData(conn, self.write_buffer.?.*[0..self.data_length], 0);
    }

    pub fn writeDone(self: *CustomBIO, conn: usize, data: []const u8) void {
        assert(self.data_outgoing);
        dbgLog("Write confirmed ({} bytes)", .{data.len});
        if (self.data_outgoing) {
            self.data_sent_confirmed += @intCast(u32, data.len);
            if (self.data_sent_confirmed >= self.data_length) {
                dbgLog("Write finished ({} bytes)", .{self.data_length});
                TCPServer.write_buffer_pool.free(self.write_buffer.?);
                self.write_buffer = null;
                self.data_sent_confirmed = 0;
                self.data_outgoing = false;
                self.data_length = 0;
            } else {
                dbgLog("Partial write. Written {}/{} bytes", .{ data.len, self.data_length });
            }
        }
        self.flush(conn) catch {};
    }
};

export fn bioCreate(bio: ?*openssl.BIO) c_int {
    openssl.BIO_set_init(bio, 1);
    return 1;
}

export fn bioDestroy(bio: ?*openssl.BIO) c_int {
    openssl.BIO_set_init(bio, 0);

    var custom_BIO = @ptrCast(*CustomBIO, @alignCast(8, openssl.BIO_get_data(bio)));

    if (custom_BIO.write_buffer != null) {
        TCPServer.write_buffer_pool.free(custom_BIO.write_buffer.?);
    }

    dbgLog("BIO destroyed.", .{});

    return 1;
}

// TODO: Can this copy be avoided? Maybe by taking control of OpenSSL's memory management
fn fillWriteBuffer(custom_BIO: *CustomBIO, data: []const u8) !void {
    if (custom_BIO.write_buffer == null) {
        custom_BIO.write_buffer = try TCPServer.write_buffer_pool.alloc();
    }
    std.mem.copy(u8, custom_BIO.write_buffer.?.*[custom_BIO.data_length .. custom_BIO.data_length + data.len], data);
    custom_BIO.data_length += @intCast(u32, data.len);
}

export fn bioWrite(bio: ?*openssl.BIO, data: [*c]const u8, data_len: c_int) c_int {
    assert(bio != null and data != null and data_len >= 0);
    openssl.BIO_clear_flags(bio, openssl.BIO_FLAGS_RWS | openssl.BIO_FLAGS_SHOULD_RETRY);

    if (data_len <= 0) {
        return 0;
    }

    var custom_BIO = @ptrCast(*CustomBIO, @alignCast(8, openssl.BIO_get_data(bio)));

    var cannot_write = false;
    if (custom_BIO.data_outgoing) {
        dbgLog("Data outgoing. cannot write", .{});
        cannot_write = true;
    }
    if (custom_BIO.data_length + @intCast(u32, data_len) > MAX_BUFFER_SIZE) {
        dbgLog("Not enough space in buffer. cannot write", .{});
        cannot_write = true;
    }

    fillWriteBuffer(custom_BIO, data[0..@intCast(u32, data_len)]) catch |e| {
        errLog("fillWriteBuffer error: {}", .{e});
        cannot_write = true;
    };

    if (cannot_write) {
        openssl.BIO_set_flags(bio, (openssl.BIO_FLAGS_WRITE | openssl.BIO_FLAGS_SHOULD_RETRY));
        return -1;
    }

    dbgLog("Write {} bytes", .{data_len});

    return data_len;
}

// TODO: Is there a way to avoid the copy?
export fn bioRead(bio: ?*openssl.BIO, data: [*c]u8, data_len: c_int) c_int {
    assert(bio != null and data != null and data_len >= 0);

    if (data_len <= 0) {
        return 0;
    }
    var custom_BIO = @ptrCast(*CustomBIO, @alignCast(8, openssl.BIO_get_data(bio)));

    if (custom_BIO.next_read_data != null and custom_BIO.next_read_data.?.len == 0) {
        custom_BIO.next_read_data = null;
    }

    openssl.BIO_clear_flags(bio, openssl.BIO_FLAGS_RWS | openssl.BIO_FLAGS_SHOULD_RETRY);

    if (custom_BIO.next_read_data == null) {
        openssl.BIO_set_flags(bio, (openssl.BIO_FLAGS_READ | openssl.BIO_FLAGS_SHOULD_RETRY));
        return -1;
    }

    var l = @intCast(usize, data_len);
    if (l > custom_BIO.next_read_data.?.len) {
        l = custom_BIO.next_read_data.?.len;
    }

    std.mem.copy(u8, data[0..l], custom_BIO.next_read_data.?[0..l]);

    if (l >= custom_BIO.next_read_data.?.len) {
        custom_BIO.next_read_data = null;
    } else {
        custom_BIO.next_read_data = custom_BIO.next_read_data.?[l..];
    }
    // next_read_data is now null if all data is been read

    return @intCast(c_int, l);
}

export fn bioCtrl(bio: ?*openssl.BIO, cmd: c_int, larg: c_long, pargs: ?*c_void) c_long {
    if (cmd == openssl.BIO_CTRL_PENDING or cmd == openssl.BIO_CTRL_WPENDING) {
        return 0;
    }

    return 1;
}
