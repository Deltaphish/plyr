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

// TODO: Compute N_SUBTABLE from tables (compute it twice?)
pub fn HuffmanDecoder(comptime T: type, comptime N_SUBTABLE: comptime_int) type {
    return struct {
        subtables: [N_SUBTABLE][SUBTABLE_SIZE]Entry(T),
        table_ix: [64]u32, // TODO: Compute table size based on table count.
        strategy: ?*const fn (table_id: u32, reader: *bit_reader.BitReader, val: T) T,

        pub fn init(tables: []const HuffmanTable(T)) @This() {
            var self = @This(){
                .subtables = [_][SUBTABLE_SIZE]Entry(T){[_]Entry(T){.none} ** SUBTABLE_SIZE} ** N_SUBTABLE,
                .table_ix = [_]u32{std.math.maxInt(u32)} ** 64,
                .strategy = null,
            };

            var alloc = SubTableAlloc(T).init(self.subtables[0..]);

            for (tables) |table| {
                self.table_ix[table.id] = populateSubtable(T, &alloc, table.rows);
            }
            return self;
        }

        pub fn init_with_strategy(strategy: *const fn (table_id: u32, reader: *bit_reader.BitReader, val: T) T, tables: []const HuffmanTable(T)) @This() {
            var self = @This().init(tables);
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
            const table = self.subtables[table_id];
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
        subtables: [][SUBTABLE_SIZE]Entry(T),
        subtable_it: u32,

        fn init(buffer: [][SUBTABLE_SIZE]Entry(T)) @This() {
            return @This(){ .subtables = buffer, .subtable_it = 0 };
        }

        fn alloc(self: *@This()) HuffmanError!u32 {
            const addr = self.subtable_it;
            self.subtable_it += 1;
            return addr;
        }

        fn get(self: @This(), ix: u32) []Entry(T) {
            std.debug.assert(ix < self.subtables.len);
            std.debug.assert(ix < self.subtable_it);
            return &self.subtables[ix];
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
        items: std.BoundedArray(HuffmanCode(T), INIT_BUFF_SIZE),
        subtable_addr: u32,

        pub fn init(subtable_addr: u32) @This() {
            return @This(){
                .items = std.BoundedArray(HuffmanCode(T), INIT_BUFF_SIZE).init(0) catch unreachable,
                .subtable_addr = subtable_addr,
            };
        }
    };
}

fn populateSubtable(comptime T: type, alloc: *SubTableAlloc(T), nodes: []const HuffmanCode(T)) u32 {
    // Recursive functions in zig is still a grey area, so instead of making innerPopulateSubtable recursive
    // we make the stack and memory allocations explicit.
    // This function is a wrapper of innerPopulateSubtable, taking care of bookkeeping (stack, allocs, etc)

    // TODO: Finetune magic number for stack
    const StackType = std.BoundedArray(Frame(T), INIT_BUFF_SIZE);

    var stack = StackType.init(0) catch unreachable;
    const inital_ba = std.BoundedArray(HuffmanCode(T), INIT_BUFF_SIZE).fromSlice(nodes) catch @panic("to many in table, need to increase alloc");

    const addr = alloc.alloc() catch @panic("Subtable allocation error");

    const inital_stack = Frame(T){ .items = inital_ba, .subtable_addr = addr };
    stack.append(inital_stack) catch @panic("Waka waka");

    while (stack.pop()) |frame| {
        innerPopulateSubtable(T, alloc, frame.subtable_addr, frame.items.buffer[0..frame.items.len], &stack);
    }
    return addr;
}

fn innerPopulateSubtable(comptime T: type, alloc: *SubTableAlloc(T), subtable_addr: u32, nodes: []const HuffmanCode(T), stack: *std.BoundedArray(Frame(T), INIT_BUFF_SIZE)) void {

    // We don't have allocators, so sketchy maps it is;
    var buckets = [_]?std.BoundedArray(HuffmanCode(T), INIT_BUFF_SIZE){null} ** 255;

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
                buckets[key] = std.BoundedArray(HuffmanCode(T), INIT_BUFF_SIZE).init(0) catch unreachable;
                subtable[key] = Entry(T){ .link = linked_subtable };
            }
            buckets[key].?.append(node) catch @panic("\nToo many children for one id, increase buckets child size\n");
        }
    }
    for (buckets, 0..) |maybeBucket, i| {
        if (maybeBucket) |bucket| {
            const link = subtable[i].link;
            var frame = Frame(T).init(link);
            for (bucket.buffer[0..bucket.len]) |code| {
                const c: HuffmanCode(T) = code;
                const val = c.val orelse @panic("AAAAAH");
                const old_code = c.code;

                const new_length = val.len - 8;
                const new_code = ((@as(u32, 1) << (new_length)) - 1) & old_code;

                const new_c = HuffmanCode(T).init(new_code, new_length, val.val);
                frame.items.append(new_c) catch @panic("Out of subtables");
            }
            stack.append(frame) catch @panic("Too many children for frame");
        }
    }
}
