const std = @import("std");
const config = @import("config");

const id3 = @import("id3.zig");
const mp3_unpack = @import("mp3_unpacker.zig");
const mp3_decode = @import("mp3_decoder.zig");
const mp3_tables = @import("mp3_table.zig");
const mp3_t = @import("mp3_types.zig");

const mp3_requant = @import("requantize.zig");
const mp3_alias = @import("alias_reduction.zig");

const mp3_imdct = @import("./imdct.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;

    const stdout_file = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stdout = stdout_file.interface;

    const files = [_][]const u8{
        "./data1.mp3",
    };

    const alloc = init.gpa;

    var buffer = [_]u8{0} ** 2332227;

    for (files) |file| {
        _ = try std.Io.Dir.cwd().readFile(io, file, &buffer);

        var tag = try id3.parse_id3_tag(&buffer, alloc);
        defer tag.frames.deinit(alloc);

        if (config.verbose_id3) {
            id3.debug_id3_tag(tag);
        }

        const mp3_data = buffer[(tag.header.size + 10)..];
        const huffman_tables = mp3_tables.Decoder.init(alloc);

        var decoder = try mp3_decode.DecoderState.init(huffman_tables, mp3_data);

        var count: usize = 0;
        var bad_frames: usize = 0;
        while (true) {
            if (decoder.next()) |maybeFrame| {
                if (maybeFrame) |frame| {
                    try stdout.print("Version {}\n", .{frame.header.mpeg_version});
                    try stdout.print("Sampling rate {}\n", .{frame.header.freq});
                    try stdout.print("big_count {}\n", .{frame.side_info.granules[0][1].big_values});
                    try stdout.print("Data {any}\n", .{frame.data[1][0].data});

                    var q_frame = mp3_requant.requantize(frame);
                    mp3_alias.alias_reduction(&q_frame);
                    const samples = mp3_imdct.convertToSamples(null, q_frame);
                    try stdout.print("{any}\n", .{samples.data[0][0]});
                    count += 1;
                } else {
                    break; // End of file
                }
            } else |err| switch (err) {
                mp3_t.MP3_ERROR.MalformedData => {
                    try stdout.print("Found bad frame (main)\n", .{});
                    bad_frames += 1;
                    continue;
                },
                mp3_t.MP3_ERROR.MalformedSideData => {
                    try stdout.print("Found bad frame (side)\n", .{});
                    bad_frames += 1;
                    continue;
                },
                else => {
                    std.debug.print("Error occured {}\n", .{err});
                    break;
                },
            }
        }
        try stdout.print("Found {} frames, skipped {} frames\n", .{ count, bad_frames });
    }
    try stdout.flush();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
