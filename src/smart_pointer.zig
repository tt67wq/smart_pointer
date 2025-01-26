const std = @import("std");
const atomic = std.atomic;
const testing = std.testing;

// Stage 1: Define the foundational structure
const RefCounted = struct {
    allocator: std.mem.Allocator,
    counter: atomic.Value(usize),
    data: *anyopaque,
    destroy_fn: *const fn (std.mem.Allocator, *anyopaque) void,

    fn create(allocator: std.mem.Allocator, ptr: anytype, destroy: fn (std.mem.Allocator, @TypeOf(ptr)) void) !*RefCounted {
        const wrapper = try allocator.create(RefCounted);

        wrapper.* = .{
            .allocator = allocator,
            .counter = atomic.Value(usize).init(1),
            .data = ptr,
            .destroy_fn = @ptrCast(&destroy),
        };

        return wrapper;
    }

    fn retain(rc: *RefCounted) void {
        _ = rc.counter.fetchAdd(1, .monotonic);
    }

    fn release(rc: *RefCounted) void {
        const prev = rc.counter.fetchSub(1, .release);
        if (prev == 1) {
            rc.counter.fence(.acquire);
            rc.destroy_fn(rc.allocator, rc.data);
            rc.allocator.destroy(rc);
        }
    }
};

// stage 2: type-safe wrapper
pub fn SmartPointer(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        rc: *RefCounted,
        ptr: *T,

        const Self = @This();

        // 创建智能指针（类型安全版本）
        pub fn create(allocator: std.mem.Allocator, value: T) !Self {
            const ptr = try allocator.create(T);
            ptr.* = value;

            return .{
                .allocator = allocator,
                .rc = try RefCounted.create(allocator, ptr, destroyT),
                .ptr = ptr,
            };
        }

        // 类型特化的销毁函数
        fn destroyT(allocator: std.mem.Allocator, ptr: *T) void {
            mayDeinit(ptr);
            allocator.destroy(ptr);
        }

        fn mayDeinit(ptr: *T) void {
            const typeinfo = @typeInfo(T);
            if (typeinfo != .Struct) return;
            if (@hasDecl(T, "deinit")) {
                ptr.deinit();
            }
        }

        // 复制指针（增加引用计数）
        pub fn clone(self: Self) Self {
            self.rc.retain();
            return .{
                .allocator = self.allocator,
                .rc = self.rc,
                .ptr = self.ptr,
            };
        }

        // 释放资源
        pub fn release(self: *Self) void {
            self.rc.release();
            self.ptr = undefined;
        }
    };
}

// stage 3: type-safe access
pub fn get(comptime T: type, sp: anytype) *T {
    if (@TypeOf(sp.ptr) != *T) {
        @compileError("Type mismatch in smart pointer access");
    }
    return sp.ptr;
}

test "basic" {
    const MyType = struct { value: u32 };

    // 创建初始指针
    var sp = try SmartPointer(MyType).create(std.testing.allocator, .{ .value = 42 });
    // defer sp.release();

    try testing.expect(sp.ptr.value == 42);
    try testing.expect(sp.rc.counter.load(.monotonic) == 1);

    // 创建副本
    var sp2 = sp.clone();
    defer sp2.release();

    try testing.expect(sp.rc.counter.load(.monotonic) == 2);

    // 修改原始数据
    sp.ptr.value += 10;
    sp.release();
    try testing.expect(sp2.ptr.value == 52);
}

test "struct with deinit" {
    const MyType = struct {
        allocator: std.mem.Allocator,
        value: []u8,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, value: []const u8) !Self {
            return .{
                .allocator = allocator,
                .value = try allocator.dupe(u8, value),
            };
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.value);
        }
    };

    const m1 = try MyType.init(std.testing.allocator, "Hello");
    var sp = try SmartPointer(MyType).create(std.testing.allocator, m1);
    defer sp.release();
}

test "type safety" {
    const FloatPtr = SmartPointer(f32);
    var sp = try FloatPtr.create(std.testing.allocator, 3.14);
    defer sp.release();

    // correct access
    _ = get(f32, sp);

    // wrong access
    // _ = get(u32, sp);
}

test "concurrent access" {
    const Concurrency = 100;
    const TestData = struct { value: u32 };

    var sp = try SmartPointer(TestData).create(std.testing.allocator, .{ .value = 0 });
    defer sp.release();

    var threads: [Concurrency]std.Thread = undefined;

    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn func(s: *SmartPointer(TestData)) void {
                var local_copy = s.clone();
                defer local_copy.release();
            }
        }.func, .{&sp});
    }

    for (threads) |t| t.join();

    try testing.expect(sp.rc.counter.load(.monotonic) == 1);
}
