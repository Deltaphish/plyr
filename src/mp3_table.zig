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
const TABLE_3 = [_]HuffmanBigNode{
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

const TABLE_5 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 1, .code = 0b1, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b010, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b000110, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0000101, .x = 0, .y = 3 },
    HuffmanBigNode{ .len = 3, .code = 0b011, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b001, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b000100, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0000100, .x = 1, .y = 3 },
    HuffmanBigNode{ .len = 6, .code = 0b000111, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 6, .code = 0b000101, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0000111, .x = 2, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00000001, .x = 2, .y = 3 },
    HuffmanBigNode{ .len = 7, .code = 0b0000110, .x = 3, .y = 0 },
    HuffmanBigNode{ .len = 6, .code = 0b000001, .x = 3, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0000001, .x = 3, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00000000, .x = 3, .y = 3 },
};

const TABLE_6 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 3, .code = 0b111, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b011, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 5, .code = 0b00101, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0000001, .x = 0, .y = 3 },
    HuffmanBigNode{ .len = 3, .code = 0b110, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 2, .code = 0b10, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 4, .code = 0b0011, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 5, .code = 0b00010, .x = 1, .y = 3 },
    HuffmanBigNode{ .len = 4, .code = 0b0101, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 4, .code = 0b0100, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 5, .code = 0b00100, .x = 2, .y = 2 },
    HuffmanBigNode{ .len = 6, .code = 0b000001, .x = 2, .y = 3 },
    HuffmanBigNode{ .len = 6, .code = 0b000011, .x = 3, .y = 0 },
    HuffmanBigNode{ .len = 5, .code = 0b00011, .x = 3, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b000010, .x = 3, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0000000, .x = 3, .y = 3 },
};

const TABLE_7 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 1, .code = 0b1, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b010, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b001010, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00010011, .x = 0, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00010000, .x = 0, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000001010, .x = 0, .y = 5 },
    HuffmanBigNode{ .len = 3, .code = 0b011, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 4, .code = 0b0011, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b000111, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0001010, .x = 1, .y = 3 },
    HuffmanBigNode{ .len = 7, .code = 0b0000101, .x = 1, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00000011, .x = 1, .y = 5 },
    HuffmanBigNode{ .len = 6, .code = 0b001011, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 5, .code = 0b00100, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0001101, .x = 2, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00010001, .x = 2, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00001000, .x = 2, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000000100, .x = 2, .y = 5 },
    HuffmanBigNode{ .len = 7, .code = 0b0001100, .x = 3, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0001011, .x = 3, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00010010, .x = 3, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000001111, .x = 3, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000001011, .x = 3, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000000010, .x = 3, .y = 5 },
    HuffmanBigNode{ .len = 7, .code = 0b0000111, .x = 4, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0000110, .x = 4, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00001001, .x = 4, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000001110, .x = 4, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000000011, .x = 4, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000001, .x = 4, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00000110, .x = 5, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00000100, .x = 5, .y = 1 },
    HuffmanBigNode{ .len = 9, .code = 0b000000101, .x = 5, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000011, .x = 5, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000010, .x = 5, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000000, .x = 5, .y = 5 },
};

const TABLE_8 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 2, .code = 0b11, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b100, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b000110, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00010010, .x = 0, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00001100, .x = 0, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000000101, .x = 0, .y = 5 },
    HuffmanBigNode{ .len = 3, .code = 0b101, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 2, .code = 0b01, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 4, .code = 0b0010, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00010000, .x = 1, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00001001, .x = 1, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00000011, .x = 1, .y = 5 },
    HuffmanBigNode{ .len = 6, .code = 0b000111, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 4, .code = 0b0011, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b000101, .x = 2, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00001110, .x = 2, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00000111, .x = 2, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000000011, .x = 2, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00010011, .x = 3, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00010001, .x = 3, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00001111, .x = 3, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000001101, .x = 3, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000001010, .x = 3, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000100, .x = 3, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00001101, .x = 4, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0000101, .x = 4, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00001000, .x = 4, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000001011, .x = 4, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000101, .x = 4, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000001, .x = 4, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000001100, .x = 5, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00000100, .x = 5, .y = 1 },
    HuffmanBigNode{ .len = 9, .code = 0b000000100, .x = 5, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000000001, .x = 5, .y = 3 },
    HuffmanBigNode{ .len = 11, .code = 0b00000000001, .x = 5, .y = 4 },
    HuffmanBigNode{ .len = 11, .code = 0b00000000000, .x = 5, .y = 5 },
};

