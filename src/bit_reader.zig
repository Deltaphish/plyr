const std = @import("std");

pub const BitReader = struct {
    buffer: []const u8,
    bit_cursor: u32,
    bit_cursor_limit: u32,

    pub fn init(buffer: []const u8) BitReader {
        return BitReader{ .buffer = buffer, .bit_cursor = 0, .bit_cursor_limit = std.math.maxInt(u32) };
    }

    pub fn init_with_limit(buffer: []const u8, limit: u32) BitReader {
        return BitReader{ .buffer = buffer, .bit_cursor = 0, .bit_cursor_limit = limit };
    }

    pub fn inc_limit(self: *BitReader, ammount: u32) void {
        self.bit_cursor_limit += ammount;
    }

    pub fn readByte(self: *BitReader) ?u8 {
        const inital_cursor = self.bit_cursor;
        defer std.debug.assert(self.bit_cursor == inital_cursor);

        if (self.bit_cursor >= self.buffer.len * 8) {
            return null;
        } else if (self.bit_cursor % 8 == 0) {
            return self.buffer[self.bit_cursor / 8];
        } else {
            const first = self.buffer[self.bit_cursor / 8];
            var second: u8 = undefined;

            if (self.bit_cursor >= (self.buffer.len - 1) * 8) {
                second = 0;
            } else {
                second = self.buffer[self.bit_cursor / 8 + 1];
            }

            const padding_len: u3 = @intCast(self.bit_cursor % 8);
            return @intCast((first << padding_len) | (second >> (7 - (padding_len - 1))));
        }
    }

    pub fn readBits(self: *BitReader, bit_count: u32) ?u32 {
        if (bit_count + self.bit_cursor > self.bit_cursor_limit) {
            std.debug.print("Hitt cursor limit {}, with step {}\n", .{ self.bit_cursor_limit, bit_count });
            return null;
        }
        if (bit_count == 0) {
            return 0;
        }
        const inital_cursor = self.bit_cursor;
        defer std.debug.assert(self.bit_cursor == inital_cursor);

        if (bit_count < 8) {
            const small_bit_count: u3 = @truncate(bit_count - 1);
            const byte = self.readByte() orelse return null;
            return @intCast(byte >> (7 - small_bit_count));
        }
        if (bit_count == 8) {
            return @intCast(self.readByte() orelse return null);
        }

        var res: u32 = 0;
        var bits_to_read: u32 = bit_count;

        while (bits_to_read >= 8) {
            const byte = self.readByte() orelse return null;
            res <<= 8;
            res |= byte;
            bits_to_read -= 8;
            self.bit_cursor += 8;
        }
        if (bits_to_read != 0) {
            const byte = self.readByte() orelse return null;
            const small_bits_to_read: u3 = @truncate(bits_to_read - 1);
            res <<= small_bits_to_read + 1;
            res |= (byte >> (7 - small_bits_to_read));
            self.bit_cursor += bits_to_read;
        }
        self.bit_cursor -= bit_count;
        return @intCast(res);
    }

    pub fn walkForward(self: *BitReader, steps: u32) bool {
        if (steps + self.bit_cursor > self.bit_cursor_limit) {
            return false;
        }
        self.bit_cursor += steps;
        return self.bit_cursor < self.buffer.len * 8;
    }
};

test "read aligned bytes" {
    const buffer = [_]u8{ 0xff, 0 };
    var breader = BitReader.init(buffer[0..]);

    try std.testing.expect(breader.readByte() != null);
    try std.testing.expectEqual(buffer[0], breader.readByte());

    _ = breader.walkForward(8);

    try std.testing.expect(breader.readByte() != null);
    try std.testing.expectEqual(buffer[1], breader.readByte());
}

test "read N < 8 bits" {
    const buffer = [_]u8{ 0, 0b11111111 };
    var breader = BitReader.init(buffer[0..]);

    try std.testing.expect(breader.readBits(2) != null);
    try std.testing.expectEqual(0, breader.readBits(2));

    _ = breader.walkForward(8);

    try std.testing.expect(breader.readBits(2) != null);
    try std.testing.expectEqual(3, breader.readBits(2));
}

test "read N > 8 bits" {
    const buffer = [_]u8{ 0, 0b11111111 };
    var breader = BitReader.init(buffer[0..]);

    try std.testing.expect(breader.readBits(16) != null);
    try std.testing.expectEqual(0b11111111, breader.readBits(16));
}

test "read N > 8 where N % 8 != 0 bits" {
    const buffer = [_]u8{ 0b11111111, 0xff };
    var breader = BitReader.init(buffer[0..]);

    try std.testing.expect(breader.readBits(13) != null);
    try std.testing.expectEqual(0x1FFF, breader.readBits(13));
}

test "read some bits" {
    const buffer = [_]u8{ 0, 0b11111111 };
    var breader = BitReader.init(buffer[0..]);

    try std.testing.expect(breader.readByte() != null);
    try std.testing.expectEqual(0, breader.readByte());

    _ = breader.walkForward(1);

    try std.testing.expect(breader.readByte() != null);
    try std.testing.expectEqual(1, breader.readByte());

    _ = breader.walkForward(1);

    try std.testing.expect(breader.readByte() != null);
    try std.testing.expectEqual(3, breader.readByte());
}

test "detect end of stream" {
    const buffer = [_]u8{ 0, 0b11111111 };
    var breader = BitReader.init(buffer[0..]);

    try std.testing.expect(breader.walkForward(8));
    try std.testing.expect(!breader.walkForward(8));
}

test "detect bit limit" {
    const buffer = [_]u8{ 0, 0b11111111, 0b1111 };
    var breader = BitReader.init_with_limit(buffer[0..], 9);

    try std.testing.expect(breader.walkForward(8));
    try std.testing.expect(!breader.walkForward(8));
}
