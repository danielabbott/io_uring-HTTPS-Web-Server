const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const log_ = @import("Log.zig");
const fatalErrorLog_ = log_.fatalErrorLog;
const errLog_ = log_.errLog;
const dbgLog_ = log_.dbgLog;
const ArrayList = std.ArrayList;
const c_allocator = std.heap.c_allocator;
const page_allocator = std.heap.page_allocator;
const ObjectPool_ = @import("ObjectPool.zig");
const ObjectPool = ObjectPool_.ObjectPool;
const Queue = @import("Queue.zig").Queue;
const printStatistics = @import("Statistics.zig").printStatistics;
const config = @import("Config.zig").config;

pub fn fatalErrorLog(comptime s: []const u8, args: var) void {
    fatalErrorLog_("TCP: " ++ s, args);
}
pub fn dbgLog(comptime s: []const u8, args: var) void {
    dbgLog_("TCP: " ++ s, args);
}
pub fn errLog(comptime s: []const u8, args: var) void {
    errLog_("TCP: " ++ s, args);
}

const SOCKET_BACKLOG = 4096;
const QUEUE_DEPTH = 32768;
const READ_BUFFER_SIZE = 2 * 1024;
const NUM_READ_BUFFERS = 8192;
pub const WRITE_BUFFER_SIZE = 32 * 1024;
// const MAX_CONNECTIONS = 15000;

threadlocal var bytes_recieved_total: usize = 0;
threadlocal var bytes_sent_total: usize = 0;
threadlocal var connections_counter: u32 = 0;
threadlocal var peak_connections: u32 = 0;
threadlocal var events_pending: u32 = 0;

pub fn bytesRecievedTotal() usize {
    return bytes_recieved_total;
}
pub fn bytesSentTotal() usize {
    return bytes_sent_total;
}
pub fn numConnections() u32 {
    return connections_counter;
}
pub fn peakConnections() u32 {
    return peak_connections;
}
pub fn numPendingEvents() u32 {
    return events_pending;
}

threadlocal var io_uring_events_being_submitted: u32 = 0;

usingnamespace std.c;

const uring = @cImport({
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("liburing.h");
});

const ListenSocket = struct {
    fd: c_int,
    port: u16,

    fn queueAccept(self: *ListenSocket) !void {
        events_pending += 1;
        errdefer events_pending -= 1;

        var sqe: [*c]uring.io_uring_sqe = uring.io_uring_get_sqe(&ring);
        io_uring_events_being_submitted += 1;

        var conn = try connection_pool.alloc();
        conn.* = Connection{ .server_socket = self };

        var address_length: c_int = @sizeOf(uring.sockaddr_in);
        uring.io_uring_prep_accept(sqe, self.fd, @ptrCast([*c]uring.sockaddr, &conn.client_addr), @ptrCast([*c]c_uint, &address_length), 0);

        var event = try uring_event_pool.alloc();
        errdefer uring_event_pool.free(event);
        event.* = URingEventData{
            .op_type = .Accept,
            .conn = conn,
            .io = undefined, // not used
            .meta_data = undefined, // not used
            .connection = undefined,
        };

        // Accept events are always submitted, even when the queue is full

        uring.io_uring_sqe_set_data(sqe, @ptrCast(*c_void, event));
    }
};

pub threadlocal var write_buffer_pool: ObjectPool([WRITE_BUFFER_SIZE]u8, 256, writeBuffersOnAlloc) = undefined;

threadlocal var write_buffer_pool_alloc_done = false;

fn writeBuffersOnAlloc(e: []([WRITE_BUFFER_SIZE]u8)) ObjectPool_.OnAllocErrors!void {
    // TODO: System call hangs if events are pending
    if (write_buffer_pool_alloc_done) {
        errLog("Write buffer pool full", .{});
        return error.OnAllocError;
    }
    write_buffer_pool_alloc_done = true;

    // var vecs: [256]uring.iovec = undefined;
    // for (vecs) |*v, i| {
    //     v.*.iov_base = &e[i];
    //     v.*.iov_len = WRITE_BUFFER_SIZE;
    // }
    var vec = uring.iovec{
        .iov_base = &e[0],
        .iov_len = WRITE_BUFFER_SIZE * 256,
    };
    const ret = uring.io_uring_register_buffers(&ring, &vec, 1);
    if (ret != 0) {
        fatalErrorLog("io_uring_register_buffers error: {}", .{ret});
        return error.OnAllocError;
    }
}

