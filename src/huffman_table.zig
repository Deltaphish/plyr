const std = @import("std");
const bit_reader = @import("./bit_reader.zig");

const TABLE_CUTTOFF = 8;
const SUBTABLE_SIZE = (1 << (TABLE_CUTTOFF));
const INIT_BUFF_SIZE = 256;

pub fn HuffmanTable(comptime T: type) type {
    return struct {
        id: u32,
        rows: []const HuffmanCode(T),
        pub fn init(id: u32, rows: []const HuffmanCode(T)) @This() {
            return @This(){ .id = id, .rows = rows };
        }
    };
}

pub fn HuffmanDecoder(comptime T: type) type {
    return struct {
        subtables: std.ArrayList([SUBTABLE_SIZE]Entry(T)),
        table_ix: [64]u32, // TODO: Compute table size based on table count.
        strategy: ?*const fn (table_id: u32, reader: *bit_reader.BitReader, val: T) T,
        allocator: std.mem.Allocator,

        pub fn init(tables: []const HuffmanTable(T), allocator: std.mem.Allocator) @This() {

            //TODO: Finetune capacity
            var subtables = std.ArrayList([SUBTABLE_SIZE]Entry(T)).initCapacity(allocator, 40) catch @panic("OFM");

            var sub_alloc = SubTableAlloc(T).init(&subtables, allocator);

            var index: [64]u32 = [_]u32{0} ** 64;

            for (tables) |table| {
                index[table.id] = populateSubtable(T, &sub_alloc, table.rows);
            }

            return @This(){
                .subtables = subtables,
                .table_ix = index,
                .strategy = null,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: @This()) void {
            self.subtables.deinit(self.allocator);
        }

        pub fn init_with_strategy(allocator: std.mem.Allocator, strategy: *const fn (table_id: u32, reader: *bit_reader.BitReader, val: T) T, tables: []const HuffmanTable(T)) @This() {
            var self = @This().init(tables, allocator);
            self.strategy = strategy;
            return self;
        }

        pub fn alias_table(self: *@This(), from: u32, to: u32) void {
            // No unintialized tables
            std.debug.assert(self.table_ix[to] != std.math.maxInt(u32));
            self.table_ix[from] = self.table_ix[to];
        }

        fn beginQuery(self: @This(), table_id: u32, byte: u8) Entry(T) {
            // No unintialized tables
            std.debug.assert(self.table_ix[table_id] != std.math.maxInt(u32));
            return self.query(self.table_ix[table_id], byte);
        }
        fn queryLink(self: @This(), link: Entry(T), byte: u8) Entry(T) {
            std.debug.assert(link == .link);
            return self.query(link.link, byte);
        }

        fn query(self: @This(), table_id: u32, byte: u8) Entry(T) {
            const table = self.subtables.items[table_id];
            return table[byte];
        }

        pub fn decode(self: @This(), table_id: u32, reader: *bit_reader.BitReader, dest: []T) u32 {
            var dest_it: u32 = 0;

            // Hard code Table 0
            if (table_id == 0) {
                return 0;
            }

            if (dest.len == 0) {
                //Nothing to do here...
                return 0;
            }

            while (reader.readByte()) |byte| {
                const start = reader.bit_cursor;
                var entry: Entry(T) = self.beginQuery(table_id, byte);
                var actual_length: u5 = 0;
                while (entry == .link) {
                    actual_length += 8;
                    if (!reader.walkForward(8)) {
                        return dest_it;
                    }
                    const b = reader.readByte() orelse return dest_it;
                    entry = self.queryLink(entry, b);
                }
                std.debug.assert(entry == .val);

                var val = entry.val;

                if (!reader.walkForward(val.len)) {
                    return dest_it;
                }

                val.len += actual_length;

                if (reader.bit_cursor != start + val.len) {
                    std.debug.print("{} {} {}\n", .{ reader.bit_cursor, start, val.len });
                }
                std.debug.assert(reader.bit_cursor == start + val.len);

                if (self.strategy != null) {
                    dest[dest_it] = self.strategy.?(table_id, reader, val.val);
                } else {
                    dest[dest_it] = val.val;
                }

                dest_it += 1;
                if (dest_it >= dest.len) {
                    return dest_it;
                }
            }

            return dest_it;
        }
    };
}

test "Decode u32s" {
    const IntCode = HuffmanCode(u32);
    const rows = [_]IntCode{
        IntCode.init(0b1, 1, 1),
        IntCode.init(0b001, 3, 2),
        IntCode.init(0b01, 2, 3),
        IntCode.init(0b000000000, 9, 4),
    };

    const table = HuffmanTable(u32).init(0, rows[0..]);
    var decoder = HuffmanDecoder(u32, 200).init(&[_]HuffmanTable(u32){table});

    const plaintext = [_]u32{ 1, 2, 3, 3, 2, 1, 4 };
    const bitstream = [_]u8{ 0b10010101, 0b00110000, 0b00000000 };
    var dest = [_]u32{0} ** 7;

    var reader = bit_reader.BitReader.init(bitstream[0..]);
    try std.testing.expectEqual(7, decoder.decode(0, &reader, dest[0..]));
    try std.testing.expectEqualSlices(u32, plaintext[0..], dest[0..]);
}

fn dummy_strat(_: u32, reader: *bit_reader.BitReader, val: u32) u32 {
    if (val == 4) {
        const extra = reader.readBits(2) orelse @panic("WWWW");
        defer _ = reader.walkForward(2);
        return val + extra;
    }
    return val;
}

test "Decode u32s with strategy" {
    const IntCode = HuffmanCode(u32);
    const rows = [_]IntCode{
        IntCode.init(0b1, 1, 1),
        IntCode.init(0b001, 3, 2),
        IntCode.init(0b01, 2, 3),
        IntCode.init(0b000, 3, 4),
    };

    const table = HuffmanTable(u32).init(0, rows[0..]);

    const plaintext = [_]u32{ 1, 2, 3, 3, 2, 1, 7 };
    const bitstream = [_]u8{ 0b10010101, 0b00110001, 0b10000000 };

    var decoder = HuffmanDecoder(u32, 200).init_with_strategy(dummy_strat, &[_]HuffmanTable(u32){table});
    var dest = [_]u32{0} ** 7;
    var reader = bit_reader.BitReader.init(bitstream[0..]);
    try std.testing.expectEqual(7, decoder.decode(0, &reader, dest[0..]));
    try std.testing.expectEqualSlices(u32, plaintext[0..], dest[0..]);
}

const HuffmanError = error{
    OutOfSubTables,
};

pub fn HuffmanCode(comptime value: anytype) type {
    return struct {
        code: u32,
        val: ?HuffmanValue(value),

        pub fn init(code: u32, len: u5, val: value) @This() {
            return @This(){
                .code = code,
                .val = HuffmanValue(value){ .len = len, .val = val },
            };
        }

        pub fn default() @This() {
            return @This(){
                .code = 0,
                .val = null,
            };
        }

        pub fn getValue(self: @This()) ?HuffmanValue(value) {
            return self.val;
        }
    };
}

pub fn HuffmanValue(comptime value: anytype) type {
    return struct {
        len: u5,
        val: value,
    };
}

fn Entry(comptime V: anytype) type {
    return union(enum) {
        val: HuffmanValue(V),
        link: u32,
        none: void,
    };
}

fn SubTableAlloc(T: anytype) type {
    return struct {
        subtables: *std.ArrayList([SUBTABLE_SIZE]Entry(T)),
        allocator: std.mem.Allocator,

        fn init(subtables: *std.ArrayList([SUBTABLE_SIZE]Entry(T)), allocator: std.mem.Allocator) @This() {
            //TODO: Calibrate capacity size
            return @This(){ .subtables = subtables, .allocator = allocator };
        }

        fn alloc(self: *@This()) HuffmanError!u32 {
            const addr: u32 = @intCast(self.subtables.items.len);
            const next: *[SUBTABLE_SIZE]Entry(T) = self.subtables.addOne(self.allocator) catch @panic("OFM");
            next.* = @splat(Entry(T).none);
            return addr;
        }

        fn get(self: @This(), ix: u32) []Entry(T) {
            std.debug.assert(ix < self.subtables.items.len);
            return &self.subtables.items[ix];
        }
    };
}

test "SubTableAlloc sanity test" {
    var buffer = [_][SUBTABLE_SIZE]Entry(u8){[_]Entry(u8){.none} ** SUBTABLE_SIZE} ** 10;
    var alloc = SubTableAlloc(u8).init(&buffer);

    const table_1 = try alloc.alloc();
    const table_2 = try alloc.alloc();
    try std.testing.expect(table_1 != table_2);

    var t1 = alloc.get(table_1);
    t1[0] = Entry(u8){ .val = HuffmanValue(u8){ .val = 255, .len = 1 } };

    const t2 = alloc.get(table_2);
    try std.testing.expectEqual(t2[0], .none);
}

fn Frame(comptime T: anytype) type {
    return struct {
        items_buffer: [INIT_BUFF_SIZE]HuffmanCode(T),
        items: std.ArrayList(HuffmanCode(T)),
        subtable_addr: u32,

        pub fn init(subtable_addr: u32) @This() {
            var f = @This(){
                .items_buffer = undefined,
                .items = undefined,
                .subtable_addr = subtable_addr,
            };
            f.items = std.ArrayList(HuffmanCode(T)).initBuffer(&f.items_buffer);
            return f;
        }
    };
}

fn populateSubtable(comptime T: type, alloc: *SubTableAlloc(T), nodes: []const HuffmanCode(T)) u32 {
    // Recursive functions in zig is still a grey area, so instead of making innerPopulateSubtable recursive
    // we make the stack and memory allocations explicit.
    // This function is a wrapper of innerPopulateSubtable, taking care of bookkeeping (stack, allocs, etc)

    // TODO: Finetune magic number for stack

    var stack_buffer: [INIT_BUFF_SIZE]Frame(T) = undefined;
    var stack = std.ArrayList(Frame(T)).initBuffer(&stack_buffer);

    var ba_buffer: [INIT_BUFF_SIZE]HuffmanCode(T) = undefined;

    var inital_ba = std.ArrayList(HuffmanCode(T)).initBuffer(&ba_buffer);
    inital_ba.appendSliceAssumeCapacity(nodes);

    const addr = alloc.alloc() catch @panic("Subtable allocation error");

    var initial_stack = Frame(T).init(addr);
    initial_stack.items.appendSliceAssumeCapacity(nodes);
    stack.appendAssumeCapacity(initial_stack);

    while (stack.pop()) |frame| {
        innerPopulateSubtable(T, alloc, frame.subtable_addr, frame.items.items[0..], &stack);
    }
    return addr;
}

fn innerPopulateSubtable(comptime T: type, alloc: *SubTableAlloc(T), subtable_addr: u32, nodes: []const HuffmanCode(T), stack: *std.ArrayList(Frame(T))) void {
    var buffer: [1000]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var buckets = [_]?std.ArrayList(HuffmanCode(T)){null} ** 255;

    var subtable = alloc.get(subtable_addr);

    for (nodes) |node| {
        const data = node.getValue() orelse @panic("Trying to use a huffmancode with an uninitalized");
        if (TABLE_CUTTOFF == data.len) {
            subtable[node.code] = Entry(T){ .val = data };
        } else if (TABLE_CUTTOFF > data.len) {
            const wildcard_width: u3 = @intCast(TABLE_CUTTOFF - data.len);
            for (0..(@as(u8, 1) << wildcard_width)) |wildcard| {
                const key = (node.code << wildcard_width) | wildcard;
                subtable[key] = Entry(T){ .val = data };
            }
        } else {
            const delta: u5 = @intCast(data.len - TABLE_CUTTOFF);
            const key = node.code >> delta;
            if (buckets[key] == null) {
                const linked_subtable = alloc.alloc() catch @panic("Out of subtables");
                buckets[key] = std.ArrayList(HuffmanCode(T)).initCapacity(fba.allocator(), 4) catch unreachable;
                subtable[key] = Entry(T){ .link = linked_subtable };
            }
            buckets[key].?.append(fba.allocator(), node) catch @panic("\nToo many children for one id, increase buckets child size\n");
        }
    }
    for (buckets, 0..) |maybeBucket, i| {
        if (maybeBucket) |bucket| {
            const link = subtable[i].link;
            var frame = Frame(T).init(link);
            for (bucket.items) |code| {
                const c: HuffmanCode(T) = code;
                const val = c.val orelse @panic("AAAAAH");
                const old_code = c.code;

                const new_length = val.len - 8;
                const new_code = ((@as(u32, 1) << (new_length)) - 1) & old_code;

                const new_c = HuffmanCode(T).init(new_code, new_length, val.val);
                frame.items.appendBounded(new_c) catch @panic("Out of subtables");
            }
            stack.appendBounded(frame) catch @panic("Too many children for frame");
        }
    }
}
