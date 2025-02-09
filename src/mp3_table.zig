const std = @import("std");

const TABLE_CUTTOFF = 8;
const SUBTABLE_SIZE = (1 << (TABLE_CUTTOFF + 1)) - 1;

const HuffmanTablesFoo = HuffmanTables.init();

const EntryType = enum {
    v_big,
    v_r4,
    link,
    none,
};

const Entry = union(EntryType) {
    v_big: HuffmanBigValue,
    v_r4: HuffmanR4Value,
    link: u16,
    none: void,
};

fn StackEntry(T: anytype) type {
    return struct {
        subtable_addr: u8,
        nodes: std.BoundedArray(T, 64),

        pub fn new() StackEntry(T) {
            return StackEntry(T){
                .subtable_addr = 255,
                .nodes = std.BoundedArray(T, 64).init(0) catch unreachable,
            };
        }
    };
}

const HuffmanTables = struct {
    // Backed by a n-ary tree, where n = SUBTABLE_SIZE.
    // All codes where len(code) > TABLE_CUTOFF will require a jump between subtables,
    // but given a suitably large TABLE_CUTOFF this will be infrequent due to the nature of Huffman tables.
    //
    // Should be initialized in comptime, no optimization efforts have been made for initialization.

    // TODO: Find exact value
    subtables: [200][SUBTABLE_SIZE]Entry = [_][SUBTABLE_SIZE]Entry{[_]Entry{.none} ** SUBTABLE_SIZE} ** 200,
    subtable_it: u8 = 15, // First 15 subtables are for the 15 top level tables, dear lord that's some tables...

    pub fn init() HuffmanTables {
        var self = HuffmanTables{};
        self.populateSubtable(HuffmanR4Node, 0, TABLE_A[0..]); // TODO: Use anytype
        self.populateSubtable(HuffmanR4Node, 1, TABLE_B[0..]);
        return self;
    }

    fn allocSubtable(self: *HuffmanTables) u8 {
        self.subtable_it += 1;
        return self.subtable_it;
    }

    fn populateSubtable(self: *HuffmanTables, comptime T: type, subtable_addr: u8, nodes: []const T) void {
        // Recursive functions in zig is still a grey area, so instead of making innerPopulateSubtable recursive
        // we make the stack and memory allocations explicit.
        // This function is a wrapper of innerPopulateSubtable, taking care of bookkeeping (stack, allocs, etc)

        // TODO: Finetune magic number for stack
        const StackType = std.BoundedArray(StackEntry(T), 64);
        var stack = StackType.init(0) catch unreachable;
        const inital_ba = std.BoundedArray(T, 64).fromSlice(nodes) catch @panic("to many in table, need to increase alloc");
        stack.append(StackEntry(T){ .subtable_addr = subtable_addr, .nodes = inital_ba }) catch @panic("Waka waka");

        while (stack.popOrNull()) |item| {
            var children_buffer = [_]StackEntry(T){StackEntry(T).new()} ** 64;
            const children = self.innerPopulateSubtable(T, item.subtable_addr, item.nodes.buffer[0..item.nodes.len], children_buffer[0..]);
            stack.appendSlice(children) catch @panic("Queue overflowed");
        }
    }

    fn innerPopulateSubtable(self: *HuffmanTables, comptime T: type, subtable_addr: u8, nodes: []const T, children_buffer: []StackEntry(T)) []StackEntry(T) {
        std.debug.assert(@hasField(T, "len"));

        // subtable_addr is valid
        std.debug.assert(subtable_addr < self.subtables.len);

        // We don't have allocators, so sketchy maps it is;
        var buckets = [_]?StackEntry(T){null} ** 255;

        for (nodes) |node| {
            const data = node.toData();
            if (TABLE_CUTTOFF == node.len) {
                self.subtables[subtable_addr][node.code] = data;
            } else if (TABLE_CUTTOFF > node.len) {
                const wildcard_width: u3 = @intCast(TABLE_CUTTOFF - node.len);
                for (0..((@as(u8, 1) << wildcard_width) - 1)) |wildcard| {
                    const key = (node.code << wildcard_width) | wildcard;
                    self.subtables[subtable_addr][key] = data;
                }
            } else {
                const delta: u3 = @intCast(node.len - TABLE_CUTTOFF);
                const key = node.code >> delta;
                if (buckets[key] == null) {
                    const linked_subtable = self.allocSubtable();
                    buckets[key] = StackEntry(T).new();
                    buckets[key].?.subtable_addr = linked_subtable;
                    self.subtables[subtable_addr][key] = Entry{ .link = linked_subtable };
                }
                buckets[key].?.nodes.append(node) catch @panic("\nToo many children for one id, increase buckets child size\n");
            }
        }
        var children_it: u32 = 0;
        for (buckets) |maybeBucket| {
            if (maybeBucket) |bucket| {
                children_buffer[children_it] = bucket;
                children_it += 1;
            }
        }
        if (children_it == 0) {
            return &.{};
        } else {
            return children_buffer[0..(children_it - 1)];
        }
    }
};

test "query Table A" {
    const table = HuffmanTables.init();
    try std.testing.expect(@as(EntryType, table.subtables[0][0]) == Entry.v_r4);
}

const HuffmanR4Value = struct {
    len: u4,
    v: u1,
    w: u1,
    x: u1,
    y: u1,

    fn default() HuffmanR4Value {
        return HuffmanR4Value{ .len = 0, .v = 0, .w = 0, .x = 0, .y = 0 };
    }
};