threadlocal var server_sockets: ArrayList(ListenSocket) = undefined;
threadlocal var read_buffers: []u8 = undefined;

threadlocal var ring: uring.io_uring = undefined;

threadlocal var cqe: [*c]uring.io_uring_cqe = undefined;
threadlocal var events_backlog: Queue(*URingEventData) = undefined;

// Returns true if there is space in the event submission queue
// Returns false if the event was added to the backlog
fn incrementPendingEventCounter(event: *URingEventData) !bool {
    if (events_pending >= QUEUE_DEPTH) {
        dbgLog("IO Uring Queue full. Event type = {}", .{event.*.op_type});
        try events_backlog.enqueue(event);
        return false;
    } else {
        events_pending += 1;
        return true;
    }
}

threadlocal var uring_event_pool: ObjectPool(URingEventData, 256, null) = undefined;

pub fn eventPoolSize() usize {
    return uring_event_pool.size();
}

const URingEventData = struct {
    const OpType = enum {
        BufferRegister, // All other fields ignored for this op type
            Accept, Read, Write, Close
    };
    op_type: OpType,
    conn: *Connection,
    io: []const u8, // for writes
    meta_data: u64, // custom data for writes. Not used for reads as reads are not started by the app-level code
    connection: *Connection,

    fn submit(self: *URingEventData) !void {
        switch (self.op_type) {
            .Read => {
                var sqe: *uring.io_uring_sqe = uring.io_uring_get_sqe(&ring);
                io_uring_events_being_submitted += 1;

                uring.io_uring_prep_recv(sqe, self.connection.client_socket, null, READ_BUFFER_SIZE, 0);
                sqe_set_buf_group(@ptrToInt(sqe), 1);
                sqe_set_flags(@ptrToInt(sqe), uring.IOSQE_BUFFER_SELECT);

                uring.io_uring_sqe_set_data(sqe, @ptrCast(*c_void, self));
                self.connection.state = Connection.State.Reading;
            },
            .Write => {
                var sqe: *uring.io_uring_sqe = uring.io_uring_get_sqe(&ring);
                io_uring_events_being_submitted += 1;

                uring.io_uring_prep_write_fixed(sqe, self.connection.client_socket, self.io.ptr, @intCast(c_uint, self.io.len), 0, 0);
                sqe_set_flags(@ptrToInt(sqe), uring.IOSQE_IO_LINK); // force commands to be in order

                uring.io_uring_sqe_set_data(sqe, @ptrCast(*c_void, self));
                self.connection.state = Connection.State.Reading;
                self.connection.write_in_progress = true;
            },
            .Close => {
                var sqe: *uring.io_uring_sqe = uring.io_uring_get_sqe(&ring);
                io_uring_events_being_submitted += 1;

                uring.io_uring_prep_close(sqe, self.connection.client_socket);
                sqe_set_flags(@ptrToInt(sqe), uring.IOSQE_IO_LINK); // force commands to be in order

                uring.io_uring_sqe_set_data(sqe, @ptrCast(*c_void, self));
                self.connection.state = Connection.State.Closing;
            },
            else => {},
        }
    }
};

// Return non-null if connection should be denied
pub const callback_new_connection = fn (port: u16, conn: usize, ip: u128) ?usize;

pub const callback_data_received = fn (port: u16, user_data: usize, conn: usize, data: []const u8) void;

// data is the slice that was passed to sendData()
pub const callback_write_complete = fn (port: u16, user_data: usize, conn: usize, data: []const u8, meta_data: u64) void;

pub const callback_connection_lost = fn (port: u16, user_data: usize, conn: usize) void;

threadlocal var cb_new_connection: callback_new_connection = undefined;
threadlocal var cb_data_recieved: callback_data_received = undefined;
threadlocal var cb_connection_lost: callback_connection_lost = undefined;
threadlocal var cb_write_complete: ?callback_write_complete = null;

threadlocal var connection_pool: ObjectPool(Connection, 4096, null) = undefined;

pub fn connectionPoolSize() usize {
    return connection_pool.size();
}

