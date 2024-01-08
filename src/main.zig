const std = @import("std");

// No Clue what this is for?
const MAP_CAPACITY = 512 * 2 * 2;

// Type names for better readability later???
const T = i32;
const F = f32;

// Station Struct
// We want the min, max and mean temp values per station
const Stat = struct {
    min: F,
    max: F,
    sum: F,
    count: u32,

    pub fn mergeIn(self: *Stat, other: Stat) void {
        self.min = @min(self.min, other.min);
        self.max = @max(self.max, other.max);
        self.sum += other.sum;
        self.count += 1;
    }

    pub fn addItem(self: *Stat, item: F) void {
        self.min = @min(self.min, item);
        self.max = @max(self.max, item);
        self.sum += item;
        self.count += 1;
    }
};

const WorkerCtx = struct {
    map: std.StringHashMap(Stat),
    countries: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !WorkerCtx {
        var self: WorkerCtx = undefined;
        self.map = std.StringHashMap(Stat).init(allocator);
        try self.map.ensureTotalCapacity(MAP_CAPACITY);
        self.countries = std.ArrayList([]const u8).init(allocator);
        return self;
    }

    pub fn deinit(self: *WorkerCtx) void {
        self.map.deinit();
        self.countries.deinit();
    }
};

// Inlining the function to avoid adding to the call stack?
inline fn parseSimpleFloat(chunk: []const u8, pos: *usize) F {
    var inum: i32 = 0;
    var is_neg = false;
    for (0..6) |i| {
        // pos.* derefences the pointer so it gives a usize
        // we incremenent that by i
        const idx = pos.* + i;
        const item = chunk[idx];
        switch (item) {
            '-' => is_neg = true,
            '0'...'9' => {
                inum *= 10;
                inum += item - '0';
            },
            '\n' => {
                pos.* = idx + 1;
                break;
            },
            else => {},
        }
    }
    inum *= if (is_neg) -1 else 1;
    const num: f32 = @as(f32, @floatFromInt(inum)) / 10;
    return num;
}

fn threadRun(chunk: []const u8, chunk_idx: usize, main_ctx: *WorkerCtx, main_mutex: *std.Thread.Mutex, wg: *std.Thread.WaitGroup) void {
    _ = wg;
    _ = main_mutex;
    _ = main_ctx;
    _ = chunk_idx;
    _ = chunk;
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == std.math.Order.lt;
}

pub fn main() !void {
    std.debug.print("Commencing 1 Billy");

    var args = try std.process.argsWithAllocator(std.heap.c_allocator);
    defer args.deinit();
}

test "parseSimpleFloat - pos 3 degs" {
    var pos: usize = 0;
    const str = "13.4\n";
    const num = parseSimpleFloat(str, &pos);
    try std.testing.expectEqual(@as(F, 13.4), num);
    try std.testing.expectEqual(str.len, pos);
}

test "parseSimpleFloat - neg 3 degs" {
    var pos: usize = 0;
    const str = "-91.5\n";
    const num = parseSimpleFloat(str, &pos);
    try std.testing.expectEqual(@as(F, -91.5), num);
    try std.testing.expectEqual(str.len, pos);
}

test "parseSimpleFloat - pos 2 degs" {
    var pos: usize = 0;
    const str = "3.4\n";
    const num = parseSimpleFloat(str, &pos);
    try std.testing.expectEqual(@as(F, 3.4), num);
    try std.testing.expectEqual(str.len, pos);
}

test "parseSimpleFloat - neg 2 degs" {
    var pos: usize = 0;
    const str = "-3.4\n";
    const num = parseSimpleFloat(str, &pos);
    try std.testing.expectEqual(@as(F, -3.4), num);
    try std.testing.expectEqual(str.len, pos);
}
