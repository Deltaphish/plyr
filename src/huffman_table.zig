//! Decodes huffman encoded bitstreams through linked lookup tables
//! The lookup tables are all of the size 2 ** 8, so all bytes are indexes into a table.
//! The tables are populated as follows:
//!
//!     len(code) < TABLE_CUTOFF -> table[(code << len(padding)) | {0,1}^len(padding)] = val(code) ; where padding = TABLE_CUTOFF - len(code)
//!     len(code) = TABLE_CUTOFF -> table[code] = val(code)
//!     len(code) > TABLE_CUTOFF -> table[code[0..8]] = link to another table.
//!
//! This creates an 256-arry tree with depth ceil(max(len(code))/8).
//! To decode:
//!
//! 1. offset = read 8 bits (padd with 0 if necessary)
//! 2. if table[offset] == val
//!         return val,
//!    else
//!         table = *link
//!         goto 1.
//!
//! This means that codes <= TABLE_CUTOFF are faster to decode while larger codes require additional lookups.
//! Given a huffman encoded stream with a good compression ratio the distribution of encountered code lengths is biased torwards shorter codes,
//! thus average lookups should be correlated with compression ratio of the stream.

const std = @import("std");

const TABLE_CUTTOFF = 8;
const SUBTABLE_SIZE = (1 << (TABLE_CUTTOFF));
const INIT_BUFF_SIZE = 256;

pub fn HuffmanTable(comptime T: type) type {
    return struct {
        id: u32,
        rows: []const HuffmanCode(T),
    };
}

// TODO: Compute N_SUBTABLE from tables (compute it twice?)
pub fn HuffmanDecoder(comptime T: type, comptime N_SUBTABLE: comptime_int) type {
    return struct {
        subtables: [N_SUBTABLE][SUBTABLE_SIZE]Entry(T),
        table_ix: [64]u32, // TODO: Compute table size based on table count.

        pub fn init(tables: []const HuffmanTable(T)) @This() {
            var self = @This(){
                .subtables = [_][SUBTABLE_SIZE]Entry(T){[_]Entry(T){.none} ** SUBTABLE_SIZE} ** N_SUBTABLE,
                .table_ix = [_]u32{std.math.maxInt(u32)} ** 64,
            };
            var alloc = SubTableAlloc(T).init(self.subtables[0..]);

            for (tables) |table| {
                self.table_ix[table.id] = populateSubtable(T, &alloc, table.rows);
            }
            return self;
        }

        pub fn beginQuery(self: @This(), table_id: u32, byte: u8) Entry(T) {
            std.debug.assert(self.table_ix[table_id] != std.math.maxInt(u32));
            return self.query(self.table_ix[table_id], byte);
        }
        pub fn queryLink(self: @This(), link: Entry(T), byte: u8) Entry(T) {
            std.debug.assert(link == .link);
            return self.query(link.link, byte);
        }

        fn query(self: @This(), table_id: u32, byte: u8) Entry(T) {
            const table = self.subtables[table_id];
            switch (table[byte]) {
                .val, .link => return table[byte],
                .none => unreachable,
            }
        }
    };
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
            // Index is within bounds
            std.debug.assert(ix < self.subtables.len);
            // Index does not access unallocated slices
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

    while (stack.popOrNull()) |frame| {
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