const Connection = struct {
    const State = enum {
        Accepting, Reading, Closing
    };
    state: State = State.Accepting,

    write_in_progress: bool = false,

    server_socket: *ListenSocket,
    user_data: ?usize = null,

    // Only valid if state == Reading
    client_socket: c_int = undefined,
    client_addr: sockaddr_in6 = undefined,

    last_read_time: u64 = 0,

    fn accept(self: *Connection, fd: c_int) !void {
        self.client_socket = fd;

        const user_data = cb_new_connection(self.server_socket.port, @ptrToInt(self), @bitCast(u128, self.client_addr.addr));

        if (user_data == null) {
            return error.ConnectionRefused;
        }

        self.state = Connection.State.Reading;
        self.user_data = user_data;
        connections_counter += 1;
        peak_connections = std.math.max(peak_connections, connections_counter);
    }

    fn queueRead(self: *Connection) !void {
        if (self.state != .Reading) {
            return;
        }
        if (self.user_data == null) {
            assert(false);
            return error.MissingUserData;
        }

        var event = try uring_event_pool.alloc();
        errdefer uring_event_pool.free(event);
        event.* = URingEventData{
            .op_type = .Read,
            .conn = self,
            .io = undefined,
            .meta_data = 0,
            .connection = self,
        };

        if (try incrementPendingEventCounter(event)) {
            errdefer events_pending -= 1;
            try event.submit();
        }
    }

    fn readCompleteOrFailed(self: *Connection) !void {
        const buffer_id = cqe.*.flags >> 16;

        assert(self.user_data != null);
        if (cqe.*.res <= 0 or (cqe.*.flags & uring.IORING_CQE_F_BUFFER) == 0 or buffer_id > NUM_READ_BUFFERS or self.state != .Reading or self.user_data == null) {
            try reregisterBuffer(buffer_id); // Function will ignore any invalid IDs
            try self.queueClose();
            return;
        }

        self.last_read_time = std.time.milliTimestamp();

        const bytesRead = @intCast(u32, cqe.*.res);
        const buffer_idx = buffer_id - 1;

        const buffer = read_buffers[buffer_idx * READ_BUFFER_SIZE .. (buffer_idx + 1) * READ_BUFFER_SIZE];

        cb_data_recieved(self.server_socket.port, self.user_data.?, @ptrToInt(self), buffer[0..bytesRead]);

        try reregisterBuffer(buffer_id);
        try self.queueRead();
    }

    // N.B. Because it is possible for writes to only partially complete, only one write
    // may be queued per connection at once. This prevents parts of the data from being skipped.
    // N.B. Data must be a subslice of a buffer from write_buffer_pool
    fn queueWrite(self: *Connection, data: []const u8, meta_data: u64) !void {
        if (self.state != .Reading) {
            return error.InvalidState;
        }
        if (self.user_data == null) {
            assert(false);
            return error.MissingUserData;
        }

        if (self.write_in_progress) {
            assert(false);
            return error.WriteAlreadyQueued;
        }

        var event = try uring_event_pool.alloc();
        errdefer uring_event_pool.free(event);
        event.* = URingEventData{
            .op_type = .Write,
            .conn = self,
            .io = data,
            .meta_data = meta_data,
            .connection = self,
        };

        if (try incrementPendingEventCounter(event)) {
            errdefer events_pending -= 1;
            try event.submit();
        }
    }

    fn writeComplete(self: *Connection, event: *URingEventData, bytes_written: u32) void {
        self.write_in_progress = false;
        if (self.state != .Reading) {
            return;
        }
        if (self.user_data == null) {
            assert(false);
            return;
        }

        if (cb_write_complete != null) {
            cb_write_complete.?(self.server_socket.port, self.user_data.?, @ptrToInt(self), event.io[0..bytes_written], event.meta_data);
        }
    }

    fn queueClose(self: *Connection) !void {
        if (self.state == .Closing) {
            return;
        }
        self.state = .Closing;

        var event = try uring_event_pool.alloc();
        errdefer uring_event_pool.free(event);
        event.* = URingEventData{
            .op_type = .Close,
            .conn = self,
            .io = undefined,
            .meta_data = undefined, // not used
            .connection = self,
        };

        if (try incrementPendingEventCounter(event)) {
            errdefer events_pending -= 1;
            try event.submit();
        }
    }

    pub fn closed(self: *Connection) void {
        if (connections_counter > 0) {
            connections_counter -= 1;
        }
        if (self.state != .Accepting and self.user_data != null) {
            cb_connection_lost(self.server_socket.port, self.user_data.?, @ptrToInt(self));
        }
        self.user_data = null;
    }

    pub fn closeIfIdle(self: *Connection) !void {
        if (events_pending > QUEUE_DEPTH - 5) {
            return error.GenericCallbackError;
        }
        if (self.write_in_progress) {
            return;
        }
        if (std.time.milliTimestamp() - self.last_read_time < 10 * 1000) {
            return;
        }

        // Idle, close.
        self.queueClose() catch {
            return error.GenericCallbackError;
        };
    }
};