const TABLE_9 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 3, .code = 0b111, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b101, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 5, .code = 0b01001, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 6, .code = 0b001110, .x = 0, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00001111, .x = 0, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000000111, .x = 0, .y = 5 },
    HuffmanBigNode{ .len = 3, .code = 0b110, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b100, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 4, .code = 0b0101, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 5, .code = 0b00101, .x = 1, .y = 3 },
    HuffmanBigNode{ .len = 6, .code = 0b000110, .x = 1, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00000111, .x = 1, .y = 5 },
    HuffmanBigNode{ .len = 4, .code = 0b0111, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 4, .code = 0b0110, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 5, .code = 0b01000, .x = 2, .y = 2 },
    HuffmanBigNode{ .len = 6, .code = 0b001000, .x = 2, .y = 3 },
    HuffmanBigNode{ .len = 7, .code = 0b0001000, .x = 2, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00000101, .x = 2, .y = 5 },
    HuffmanBigNode{ .len = 6, .code = 0b001111, .x = 3, .y = 0 },
    HuffmanBigNode{ .len = 5, .code = 0b00110, .x = 3, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b001001, .x = 3, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0001010, .x = 3, .y = 3 },
    HuffmanBigNode{ .len = 7, .code = 0b0000101, .x = 3, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00000001, .x = 3, .y = 5 },
    HuffmanBigNode{ .len = 7, .code = 0b0001011, .x = 4, .y = 0 },
    HuffmanBigNode{ .len = 6, .code = 0b000111, .x = 4, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0001001, .x = 4, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0000110, .x = 4, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00000100, .x = 4, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000000001, .x = 4, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00001110, .x = 5, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0000100, .x = 5, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00000110, .x = 5, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00000010, .x = 5, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000000110, .x = 5, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000000000, .x = 5, .y = 5 },
};

const TABLE_10 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 1, .code = 0b1, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b010, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b001010, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00010111, .x = 0, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000100011, .x = 0, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000011110, .x = 0, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000001100, .x = 0, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0000010001, .x = 0, .y = 7 },
    HuffmanBigNode{ .len = 3, .code = 0b011, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 4, .code = 0b0011, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b001000, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0001100, .x = 1, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00010010, .x = 1, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000010101, .x = 1, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00001100, .x = 1, .y = 6 },
    HuffmanBigNode{ .len = 8, .code = 0b00000111, .x = 1, .y = 7 },
    HuffmanBigNode{ .len = 6, .code = 0b001011, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 6, .code = 0b001001, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0001111, .x = 2, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00010101, .x = 2, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000100000, .x = 2, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000101000, .x = 2, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000010011, .x = 2, .y = 6 },
    HuffmanBigNode{ .len = 9, .code = 0b000000110, .x = 2, .y = 7 },
    HuffmanBigNode{ .len = 7, .code = 0b0001110, .x = 3, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0001101, .x = 3, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00010110, .x = 3, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000100010, .x = 3, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0000101110, .x = 3, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000010111, .x = 3, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000010010, .x = 3, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000111, .x = 3, .y = 7 },
    HuffmanBigNode{ .len = 8, .code = 0b00010100, .x = 4, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00010011, .x = 4, .y = 1 },
    HuffmanBigNode{ .len = 9, .code = 0b000100001, .x = 4, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0000101111, .x = 4, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0000011011, .x = 4, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000010110, .x = 4, .y = 5 },
    HuffmanBigNode{ .len = 10, .code = 0b0000001001, .x = 4, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000011, .x = 4, .y = 7 },
    HuffmanBigNode{ .len = 9, .code = 0b000011111, .x = 5, .y = 0 },
    HuffmanBigNode{ .len = 9, .code = 0b000010110, .x = 5, .y = 1 },
    HuffmanBigNode{ .len = 10, .code = 0b0000101001, .x = 5, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0000011010, .x = 5, .y = 3 },
    HuffmanBigNode{ .len = 11, .code = 0b00000010101, .x = 5, .y = 4 },
    HuffmanBigNode{ .len = 11, .code = 0b00000010100, .x = 5, .y = 5 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000101, .x = 5, .y = 6 },
    HuffmanBigNode{ .len = 11, .code = 0b00000000011, .x = 5, .y = 7 },
    HuffmanBigNode{ .len = 8, .code = 0b00001110, .x = 6, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00001101, .x = 6, .y = 1 },
    HuffmanBigNode{ .len = 9, .code = 0b000001010, .x = 6, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0000001011, .x = 6, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0000010000, .x = 6, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000110, .x = 6, .y = 5 },
    HuffmanBigNode{ .len = 11, .code = 0b00000000101, .x = 6, .y = 6 },
    HuffmanBigNode{ .len = 11, .code = 0b00000000001, .x = 6, .y = 7 },
    HuffmanBigNode{ .len = 9, .code = 0b000001001, .x = 7, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00001000, .x = 7, .y = 1 },
    HuffmanBigNode{ .len = 9, .code = 0b000000111, .x = 7, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0000001000, .x = 7, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000100, .x = 7, .y = 4 },
    HuffmanBigNode{ .len = 11, .code = 0b00000000100, .x = 7, .y = 5 },
    HuffmanBigNode{ .len = 11, .code = 0b00000000010, .x = 7, .y = 6 },
    HuffmanBigNode{ .len = 11, .code = 0b00000000000, .x = 7, .y = 7 },
};

