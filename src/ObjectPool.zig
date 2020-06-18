const std = @import("std");
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const c_allocator = std.heap.c_allocator;
const page_allocator = std.heap.page_allocator;
const Allocator = std.mem.Allocator;

// POSIX function
extern fn ffsll(c_longlong) c_int;

pub const OnAllocErrors = error{OnAllocError};
pub const CallbackErrors = error{GenericCallbackError};

pub fn ObjectPool(comptime T: type, comptime sub_pool_size: u32, comptime on_alloc: ?(fn ([]T) OnAllocErrors!void)) type {
    if (sub_pool_size % 64 != 0) {
        @compileError("sub_pool_size must be a multiple of 64");
    }

    return struct {
        const Self = @This();
        allocator_data: *Allocator,

        pub const Subpool = struct {
            bitmap: [sub_pool_size / 64]u64 = undefined, // call clear()
            elements: []T,

            pub fn init(elements: []T) Subpool {
                var x = Subpool{ .elements = elements };
                x.clear();
                return x;
            }

            pub fn isEmpty(self: Subpool) bool {
                for (self.bitmap) |b| {
                    if (b != 0) {
                        return false;
                    }
                }
                return true;
            }

            pub fn isFull(self: Subpool) bool {
                for (self.bitmap) |b| {
                    if (b != 0xffffffffffffffff) {
                        return false;
                    }
                }
                return true;
            }

            pub fn clear(self: *Subpool) void {
                std.mem.set(u8, std.mem.sliceAsBytes(self.bitmap[0..]), 0);
            }

            pub fn objectBelongs(self: Subpool, obj: *T) bool {
                const o_ptr = @ptrToInt(obj);
                const e0_ptr = @ptrToInt(&self.elements[0]);
                return o_ptr >= e0_ptr and o_ptr < e0_ptr + sub_pool_size * @sizeOf(T);
            }

            pub fn objectAtIndex(self: *Subpool, i: u32) bool {
                return self.bitmap[i / 64] & (@as(u64, 1) << @intCast(u6, i % 64)) != 0;
            }

            // Assumes that objectBelongs returned true for obj
            pub fn freeObject(self: *Subpool, obj: *T) void {
                const i = @intCast(u32, (@ptrToInt(obj) - @ptrToInt(&self.elements[0])) / @sizeOf(T));
                assert(i >= 0 and i < sub_pool_size);
                assert(self.objectAtIndex(i));
                self.bitmap[i / 64] &= ~(@as(u64, 1) << @intCast(u6, i % 64));
            }

            // Assumes isFull() returned false
            pub fn alloc(self: *Subpool) *T {
                var i: u32 = 0; // bit/element index
                for (self.bitmap) |*b| {
                    const first_bit_clear = @intCast(u32, ffsll(@bitCast(c_longlong, ~b.*)));
                    if (first_bit_clear > 0) {
                        b.* |= @as(u64, 1) << @intCast(u6, first_bit_clear - 1);
                        return &self.elements[i + first_bit_clear - 1];
                    }
                    i += 64;
                }
                unreachable;
            }
        };

        subpools: ArrayList(Subpool),

        pub fn init(allocator_list: *Allocator, allocator_data: *Allocator) Self {
            return .{ .allocator_data = allocator_data, .subpools = ArrayList(Subpool).init(allocator_list) };
        }

        // Deallocated all objects. All pointers become invalid.
        pub fn clear(self: *Self) void {
            for (self.subpools.items) |*p| {
                self.allocator_data.free(p.elements);
            }
            self.subpools.resize(0) catch unreachable;
        }

        pub fn deinit(self: *Self) void {
            self.clear();

            self.subpools.deinit();
        }

        pub fn addSubpool(self: *Self) !*Subpool {
            var subpool = Subpool.init(try self.allocator_data.alloc(T, sub_pool_size));
            errdefer self.allocator_data.free(subpool.elements);
            if (on_alloc != null) {
                try on_alloc.?(subpool.elements);
            }

            try self.subpools.append(subpool);
            return &self.subpools.items[self.subpools.items.len - 1];
        }

        // Find first subpool that has 1 or more available objects (if there is one)
        fn getSubPoolWithSpace(self: *Self) ?*Subpool {
            for (self.subpools.items) |*p| {
                if (!p.isFull()) {
                    return p;
                }
            }
            return null;
        }

        pub fn alloc(self: *Self) !*T {
            var subpool: *Subpool = self.getSubPoolWithSpace() orelse try self.addSubpool();
            return subpool.alloc();
        }

        // alloc but don't create new objects
        // If this function returns null then the next call to alloc() will allocate new objects
        pub fn allocNotNew(self: *Self) ?*T {
            // Find first subpool that has 1 or more available objects (if there is one)
            var subpool_with_space = self.getSubPoolWithSpace();

            if (subpool_with_space == null) {
                return null;
            }
            return subpool_with_space.?.alloc();
        }

        pub fn free(self: *Self, o: *T) void {
            for (self.subpools.items) |*p| {
                if (p.objectBelongs(o)) {
                    p.freeObject(o);
                }
            }
        }

        pub fn forEach(self: *Self, f: fn (*T) CallbackErrors!void) CallbackErrors!void {
            for (self.subpools.items) |*p| {
                var i: u32 = 0;
                while (i < sub_pool_size) : (i += 1) {
                    if (p.*.objectAtIndex(i)) {
                        try f(&p.*.elements[i]);
                    }
                }
            }
        }

        pub fn size(self: Self) usize {
            return self.subpools.items.len * sub_pool_size;
        }
    };
}

const TestStruct = struct {
    a: u32, b: u32, c: [32]u8
};

test "Object Subpools" {
    var pool = ObjectPool(TestStruct, 128, null).init(c_allocator, page_allocator);
    const test_struct_ptr_1 = try pool.alloc();
    test_struct_ptr_1.*.a = 1;
    const test_struct_ptr_2 = try pool.alloc();
    pool.free(test_struct_ptr_2);
    const test_struct_ptr_3 = try pool.alloc();
    std.testing.expect(test_struct_ptr_2 == test_struct_ptr_3);

    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        _ = try pool.alloc();
    }
    std.testing.expect(pool.size() == 256);

    pool.deinit();

    i = 0;
    while (i < 64) : (i += 1) {
        std.testing.expect(ffsll(@bitCast(c_longlong, @as(u64, 1) << @intCast(u6, i))) == i + 1);
    }
}
