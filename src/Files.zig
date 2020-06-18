const std = @import("std");
const c_allocator = std.heap.c_allocator;
const StringHashMap = std.StringHashMap;

// For dynamic files
// const GenerateFileError = error{ OutOfMemory, GenericError };
// pub const callback_generate_file = fn (uid: u32, url: []const u8) GenerateFileError![]const u8;
// pub const callback_done_with = fn (data: []const u8) void;

const FileData = struct {
    dynamic: bool, mime_type: ?[]const u8, data: union {
        // if dynamic = false
        static_data: []const u8,

        // if dynamic = true
        // dynamic_file_data: struct {
        //     uid: u32, callback: callback_generate_file, callback_done_with: callback_done_with
        // }
    }
};

var files_map: StringHashMap(FileData) = undefined;

pub fn init() void {
    files_map = StringHashMap(FileData).init(c_allocator);
}

// Pointers must remain valid
pub fn addStaticFile(url: []const u8, data: []const u8, mime_type: ?[]const u8) !void {
    _ = try files_map.put(url, FileData{
        .dynamic = false,
        .mime_type = mime_type,
        .data = .{ .static_data = data },
    });
}

var uid_counter: u32 = 0;

// Pointer must remain valid
// Returns unique id that is passed to the callback
// pub fn addDynamicFile(url: []const u8, cb_generate_file: callback_generate_file, cb_done_with: callback_done_with) !u32 {
//     _ = try files_map.put(url, FileData{
//         .dynamic = true,
//         .data = .{
//             .dynamic_file_data = .{
//                 .uid = uid_counter,
//                 .callback = cb_generate_file,
//                 .callback_done_with = cb_done_with,
//             },
//         },
//     });
//     uid_counter += 1;
//     return uid_counter - 1;
// }

// Returns contents of static file at URL
pub fn getFile(url: []const u8, mime_type: *(?[]const u8)) ?[]const u8 {
    const kv = files_map.get(url);
    if (kv == null) {
        return null;
    }
    // if (kv.?.value.dynamic) {
    //     return kv.?.value.data.dynamic_file_data.callback(kv.?.value.data.dynamic_file_data.uid, url) catch {
    //         return "ERROR";
    //     };
    // } else {
    // Static file
    mime_type.* = kv.?.value.mime_type;
    return kv.?.value.data.static_data;
    // }
    // return null;
}

// pub fn writeDone(data: []const u8) void {
//     const callback = @intToPtr(callback_done_with);
//     callback(data);
// }
