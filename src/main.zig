const std = @import("std");
const config = @import("config");

const id3 = @import("id3.zig");
const mp3 = @import("mp3.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const files = [_][]const u8{"./data1.mp3"};

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};

    var buffer = [_]u8{0} ** 2332227;

    for (files) |file| {
        _ = try std.fs.cwd().readFile(file, &buffer);

        try stdout.print("Reading file {s}\n", .{file});

        const tag = try id3.parse_id3_tag(&buffer, alloc.allocator());
        defer tag.frames.deinit();

        if (config.verbose_id3) {
            id3.debug_id3_tag(tag);
        }

        const mp3_data = buffer[(tag.header.size + 10)..];

        try bw.flush();

        const frames = try mp3.MP3_parse_frames(mp3_data, alloc.allocator());
        defer frames.deinit();

        if (config.verbose_mp3_headers) {
            for (frames.items) |f| {
                mp3.MP3_debug_frame(f);
            }
        }

        std.debug.print("Found {d} frames", .{frames.items.len});
    }
    try bw.flush();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
