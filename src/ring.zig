const std = @import("std");

pub fn RingBuffer(size: comptime_int) type {
    return struct {
        buffer: [size]u8,
        reader: usize,
        writer: usize,

        pub fn init() @This() {
            return @This(){
                .buffer = @splat(0),
                .reader = 0,
                .writer = 0,
            };
        }

        // Will overwrite if it catches up to reader.
        pub fn write(self: *@This(), data: []const u8) void {
            const remaining = self.buffer.len - self.writer;
            if (data.len > remaining) {
                @memcpy(self.buffer[self.writer..self.buffer.len], data[0..remaining]);
                @memcpy(self.buffer[0..(data.len - remaining)], data[remaining..]);
            } else {
                @memcpy(self.buffer[self.writer..(self.writer + data.len)], data);
            }
            self.writer = (self.writer + data.len) % self.buffer.len;
        }

        pub fn read(self: *@This(), to: []u8) usize {
            var end = (self.reader + to.len) % self.buffer.len;
            var read_len = to.len;
            defer self.reader = end;

            // If reader pointer catches up to writer pointer, read up until writer;
            if (self.to_read() < to.len) {
                end = self.writer;
                read_len = self.to_read();
            }

            if (end < self.reader) {
                @memcpy(to[0..(self.buffer.len - self.reader)], self.buffer[self.reader..self.buffer.len]);
                @memcpy(to[(self.buffer.len - self.reader)..], self.buffer[0..end]);
                return (self.buffer.len - self.reader) + end;
            } else {
                @memcpy(to[0..], self.buffer[self.reader..end]);
                return end - self.reader;
            }
        }

        pub fn to_read(self: *@This()) usize {
            if (self.reader < self.writer) {
                return self.writer - self.reader;
            } else {
                return (self.writer + self.buffer.len) - self.reader;
            }
        }
    };
}

test "Ring" {
    var ring = RingBuffer(10).init();

    ring.write("hello");

    var buffer = [_]u8{0} ** 32;

    const read_bytes = ring.read(buffer[0..4]);

    try std.testing.expectEqual(4, read_bytes);
    try std.testing.expectEqualStrings("hell", buffer[0..4]);
}

test "Ring check bytes left to read" {
    var ring = RingBuffer(20).init();
    var buffer = [_]u8{0} ** 20;

    ring.write("hello");
    _ = ring.read(buffer[0..3]);
    ring.write("world");

    try std.testing.expectEqual(7, ring.to_read());
}

test "Ring check bytes left to read, with writer overwraped" {
    var ring = RingBuffer(10).init();
    var buffer = [_]u8{0} ** 10;

    ring.write("hello");
    _ = ring.read(buffer[0..2]);
    ring.write("world!");

    try std.testing.expectEqual(9, ring.to_read());
}

test "Fuzz test" {
    try std.testing.fuzz({}, ringFuzzer, .{});
}

fn ringFuzzer(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    var ring = RingBuffer(10).init();
    var str = [_]u8{0} ** 10;
    var result = [_]u8{0} ** 10;

    const len = smith.slice(str[0..]);

    ring.write(str[0..len]);
    const read_count = ring.read(result[0..len]);

    try std.testing.expectEqual(len, read_count);
    try std.testing.expectEqualSlices(u8, str[0..len], result[0..len]);
}