var one_time_init_done = false;

pub fn oneTimeInit() !void {
    if (one_time_init_done) {
        return;
    }
    one_time_init_done = true;

    // By default if the TCP connection is closed and we try to write to it
    // the server will crash.
    // This stops that. The write command will fail and the connection will
    // be closed gracefully.
    var sig_action = std.mem.zeroes(Sigaction);
    sig_action.sigaction = SIG_IGN;
    const e = sigaction(SIGPIPE, &sig_action, null);
}

pub const SocketInitInfo = struct {
    port: u16
};

// Blocks indefinitely
pub fn start(
    socket_setup_info: []const SocketInitInfo,
    cb_new_connection_: callback_new_connection,
    cb_data_recieved_: callback_data_received,
    cb_connection_lost_: callback_connection_lost,
    cb_write_complete_: ?callback_write_complete,
) !void {
    cb_new_connection = cb_new_connection_;
    cb_data_recieved = cb_data_recieved_;
    cb_connection_lost = cb_connection_lost_;
    cb_write_complete = cb_write_complete_;

    if (uring.io_uring_queue_init(QUEUE_DEPTH, &ring, 0) < 0) {
        return error.IoUringQueueInitError;
    }

    connection_pool = ObjectPool(Connection, 4096, null).init(c_allocator, c_allocator);
    uring_event_pool = ObjectPool(URingEventData, 256, null).init(c_allocator, c_allocator);
    write_buffer_pool = ObjectPool([WRITE_BUFFER_SIZE]u8, 256, writeBuffersOnAlloc).init(c_allocator, page_allocator);

    events_backlog = try Queue(*URingEventData).init(c_allocator, 256);

    try createListenSockets(socket_setup_info);
    try createBuffers();

    write_buffer_pool.free(try write_buffer_pool.alloc());

    try startListening();
}

fn createBuffers() !void {
    var event = try uring_event_pool.alloc();
    errdefer uring_event_pool.free(event);
    event.* = URingEventData{
        .op_type = .BufferRegister,
        .conn = undefined,
        .io = undefined,
        .meta_data = undefined,
        .connection = undefined,
    };

    events_pending += 1;
    errdefer events_pending -= 1;

    read_buffers = try c_allocator.alloc(u8, NUM_READ_BUFFERS * READ_BUFFER_SIZE);
    var sqe: *uring.io_uring_sqe = uring.io_uring_get_sqe(&ring);
    io_uring_events_being_submitted += 1;

    // Group 1, IDs start at 1
    uring.io_uring_prep_provide_buffers(sqe, @ptrCast(*c_void, read_buffers), READ_BUFFER_SIZE, NUM_READ_BUFFERS, 1, 1);

    uring.io_uring_sqe_set_data(sqe, @ptrCast(*c_void, event));
}

fn reregisterBuffer(id: u32) !void {
    if (id == 0 or id > NUM_READ_BUFFERS) {
        return;
    }

    const idx = id - 1;

    // TODO pass event as null
    var event = try uring_event_pool.alloc();
    errdefer uring_event_pool.free(event);
    event.* = URingEventData{
        .op_type = .BufferRegister,
        .conn = undefined,
        .io = undefined,
        .meta_data = undefined,
        .connection = undefined,
    };

    events_pending += 1;
    errdefer events_pending -= 1;

    var sqe: *uring.io_uring_sqe = uring.io_uring_get_sqe(&ring);
    io_uring_events_being_submitted += 1;

    // Group 1
    uring.io_uring_prep_provide_buffers(sqe, @ptrCast(*c_void, read_buffers[idx * READ_BUFFER_SIZE .. (idx + 1) * READ_BUFFER_SIZE]), READ_BUFFER_SIZE, 1, 1, @intCast(c_int, id));

    uring.io_uring_sqe_set_data(sqe, @ptrCast(*c_void, event));
}