const TABLE_11 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 2, .code = 0b11, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b100, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 5, .code = 0b01010, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0011000, .x = 0, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00100010, .x = 0, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000100001, .x = 0, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00010101, .x = 0, .y = 6 },
    HuffmanBigNode{ .len = 9, .code = 0b000001111, .x = 0, .y = 7 },
    HuffmanBigNode{ .len = 3, .code = 0b101, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b011, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 4, .code = 0b0100, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 6, .code = 0b001010, .x = 1, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00100000, .x = 1, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00010001, .x = 1, .y = 5 },
    HuffmanBigNode{ .len = 7, .code = 0b0001011, .x = 1, .y = 6 },
    HuffmanBigNode{ .len = 8, .code = 0b00001010, .x = 1, .y = 7 },
    HuffmanBigNode{ .len = 5, .code = 0b01011, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 5, .code = 0b00111, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b001101, .x = 2, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0010010, .x = 2, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00011110, .x = 2, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000011111, .x = 2, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00010100, .x = 2, .y = 6 },
    HuffmanBigNode{ .len = 8, .code = 0b00000101, .x = 2, .y = 7 },
    HuffmanBigNode{ .len = 7, .code = 0b0011001, .x = 3, .y = 0 },
    HuffmanBigNode{ .len = 6, .code = 0b001011, .x = 3, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0010011, .x = 3, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000111011, .x = 3, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00011011, .x = 3, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000010010, .x = 3, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00001100, .x = 3, .y = 6 },
    HuffmanBigNode{ .len = 9, .code = 0b000000101, .x = 3, .y = 7 },
    HuffmanBigNode{ .len = 8, .code = 0b00100011, .x = 4, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00100001, .x = 4, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00011111, .x = 4, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000111010, .x = 4, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000011110, .x = 4, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000010000, .x = 4, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000000111, .x = 4, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000101, .x = 4, .y = 7 },
    HuffmanBigNode{ .len = 8, .code = 0b00011100, .x = 5, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00011010, .x = 5, .y = 1 },
    HuffmanBigNode{ .len = 9, .code = 0b000100000, .x = 5, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0000010011, .x = 5, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0000010001, .x = 5, .y = 4 },
    HuffmanBigNode{ .len = 11, .code = 0b00000001111, .x = 5, .y = 5 },
    HuffmanBigNode{ .len = 10, .code = 0b0000001000, .x = 5, .y = 6 },
    HuffmanBigNode{ .len = 11, .code = 0b00000001110, .x = 5, .y = 7 },
    HuffmanBigNode{ .len = 8, .code = 0b00001110, .x = 6, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0001100, .x = 6, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0001001, .x = 6, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00001101, .x = 6, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000001110, .x = 6, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000001001, .x = 6, .y = 5 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000100, .x = 6, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000001, .x = 6, .y = 7 },
    HuffmanBigNode{ .len = 8, .code = 0b00001011, .x = 7, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0000100, .x = 7, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00000110, .x = 7, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000000110, .x = 7, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000110, .x = 7, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000011, .x = 7, .y = 5 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000010, .x = 7, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000000, .x = 7, .y = 7 },
};

