const std = @import("std");

const id3 = @import("id3.zig");
const mp3 = @import("mp3.zig");

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const files = [_][]const u8{"./data2.mp3"};

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};

    var buffer = [_]u8{0} ** 2332227;

    for (files) |file| {
        _ = try std.fs.cwd().readFile(file, &buffer);

        try stdout.print("Reading file {s}\n", .{file});

        const tag = try id3.parse_id3_tag(&buffer, alloc.allocator());
        defer tag.frames.deinit();

        try stdout.print("Found ID3 tag \n  version :: {d}.{d}\n  size :: {d} bytes\n flags :: {b}\n", .{ tag.header.major_version, tag.header.minor_version, tag.header.size, tag.header.flags });

        var total_frame_size: i64 = 0;

        for (tag.frames.items) |frame| {
            total_frame_size += frame.size + 10;
            try stdout.print("{s} size :: {d}\n", .{ frame.id, frame.size });
        }

        try stdout.print("after tag ({x}): {x}\n", .{ tag.header.size + 10, buffer[(tag.header.size + 10)..(tag.header.size + 30)] });
        try stdout.print("total frame size :: {d}\n diff :: {d}", .{ total_frame_size, @as(i64, tag.header.size) - total_frame_size });

        const mp3_data = buffer[(tag.header.size + 10)..];

        try bw.flush();

        const frames = try mp3.MP3_parse_frames(mp3_data, alloc.allocator());
        defer frames.deinit();

        for (frames.items) |f| {
            mp3.MP3_debug_frame(f);
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
