const std = @import("std");
const config = @import("config");

const id3 = @import("id3.zig");
const mp3_unpack = @import("mp3_unpacker.zig");
const mp3_decode = @import("mp3_decoder.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);

    const files = [_][]const u8{"./data2.mp3"};

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};

    var buffer = [_]u8{0} ** 2332227;

    for (files) |file| {
        _ = try std.fs.cwd().readFile(file, &buffer);

        const tag = try id3.parse_id3_tag(&buffer, alloc.allocator());
        defer tag.frames.deinit();

        if (config.verbose_id3) {
            id3.debug_id3_tag(tag);
        }

        const mp3_data = buffer[(tag.header.size + 10)..];

        var decoder = try mp3_decode.DecoderState.init(mp3_data, alloc.allocator());

        while (try decoder.next(alloc.allocator())) |frame| {
            try bw.writer().print("Data size {}\n", .{frame.data.len});
            try bw.writer().print("Sampling rate {}\n", .{frame.header.freq});
            try bw.flush();
            alloc.allocator().free(frame.data);
        }
    }
    try bw.flush();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