const TABLE_12 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 4, .code = 0b1001, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b110, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 5, .code = 0b10000, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0100001, .x = 0, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00101001, .x = 0, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000100111, .x = 0, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000100110, .x = 0, .y = 6 },
    HuffmanBigNode{ .len = 9, .code = 0b000011010, .x = 0, .y = 7 },
    HuffmanBigNode{ .len = 3, .code = 0b111, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 3, .code = 0b101, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 4, .code = 0b0110, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 5, .code = 0b01001, .x = 1, .y = 3 },
    HuffmanBigNode{ .len = 7, .code = 0b0010111, .x = 1, .y = 4 },
    HuffmanBigNode{ .len = 7, .code = 0b0010000, .x = 1, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00011010, .x = 1, .y = 6 },
    HuffmanBigNode{ .len = 8, .code = 0b00001011, .x = 1, .y = 7 },
    HuffmanBigNode{ .len = 5, .code = 0b10001, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 4, .code = 0b0111, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 5, .code = 0b01011, .x = 2, .y = 2 },
    HuffmanBigNode{ .len = 6, .code = 0b001110, .x = 2, .y = 3 },
    HuffmanBigNode{ .len = 7, .code = 0b0010101, .x = 2, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00011110, .x = 2, .y = 5 },
    HuffmanBigNode{ .len = 7, .code = 0b0001010, .x = 2, .y = 6 },
    HuffmanBigNode{ .len = 8, .code = 0b00000111, .x = 2, .y = 7 },
    HuffmanBigNode{ .len = 6, .code = 0b010001, .x = 3, .y = 0 },
    HuffmanBigNode{ .len = 5, .code = 0b01010, .x = 3, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b001111, .x = 3, .y = 2 },
    HuffmanBigNode{ .len = 6, .code = 0b001100, .x = 3, .y = 3 },
    HuffmanBigNode{ .len = 7, .code = 0b0010010, .x = 3, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00011100, .x = 3, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00001110, .x = 3, .y = 6 },
    HuffmanBigNode{ .len = 8, .code = 0b00000101, .x = 3, .y = 7 },
    HuffmanBigNode{ .len = 7, .code = 0b0100000, .x = 4, .y = 0 },
    HuffmanBigNode{ .len = 6, .code = 0b001101, .x = 4, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0010110, .x = 4, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0010011, .x = 4, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00010010, .x = 4, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00010000, .x = 4, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00001001, .x = 4, .y = 6 },
    HuffmanBigNode{ .len = 9, .code = 0b000000101, .x = 4, .y = 7 },
    HuffmanBigNode{ .len = 8, .code = 0b00101000, .x = 5, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0010001, .x = 5, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00011111, .x = 5, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00011101, .x = 5, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00010001, .x = 5, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000001101, .x = 5, .y = 5 },
    HuffmanBigNode{ .len = 8, .code = 0b00000100, .x = 5, .y = 6 },
    HuffmanBigNode{ .len = 9, .code = 0b000000010, .x = 5, .y = 7 },
    HuffmanBigNode{ .len = 8, .code = 0b00011011, .x = 6, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0001100, .x = 6, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0001011, .x = 6, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00001111, .x = 6, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00001010, .x = 6, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000000111, .x = 6, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000000100, .x = 6, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000001, .x = 6, .y = 7 },
    HuffmanBigNode{ .len = 9, .code = 0b000011011, .x = 7, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00001100, .x = 7, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00001000, .x = 7, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000001100, .x = 7, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000000110, .x = 7, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000000011, .x = 7, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000000001, .x = 7, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0000000000, .x = 7, .y = 7 },
};

