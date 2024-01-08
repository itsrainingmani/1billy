const std = @import("std");
const builtin = @import("builtin");

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
// Useful when the function is small and called very often
// more changes to stay in the code cache
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
    // I guess this is why we dont do defer wg.deinit() in the main fn
    defer wg.finish();
    var ctx = WorkerCtx.init(std.heap.c_allocator) catch unreachable;
    defer ctx.deinit();

    std.log.debug("Running thread {}!", .{chunk_idx});

    var pos: usize = 0;

    // Either update an existing city entry in the HashMap or if it doesn't exist, add one
    while (pos < chunk.len) {
        // Chennai;12.5
        // Search for the position of ; which should be the city name
        const new_pos = std.mem.indexOfScalarPos(u8, chunk, pos, ';') orelse chunk.len;
        const city = chunk[pos..new_pos];
        pos = new_pos + 1;

        const num = parseSimpleFloat(chunk, &pos);
        const entry = ctx.map.getOrPut(city) catch unreachable;
        if (entry.found_existing) {
            entry.value_ptr.addItem(num);
        } else {
            entry.value_ptr.* = Stat{ .min = num, .max = num, .sum = num, .count = 1 };
        }
    }

    // Iterate over the HashMap
    var it = ctx.map.iterator();
    while (it.next()) |entry| {
        const country = entry.key_ptr.*;
        const stat = entry.value_ptr.*;
        main_mutex.lock();
        // Critical Code
        if (main_ctx.map.getPtr(country)) |main_stat| {
            main_stat.mergeIn(stat);
        } else {
            main_ctx.countries.append(country) catch unreachable;
            main_ctx.map.put(country, stat) catch unreachable;
        }

        main_mutex.unlock();
    }
    std.log.debug("Finished Thread {}!", .{chunk_idx});
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == std.math.Order.lt;
}

pub fn main() !void {
    std.debug.print("Commencing 1 Billy", .{});

    var args = try std.process.argsWithAllocator(std.heap.c_allocator);
    defer args.deinit();

    _ = args.skip();

    const file_name = args.next() orelse "measurements.txt";
    const file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
    defer file.close();

    // Either use the actual size of the file or do the max usize value possible
    const file_len: usize = std.math.cast(usize, try file.getEndPos()) orelse std.math.maxInt(usize);

    // Memory Map the whole measurements file
    // API of std.os.mmap ->
    // ptr: ?[*]align(mem.page_size) u8 - to memory block? or to the thing being mmaped
    // length of file/device to mmap (which is file_len). This does not need to be aligned
    // prot - ??? the semantics of how to handle the given file?
    //
    // MMapError has AccessDenied. One case is where PROT_WRITE is set but the file is append-only
    // This implies that PROT is the protocol for handling the file
    //
    //
    // flags - flags. Although what the heck is std.os.MAP.PRIVATE
    // fd - file descriptor or file handle
    // offset - memory offset? but to what
    const mapped_mem = try std.os.mmap(null, file_len, std.os.PROT.READ, std.os.MAP.PRIVATE, file.handle, 0);
    defer std.os.munmap(mapped_mem);

    if (builtin.os.tag == .linux) try std.os.madvise(mapped_mem.ptr, file_len, std.os.MADV.HUGEPAGE);

    var tp: std.Thread.Pool = undefined;
    try tp.init(.{ .allocator = std.heap.c_allocator });
    // Why are we not explicitly de-initializing the thread pool
    // defer tp.deinit();

    var wg = std.Thread.WaitGroup{};
    // Why are we not explicitly de-initializing the thread wait group
    // defer wg.deinit();

    var main_ctx = try WorkerCtx.init(std.heap.c_allocator);
    defer main_ctx.deinit();
    var main_mutex = std.Thread.Mutex{};

    var chunk_start: usize = 0;
    const job_count = try std.Thread.getCpuCount() - 1;
    for (0..job_count) |i| {

        // Subdividing the mapped memory into sections to search per thread
        const search_start = mapped_mem.len / job_count * (i + 1);
        const chunk_end = std.mem.indexOfScalarPos(u8, mapped_mem, search_start, '\n') orelse mapped_mem.len;
        const chunk: []const u8 = mapped_mem[chunk_start..chunk_end];
        chunk_start = chunk_end + 1;

        // what the hell is a wait group
        wg.start();
        try tp.spawn(threadRun, .{ chunk, i, &main_ctx, &main_mutex, &wg });
        if (chunk_start >= mapped_mem.len) break;
    }

    std.log.debug("Waiting and working", .{});
    tp.waitAndWork(&wg);
    std.log.debug("Finished waiting and working", .{});

    std.mem.sortUnstable([]const u8, main_ctx.countries.items, {}, strLessThan);
    std.debug.print("{{", .{});
    for (main_ctx.countries.items, 0..) |country, i| {
        const stat = main_ctx.map.get(country).?;
        const avg = stat.sum / @as(F, @floatFromInt(stat.count));
        std.debug.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ country, stat.min, avg, stat.max });
        if (i + 1 != main_ctx.countries.items.len) std.debug.print(", ", .{});
    }
    std.debug.print("}}\n", .{});
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
