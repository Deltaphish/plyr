pub fn FifoQueue(comptime T: type, comptime size: comptime_int) type {
    return struct {
        const Self = @This();

        buffer: [size]T,
        reader: usize,
        writer: usize,

        pub fn init() Self {
            return Self{
                .reader = 0,
                .writer = 0,
            };
        }

        pub fn pop(self: *Self) ?T {
            if (self.reader == self.writer) return null;
            defer self.reader += 1;
            return self.buffer[self.reader % size];
        }

        pub fn push(self: *Self, value: T) void {
            defer self.writer += 1;
            self.buffer[self.writer % size] = value;
        }

        pub fn peekWithBackup(self: *Self, offset: usize, backup: T) T {
            if (self.reader + offset >= self.writer) return backup;
            return self.buffer[(self.reader + offset) % size];
        }
    };
}

test "FIFO Queue" {
    const expect = @import("std").testing.expect;

    var buffer: [3]u32 = @splat(0);
    var ring = FifoQueue(u32).init(buffer[0..]);
    ring.push(1);
    ring.push(2);
    ring.push(3);

    const a = ring.pop();
    const b = ring.pop();
    const c = ring.pop();
    const d = ring.pop();

    try expect(a != null);
    try expect(a == 1);

    try expect(b != null);
    try expect(b == 2);

    try expect(c != null);
    try expect(c == 3);

    try expect(d == null);
}