// Convert from host byte order to network byte order
// Also works in reverse
// Does nothing on big endian CPUs
fn hton(comptime T: type, x: T) T {
    if (builtin.endian == builtin.Endian.Little) {
        return @byteSwap(T, x);
    }
    return x;
}

const ntoh = hton;

// Creates socket that listens for incoming connections
fn createListenSockets(socket_setup_info: []const SocketInitInfo) !void {
    server_sockets = ArrayList(ListenSocket).init(c_allocator);

    for (socket_setup_info) |info| {
        const server_socket = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
        if (server_socket == -1) {
            fatalErrorLog("Error creating listening socket (socket())", .{});
            return error.SocketError;
        }
        errdefer _ = close(server_socket);

        // Allow multiple sockets to be bound to the same port
        // So multiple threads can use different listening sockets on the same port
        var c_int_1: c_int = 1;
        const setsockopt_err = setsockopt(server_socket, SOL_SOCKET, SO_REUSEPORT, &c_int_1, @sizeOf(c_int));
        if (setsockopt_err != 0) {
            fatalErrorLog("Error setting SO_REUSEPORT", .{});
            return error.SocketError;
        }

        var addr = std.mem.zeroes(sockaddr_in6);
        addr.family = AF_INET6;
        addr.addr = uring.in6addr_any.__in6_u.__u6_addr8; // TODO remove
        addr.port = hton(u16, info.port);

        if (bind(server_socket, @ptrCast(*sockaddr, &addr), @sizeOf(sockaddr_in6)) < 0) {
            fatalErrorLog("Error binding socket: {}", .{getErrno(-1)});
            return error.SocketError;
        }

        if (listen(server_socket, SOCKET_BACKLOG) < 0) {
            fatalErrorLog("Error setting socket to listen", .{});
            return error.SocketError;
        }

        try server_sockets.append(ListenSocket{
            .fd = server_socket,
            .port = info.port,
        });
    }
}

extern fn io_uring_cqe_seen__(usize, usize) void;
extern fn io_uring_wait_cqe__(usize, usize) c_int;
extern fn sqe_set_buf_group(usize, u32) void;
extern fn sqe_set_flags(usize, u8) void;

threadlocal var time_last_killed_idle_connections: u64 = 0;
threadlocal var time_last_outputted_statistics: u64 = 0;

