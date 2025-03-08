const std = @import("std");

pub const BitReader = struct {
    buffer: []const u8,
    bit_cursor: u32,

    pub fn init(buffer: []const u8) BitReader {
        return BitReader{ .buffer = buffer, .bit_cursor = 0 };
    }

    pub fn readByte(self: *BitReader) ?u8 {
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

    pub fn walkForward(self: *BitReader, steps: u32) bool {
        self.bit_cursor += steps;
        return self.bit_cursor < self.buffer.len * 8;
    }
};

test "read aligned bytes" {
    const buffer = [_]u8{ 0xff, 0 };
    var breader = BitReader{ .buffer = buffer[0..], .bit_cursor = 0 };

    try std.testing.expect(breader.readByte() != null);
    try std.testing.expectEqual(buffer[0], breader.readByte());

    _ = breader.walkForward(8);

    try std.testing.expect(breader.readByte() != null);
    try std.testing.expectEqual(buffer[1], breader.readByte());
}

test "read some bits" {
    const buffer = [_]u8{ 0, 0b11111111 };
    var breader = BitReader{ .buffer = buffer[0..], .bit_cursor = 0 };

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
    var breader = BitReader{ .buffer = buffer[0..], .bit_cursor = 0 };

    try std.testing.expect(breader.walkForward(8));
    try std.testing.expect(!breader.walkForward(8));
}