const HuffmanBigValue = struct {
    len: u4,
    x: u4,
    y: u4,

    fn default() HuffmanBigValue {
        return HuffmanBigValue{ .len = 0, .x = 0, .y = 0 };
    }
};

const HuffmanR4Node = packed struct {
    len: u4,
    code: u8,
    v: u1,
    w: u1,
    x: u1,
    y: u1,

    fn default() HuffmanR4Node {
        return HuffmanR4Node{
            .len = 10,
            .code = 255,
            .v = 1,
            .w = 1,
            .x = 1,
            .y = 1,
        };
    }

    fn toData(self: HuffmanR4Node) Entry {
        return Entry{
            .v_r4 = HuffmanR4Value{
                .len = self.len,
                .v = self.v,
                .w = self.w,
                .x = self.x,
                .y = self.y,
            },
        };
    }
};

const HuffmanBigNode = packed struct {
    len: u8,
    code: u8,
    x: u4,
    y: u4,

    fn default() HuffmanBigNode {
        return HuffmanBigNode{
            .len = 255,
            .code = 255,
            .x = 1,
            .y = 1,
        };
    }

    fn toData(self: HuffmanBigNode) Entry {
        return Entry{
            .v_big = HuffmanBigValue{
                .len = self.len,
                .x = self.x,
                .y = self.y,
            },
        };
    }
};

const TABLE_A = [_]HuffmanR4Node{
    HuffmanR4Node{ .len = 1, .code = 0b1, .v = 0, .w = 0, .x = 0, .y = 0 },
    HuffmanR4Node{ .len = 4, .code = 0b0101, .v = 0, .w = 0, .x = 0, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b0100, .v = 0, .w = 0, .x = 1, .y = 0 },
    HuffmanR4Node{ .len = 5, .code = 0b00101, .v = 0, .w = 0, .x = 1, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b0110, .v = 0, .w = 1, .x = 0, .y = 0 },
    HuffmanR4Node{ .len = 6, .code = 0b000101, .v = 0, .w = 1, .x = 0, .y = 1 },
    HuffmanR4Node{ .len = 5, .code = 0b00100, .v = 0, .w = 1, .x = 1, .y = 0 },
    HuffmanR4Node{ .len = 6, .code = 0b000100, .v = 0, .w = 1, .x = 1, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b0111, .v = 1, .w = 0, .x = 0, .y = 0 },
    HuffmanR4Node{ .len = 5, .code = 0b00011, .v = 1, .w = 0, .x = 0, .y = 1 },
    HuffmanR4Node{ .len = 5, .code = 0b00110, .v = 1, .w = 0, .x = 1, .y = 0 },
    HuffmanR4Node{ .len = 6, .code = 0b000000, .v = 1, .w = 0, .x = 1, .y = 1 },
    HuffmanR4Node{ .len = 5, .code = 0b00111, .v = 1, .w = 1, .x = 0, .y = 0 },
    HuffmanR4Node{ .len = 6, .code = 0b000010, .v = 1, .w = 1, .x = 0, .y = 1 },
    HuffmanR4Node{ .len = 6, .code = 0b000011, .v = 1, .w = 1, .x = 1, .y = 0 },
    HuffmanR4Node{ .len = 6, .code = 0b000001, .v = 1, .w = 1, .x = 1, .y = 1 },
};

const TABLE_B = [_]HuffmanR4Node{
    HuffmanR4Node{ .len = 4, .code = 0b1111, .v = 0, .w = 0, .x = 0, .y = 0 },
    HuffmanR4Node{ .len = 4, .code = 0b1110, .v = 0, .w = 0, .x = 0, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b1101, .v = 0, .w = 0, .x = 1, .y = 0 },
    HuffmanR4Node{ .len = 4, .code = 0b1100, .v = 0, .w = 0, .x = 1, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b1011, .v = 0, .w = 1, .x = 0, .y = 0 },
    HuffmanR4Node{ .len = 4, .code = 0b1010, .v = 0, .w = 1, .x = 0, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b1001, .v = 0, .w = 1, .x = 1, .y = 0 },
    HuffmanR4Node{ .len = 4, .code = 0b1000, .v = 0, .w = 1, .x = 1, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b0111, .v = 1, .w = 0, .x = 0, .y = 0 },
    HuffmanR4Node{ .len = 4, .code = 0b0110, .v = 1, .w = 0, .x = 0, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b0101, .v = 1, .w = 0, .x = 1, .y = 0 },
    HuffmanR4Node{ .len = 4, .code = 0b0100, .v = 1, .w = 0, .x = 1, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b0011, .v = 1, .w = 1, .x = 0, .y = 0 },
    HuffmanR4Node{ .len = 4, .code = 0b0010, .v = 1, .w = 1, .x = 0, .y = 1 },
    HuffmanR4Node{ .len = 4, .code = 0b0001, .v = 1, .w = 1, .x = 1, .y = 0 },
    HuffmanR4Node{ .len = 4, .code = 0b0000, .v = 1, .w = 1, .x = 1, .y = 1 },
};

const TABLE_1 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 1, .code = 0b1, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b001, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 2, .code = 0b01, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b000, .x = 1, .y = 1 },
};
const TABLE_2 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 1, .code = 0b1, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b010, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b000001, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 3, .code = 0b011, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b001, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 5, .code = 0b00001, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 5, .code = 0b00011, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 5, .code = 0b00010, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b000000, .x = 2, .y = 2 },
};