// Blocks indefinitely
fn startListening() !void {
    for (server_sockets.items) |*s| {
        try s.queueAccept();
    }

    while (true) {
        while (io_uring_events_being_submitted > 0) {
            const x = uring.io_uring_submit(&ring);
            if (x < 0) {
                return error.IoUringError;
            }
            if (x != io_uring_events_being_submitted) {
                dbgLog("io_uring_submit submitted fewer than expected", .{});
            }
            if (x == 0) {
                io_uring_events_being_submitted = 0;
                break;
            }
            io_uring_events_being_submitted -= @intCast(u32, x);
        }

        if (config().enable_statistics and
            std.time.milliTimestamp() - time_last_outputted_statistics > 5 * 1000)
        {
            time_last_outputted_statistics = std.time.milliTimestamp();
            printStatistics();
        }

        if (events_pending > (QUEUE_DEPTH / 10) * 9 and std.time.milliTimestamp() - time_last_killed_idle_connections > 2 * 60 * 1000) {
            // Thread reaching max capacity.
            connection_pool.forEach(Connection.closeIfIdle) catch {};
            time_last_killed_idle_connections = std.time.milliTimestamp();
        }

        while (events_pending < QUEUE_DEPTH - 5 and events_backlog.size > 0) {
            const e = events_backlog.dequeue() catch unreachable;
            dbgLog("Submitting event from backlog. Event type = {}", .{e.*.op_type});
            e.submit() catch {
                if (e.op_type != .BufferRegister and e.op_type != .Accept and e.op_type != .Close) {
                    e.connection.queueClose() catch {};
                }
            };
            // Do not free the event. It will be freed when it completes.
        }

        const ret = io_uring_wait_cqe__(@ptrToInt(&ring), @ptrToInt(&cqe));
        events_pending -= 1;

        if (ret < 0) {
            fatalErrorLog("io_uring_wait_cqe returned < 0", .{});
            return error.URingError;
        }

        const event = @intToPtr(*URingEventData, cqe.*.user_data);
        const conn = event.conn;

        dbgLog("async event complete: {}. events_pending is {}", .{ event.op_type, events_pending });

        if (event.op_type == URingEventData.OpType.Accept) {

            // Get socket ready to accept next connection
            conn.server_socket.queueAccept() catch |e| {
                fatalErrorLog("Error queueing accept on socket: {}", .{e});
                return e;
            };

            if (cqe.*.res >= 0) {
                // New connection
                var err = false;
                conn.accept(cqe.*.res) catch |e| {
                    errLog("Accept error: {}", .{e});
                    err = true;
                    conn.queueClose() catch {};
                };
                if (!err) {
                    conn.queueRead() catch |e| {
                        errLog("Initial read error: {}", .{e});
                        conn.queueClose() catch {};
                    };
                }
            } else {
                dbgLog("Error accepting connection. Server may be overloaded", .{});
                connection_pool.free(event.conn);
            }
        } else if (event.op_type == URingEventData.OpType.Read) {
            if (cqe.*.res <= 0) {
                // Socket closed or error
                if (cqe.*.res == -ENOBUFS) {
                    errLog("Out of read buffer space (ENOBUFS)!", .{});
                    // TODO: Allocate more read buffers
                } else if (cqe.*.res == 0) {
                    dbgLog("Connection closed", .{});
                } else if (cqe.*.res != -ECONNRESET) {
                    errLog("Read failed with error: {}", .{cqe.*.res});
                }
                conn.readCompleteOrFailed() catch |e| {
                    errLog("readCompleteOrFailed() failed with error: {}", .{e});
                };
                conn.queueClose() catch {};
            } else {
                bytes_recieved_total += @intCast(usize, cqe.*.res);
                conn.readCompleteOrFailed() catch |e| {
                    errLog("readCompleteOrFailed() failed with error: {}", .{e});
                    conn.queueClose() catch {};
                };
            }
        } else if (event.op_type == URingEventData.OpType.Write) {
            if (cqe.*.res <= 0) {
                if (cqe.*.res < 0 and cqe.*.res != -ECONNRESET) {
                    errLog("Write error. cqe.*.res = {}", .{cqe.*.res});
                }

                // Socket closed
                conn.queueClose() catch {};
            } else {
                bytes_sent_total += @intCast(usize, cqe.*.res);

                if (cqe.*.res < event.io.len) {
                    dbgLog("Incomplete write. cqe.*.res = {}, event.io.len = {}", .{ cqe.*.res, event.io.len });
                }

                conn.writeComplete(event, @intCast(u32, std.math.min(@intCast(usize, cqe.*.res), event.io.len)));

                if (cqe.*.res < event.io.len) {
                    conn.queueWrite(event.io[@intCast(usize, cqe.*.res)..], event.meta_data) catch |e| {
                        conn.queueClose() catch {};
                    };
                }
            }
        } else if (event.op_type == URingEventData.OpType.Close) {
            conn.closed();
            connection_pool.free(conn);
        }
        uring_event_pool.free(event);

        // uring.io_uring_cqe_seen(&ring, cqe);
        io_uring_cqe_seen__(@ptrToInt(&ring), @ptrToInt(cqe));
    }
}

// If this function returns an error then the connection is lost and socketFd is invalid
pub fn sendData(conn_: usize, data: []const u8, meta_data: u64) !void {
    const conn = @intToPtr(*Connection, conn_);
    conn.queueWrite(data, meta_data) catch |e| {
        conn.queueClose() catch {};
        return e;
    };
}

pub fn closeSocket(conn_: usize) void {
    dbgLog("Server closing TCP socket", .{});
    const conn = @intToPtr(*Connection, conn_);
    conn.queueClose() catch {};
}

pub fn ipToString(ip: u128, out: []u8) !void {
    const err = uring.inet_ntop(AF_INET6, &ip, out.ptr, @intCast(c_uint, out.len));

    if (err == null) {
        return error.GenericError;
    }
}