const TABLE_13 = [_]HuffmanBigNode{
    HuffmanBigNode{ .len = 1, .code = 0b1, .x = 0, .y = 0 },
    HuffmanBigNode{ .len = 4, .code = 0b0101, .x = 0, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b001110, .x = 0, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0010101, .x = 0, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00100010, .x = 0, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000110011, .x = 0, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000101110, .x = 0, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0001000111, .x = 0, .y = 7 },
    HuffmanBigNode{ .len = 9, .code = 0b000101010, .x = 0, .y = 8 },
    HuffmanBigNode{ .len = 10, .code = 0b0000110100, .x = 0, .y = 9 },
    HuffmanBigNode{ .len = 11, .code = 0b00001000100, .x = 0, .y = 10 },
    HuffmanBigNode{ .len = 11, .code = 0b00000110100, .x = 0, .y = 11 },
    HuffmanBigNode{ .len = 12, .code = 0b000001000011, .x = 0, .y = 12 },
    HuffmanBigNode{ .len = 12, .code = 0b000000101100, .x = 0, .y = 13 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000101011, .x = 0, .y = 14 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000010011, .x = 0, .y = 15 },
    HuffmanBigNode{ .len = 3, .code = 0b011, .x = 1, .y = 0 },
    HuffmanBigNode{ .len = 4, .code = 0b0100, .x = 1, .y = 1 },
    HuffmanBigNode{ .len = 6, .code = 0b001100, .x = 1, .y = 2 },
    HuffmanBigNode{ .len = 7, .code = 0b0010011, .x = 1, .y = 3 },
    HuffmanBigNode{ .len = 8, .code = 0b00011111, .x = 1, .y = 4 },
    HuffmanBigNode{ .len = 8, .code = 0b00011010, .x = 1, .y = 5 },
    HuffmanBigNode{ .len = 9, .code = 0b000101100, .x = 1, .y = 6 },
    HuffmanBigNode{ .len = 9, .code = 0b000100001, .x = 1, .y = 7 },
    HuffmanBigNode{ .len = 9, .code = 0b000011111, .x = 1, .y = 8 },
    HuffmanBigNode{ .len = 9, .code = 0b000011000, .x = 1, .y = 9 },
    HuffmanBigNode{ .len = 10, .code = 0b0000100000, .x = 1, .y = 10 },
    HuffmanBigNode{ .len = 10, .code = 0b0000011000, .x = 1, .y = 11 },
    HuffmanBigNode{ .len = 11, .code = 0b00000011111, .x = 1, .y = 12 },
    HuffmanBigNode{ .len = 12, .code = 0b000000100011, .x = 1, .y = 13 },
    HuffmanBigNode{ .len = 12, .code = 0b000000010110, .x = 1, .y = 14 },
    HuffmanBigNode{ .len = 12, .code = 0b000000001110, .x = 1, .y = 15 },
    HuffmanBigNode{ .len = 6, .code = 0b001111, .x = 2, .y = 0 },
    HuffmanBigNode{ .len = 6, .code = 0b001101, .x = 2, .y = 1 },
    HuffmanBigNode{ .len = 7, .code = 0b0010111, .x = 2, .y = 2 },
    HuffmanBigNode{ .len = 8, .code = 0b00100100, .x = 2, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000111011, .x = 2, .y = 4 },
    HuffmanBigNode{ .len = 9, .code = 0b000110001, .x = 2, .y = 5 },
    HuffmanBigNode{ .len = 10, .code = 0b0001001101, .x = 2, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0001000001, .x = 2, .y = 7 },
    HuffmanBigNode{ .len = 9, .code = 0b000011101, .x = 2, .y = 8 },
    HuffmanBigNode{ .len = 10, .code = 0b0000101000, .x = 2, .y = 9 },
    HuffmanBigNode{ .len = 10, .code = 0b0000011110, .x = 2, .y = 10 },
    HuffmanBigNode{ .len = 11, .code = 0b00000101000, .x = 2, .y = 11 },
    HuffmanBigNode{ .len = 11, .code = 0b00000011011, .x = 2, .y = 12 },
    HuffmanBigNode{ .len = 12, .code = 0b000000100001, .x = 2, .y = 13 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000101010, .x = 2, .y = 14 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000010000, .x = 2, .y = 15 },
    HuffmanBigNode{ .len = 7, .code = 0b0010110, .x = 3, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0010100, .x = 3, .y = 1 },
    HuffmanBigNode{ .len = 8, .code = 0b00100101, .x = 3, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000111101, .x = 3, .y = 3 },
    HuffmanBigNode{ .len = 9, .code = 0b000111000, .x = 3, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0001001111, .x = 3, .y = 5 },
    HuffmanBigNode{ .len = 10, .code = 0b0001001001, .x = 3, .y = 6 },
    HuffmanBigNode{ .len = 10, .code = 0b0001000000, .x = 3, .y = 7 },
    HuffmanBigNode{ .len = 10, .code = 0b0000101011, .x = 3, .y = 8 },
    HuffmanBigNode{ .len = 11, .code = 0b00001001100, .x = 3, .y = 9 },
    HuffmanBigNode{ .len = 11, .code = 0b00000111000, .x = 3, .y = 10 },
    HuffmanBigNode{ .len = 11, .code = 0b00000100101, .x = 3, .y = 11 },
    HuffmanBigNode{ .len = 11, .code = 0b00000011010, .x = 3, .y = 12 },
    HuffmanBigNode{ .len = 12, .code = 0b000000011111, .x = 3, .y = 13 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000011001, .x = 3, .y = 14 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000001110, .x = 3, .y = 15 },
    HuffmanBigNode{ .len = 8, .code = 0b00100011, .x = 4, .y = 0 },
    HuffmanBigNode{ .len = 7, .code = 0b0010000, .x = 4, .y = 1 },
    HuffmanBigNode{ .len = 9, .code = 0b000111100, .x = 4, .y = 2 },
    HuffmanBigNode{ .len = 9, .code = 0b000111001, .x = 4, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0001100001, .x = 4, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0001001011, .x = 4, .y = 5 },
    HuffmanBigNode{ .len = 11, .code = 0b00001110010, .x = 4, .y = 6 },
    HuffmanBigNode{ .len = 11, .code = 0b00001011011, .x = 4, .y = 7 },
    HuffmanBigNode{ .len = 10, .code = 0b0000110110, .x = 4, .y = 8 },
    HuffmanBigNode{ .len = 11, .code = 0b00001001001, .x = 4, .y = 9 },
    HuffmanBigNode{ .len = 11, .code = 0b00000110111, .x = 4, .y = 10 },
    HuffmanBigNode{ .len = 12, .code = 0b000000101001, .x = 4, .y = 11 },
    HuffmanBigNode{ .len = 12, .code = 0b000000110000, .x = 4, .y = 12 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000110101, .x = 4, .y = 13 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000010111, .x = 4, .y = 14 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000011000, .x = 4, .y = 15 },
    HuffmanBigNode{ .len = 9, .code = 0b000111010, .x = 5, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00011011, .x = 5, .y = 1 },
    HuffmanBigNode{ .len = 9, .code = 0b000110010, .x = 5, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0001100000, .x = 5, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0001001100, .x = 5, .y = 4 },
    HuffmanBigNode{ .len = 10, .code = 0b0001000110, .x = 5, .y = 5 },
    HuffmanBigNode{ .len = 11, .code = 0b00001011101, .x = 5, .y = 6 },
    HuffmanBigNode{ .len = 11, .code = 0b00001010100, .x = 5, .y = 7 },
    HuffmanBigNode{ .len = 11, .code = 0b00001001101, .x = 5, .y = 8 },
    HuffmanBigNode{ .len = 11, .code = 0b00000111010, .x = 5, .y = 9 },
    HuffmanBigNode{ .len = 12, .code = 0b000001001111, .x = 5, .y = 10 },
    HuffmanBigNode{ .len = 11, .code = 0b00000011101, .x = 5, .y = 11 },
    HuffmanBigNode{ .len = 13, .code = 0b0000001001010, .x = 5, .y = 12 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000110001, .x = 5, .y = 13 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000101001, .x = 5, .y = 14 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000010001, .x = 5, .y = 15 },
    HuffmanBigNode{ .len = 9, .code = 0b000101111, .x = 6, .y = 0 },
    HuffmanBigNode{ .len = 9, .code = 0b000101101, .x = 6, .y = 1 },
    HuffmanBigNode{ .len = 10, .code = 0b0001001110, .x = 6, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0001001010, .x = 6, .y = 3 },
    HuffmanBigNode{ .len = 11, .code = 0b00001110011, .x = 6, .y = 4 },
    HuffmanBigNode{ .len = 11, .code = 0b00001011110, .x = 6, .y = 5 },
    HuffmanBigNode{ .len = 11, .code = 0b00001011010, .x = 6, .y = 6 },
    HuffmanBigNode{ .len = 11, .code = 0b00001001111, .x = 6, .y = 7 },
    HuffmanBigNode{ .len = 11, .code = 0b00001000101, .x = 6, .y = 8 },
    HuffmanBigNode{ .len = 12, .code = 0b000001010011, .x = 6, .y = 9 },
    HuffmanBigNode{ .len = 12, .code = 0b000001000111, .x = 6, .y = 10 },
    HuffmanBigNode{ .len = 12, .code = 0b000000110010, .x = 6, .y = 11 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000111011, .x = 6, .y = 12 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000100110, .x = 6, .y = 13 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000100100, .x = 6, .y = 14 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000001111, .x = 6, .y = 15 },
    HuffmanBigNode{ .len = 10, .code = 0b0001001000, .x = 7, .y = 0 },
    HuffmanBigNode{ .len = 9, .code = 0b000100010, .x = 7, .y = 1 },
    HuffmanBigNode{ .len = 10, .code = 0b0000111000, .x = 7, .y = 2 },
    HuffmanBigNode{ .len = 11, .code = 0b00001011111, .x = 7, .y = 3 },
    HuffmanBigNode{ .len = 11, .code = 0b00001011100, .x = 7, .y = 4 },
    HuffmanBigNode{ .len = 11, .code = 0b00001010101, .x = 7, .y = 5 },
    HuffmanBigNode{ .len = 12, .code = 0b000001011011, .x = 7, .y = 6 },
    HuffmanBigNode{ .len = 12, .code = 0b000001011010, .x = 7, .y = 7 },
    HuffmanBigNode{ .len = 12, .code = 0b000001010110, .x = 7, .y = 8 },
    HuffmanBigNode{ .len = 12, .code = 0b000001001001, .x = 7, .y = 9 },
    HuffmanBigNode{ .len = 13, .code = 0b0000001001101, .x = 7, .y = 10 },
    HuffmanBigNode{ .len = 13, .code = 0b0000001000001, .x = 7, .y = 11 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000110011, .x = 7, .y = 12 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000101100, .x = 7, .y = 13 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000101011, .x = 7, .y = 14 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000101010, .x = 7, .y = 15 },
    HuffmanBigNode{ .len = 9, .code = 0b000101011, .x = 8, .y = 0 },
    HuffmanBigNode{ .len = 8, .code = 0b00010100, .x = 8, .y = 1 },
    HuffmanBigNode{ .len = 9, .code = 0b000011110, .x = 8, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0000101100, .x = 8, .y = 3 },
    HuffmanBigNode{ .len = 10, .code = 0b0000110111, .x = 8, .y = 4 },
    HuffmanBigNode{ .len = 11, .code = 0b00001001110, .x = 8, .y = 5 },
    HuffmanBigNode{ .len = 11, .code = 0b00001001000, .x = 8, .y = 6 },
    HuffmanBigNode{ .len = 12, .code = 0b000001010111, .x = 8, .y = 7 },
    HuffmanBigNode{ .len = 12, .code = 0b000001001110, .x = 8, .y = 8 },
    HuffmanBigNode{ .len = 12, .code = 0b000000111101, .x = 8, .y = 9 },
    HuffmanBigNode{ .len = 12, .code = 0b000000101110, .x = 8, .y = 10 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000110110, .x = 8, .y = 11 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000100101, .x = 8, .y = 12 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000011110, .x = 8, .y = 13 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000010100, .x = 8, .y = 14 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000010000, .x = 8, .y = 15 },
    HuffmanBigNode{ .len = 10, .code = 0b0000110101, .x = 9, .y = 0 },
    HuffmanBigNode{ .len = 9, .code = 0b000011001, .x = 9, .y = 1 },
    HuffmanBigNode{ .len = 10, .code = 0b0000101001, .x = 9, .y = 2 },
    HuffmanBigNode{ .len = 10, .code = 0b0000100101, .x = 9, .y = 3 },
    HuffmanBigNode{ .len = 11, .code = 0b00000101100, .x = 9, .y = 4 },
    HuffmanBigNode{ .len = 11, .code = 0b00000111011, .x = 9, .y = 5 },
    HuffmanBigNode{ .len = 11, .code = 0b00000110110, .x = 9, .y = 6 },
    HuffmanBigNode{ .len = 13, .code = 0b0000001010001, .x = 9, .y = 7 },
    HuffmanBigNode{ .len = 12, .code = 0b000001000010, .x = 9, .y = 8 },
    HuffmanBigNode{ .len = 13, .code = 0b0000001001100, .x = 9, .y = 9 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000111001, .x = 9, .y = 10 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000110110, .x = 9, .y = 11 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000100101, .x = 9, .y = 12 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000010010, .x = 9, .y = 13 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000100111, .x = 9, .y = 14 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000001011, .x = 9, .y = 15 },
    HuffmanBigNode{ .len = 10, .code = 0b0000100011, .x = 10, .y = 0 },
    HuffmanBigNode{ .len = 10, .code = 0b0000100001, .x = 10, .y = 1 },
    HuffmanBigNode{ .len = 10, .code = 0b0000011111, .x = 10, .y = 2 },
    HuffmanBigNode{ .len = 11, .code = 0b00000111001, .x = 10, .y = 3 },
    HuffmanBigNode{ .len = 11, .code = 0b00000101010, .x = 10, .y = 4 },
    HuffmanBigNode{ .len = 12, .code = 0b000001010010, .x = 10, .y = 5 },
    HuffmanBigNode{ .len = 12, .code = 0b000001001000, .x = 10, .y = 6 },
    HuffmanBigNode{ .len = 13, .code = 0b0000001010000, .x = 10, .y = 7 },
    HuffmanBigNode{ .len = 12, .code = 0b000000101111, .x = 10, .y = 8 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000111010, .x = 10, .y = 9 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000110111, .x = 10, .y = 10 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000010101, .x = 10, .y = 11 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000010110, .x = 10, .y = 12 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000011010, .x = 10, .y = 13 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000100110, .x = 10, .y = 14 },
    HuffmanBigNode{ .len = 17, .code = 0b00000000000010110, .x = 10, .y = 15 },
    HuffmanBigNode{ .len = 11, .code = 0b00000110101, .x = 11, .y = 0 },
    HuffmanBigNode{ .len = 10, .code = 0b0000011001, .x = 11, .y = 1 },
    HuffmanBigNode{ .len = 10, .code = 0b0000010111, .x = 11, .y = 2 },
    HuffmanBigNode{ .len = 11, .code = 0b00000100110, .x = 11, .y = 3 },
    HuffmanBigNode{ .len = 12, .code = 0b000001000110, .x = 11, .y = 4 },
    HuffmanBigNode{ .len = 12, .code = 0b000000111100, .x = 11, .y = 5 },
    HuffmanBigNode{ .len = 12, .code = 0b000000110011, .x = 11, .y = 6 },
    HuffmanBigNode{ .len = 12, .code = 0b000000100100, .x = 11, .y = 7 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000110111, .x = 11, .y = 8 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000011010, .x = 11, .y = 9 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000100010, .x = 11, .y = 10 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000010111, .x = 11, .y = 11 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000011011, .x = 11, .y = 12 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000001110, .x = 11, .y = 13 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000001001, .x = 11, .y = 14 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000000111, .x = 11, .y = 15 },
    HuffmanBigNode{ .len = 11, .code = 0b00000100010, .x = 12, .y = 0 },
    HuffmanBigNode{ .len = 11, .code = 0b00000100000, .x = 12, .y = 1 },
    HuffmanBigNode{ .len = 11, .code = 0b00000011100, .x = 12, .y = 2 },
    HuffmanBigNode{ .len = 12, .code = 0b000000100111, .x = 12, .y = 3 },
    HuffmanBigNode{ .len = 12, .code = 0b000000110001, .x = 12, .y = 4 },
    HuffmanBigNode{ .len = 13, .code = 0b0000001001011, .x = 12, .y = 5 },
    HuffmanBigNode{ .len = 12, .code = 0b000000011110, .x = 12, .y = 6 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000110100, .x = 12, .y = 7 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000110000, .x = 12, .y = 8 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000101000, .x = 12, .y = 9 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000110100, .x = 12, .y = 10 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000011100, .x = 12, .y = 11 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000010010, .x = 12, .y = 12 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000010001, .x = 12, .y = 13 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000001001, .x = 12, .y = 14 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000000101, .x = 12, .y = 15 },
    HuffmanBigNode{ .len = 12, .code = 0b000000101101, .x = 13, .y = 0 },
    HuffmanBigNode{ .len = 11, .code = 0b00000010101, .x = 13, .y = 1 },
    HuffmanBigNode{ .len = 12, .code = 0b000000100010, .x = 13, .y = 2 },
    HuffmanBigNode{ .len = 13, .code = 0b0000001000000, .x = 13, .y = 3 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000111000, .x = 13, .y = 4 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000110010, .x = 13, .y = 5 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000110001, .x = 13, .y = 6 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000101101, .x = 13, .y = 7 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000011111, .x = 13, .y = 8 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000010011, .x = 13, .y = 9 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000001100, .x = 13, .y = 10 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000001111, .x = 13, .y = 11 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000001010, .x = 13, .y = 12 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000000111, .x = 13, .y = 13 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000000110, .x = 13, .y = 14 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000000011, .x = 13, .y = 15 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000110000, .x = 14, .y = 0 },
    HuffmanBigNode{ .len = 12, .code = 0b000000010111, .x = 14, .y = 1 },
    HuffmanBigNode{ .len = 12, .code = 0b000000010100, .x = 14, .y = 2 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000100111, .x = 14, .y = 3 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000100100, .x = 14, .y = 4 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000100011, .x = 14, .y = 5 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000110101, .x = 14, .y = 6 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000010101, .x = 14, .y = 7 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000010000, .x = 14, .y = 8 },
    HuffmanBigNode{ .len = 17, .code = 0b00000000000010111, .x = 14, .y = 9 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000001101, .x = 14, .y = 10 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000001010, .x = 14, .y = 11 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000000110, .x = 14, .y = 12 },
    HuffmanBigNode{ .len = 17, .code = 0b00000000000000001, .x = 14, .y = 13 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000000100, .x = 14, .y = 14 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000000010, .x = 14, .y = 15 },
    HuffmanBigNode{ .len = 12, .code = 0b000000010000, .x = 15, .y = 0 },
    HuffmanBigNode{ .len = 12, .code = 0b000000001111, .x = 15, .y = 1 },
    HuffmanBigNode{ .len = 13, .code = 0b0000000010001, .x = 15, .y = 2 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000011011, .x = 15, .y = 3 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000011001, .x = 15, .y = 4 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000010100, .x = 15, .y = 5 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000011101, .x = 15, .y = 6 },
    HuffmanBigNode{ .len = 14, .code = 0b00000000001011, .x = 15, .y = 7 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000010001, .x = 15, .y = 8 },
    HuffmanBigNode{ .len = 15, .code = 0b000000000001100, .x = 15, .y = 9 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000010000, .x = 15, .y = 10 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000001000, .x = 15, .y = 11 },
    HuffmanBigNode{ .len = 19, .code = 0b0000000000000000001, .x = 15, .y = 12 },
    HuffmanBigNode{ .len = 18, .code = 0b000000000000000001, .x = 15, .y = 13 },
    HuffmanBigNode{ .len = 19, .code = 0b0000000000000000000, .x = 15, .y = 14 },
    HuffmanBigNode{ .len = 16, .code = 0b0000000000000001, .x = 15, .y = 15 },
};
