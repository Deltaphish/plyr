const std = @import("std");
const config = @import("config");

const id3 = @import("id3.zig");
const mp3_unpack = @import("mp3_unpacker.zig");
const mp3_decode = @import("mp3_decoder.zig");
const mp3_t = @import("mp3_types.zig");

const mp3_requant = @import("requantize.zig");
const mp3_alias = @import("alias_reduction.zig");

const mp3_imdct = @import("./imdct.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);

    const files = [_][]const u8{
        "./data1.mp3",
    };

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

        var decoder = try mp3_decode.DecoderState.init(mp3_data);

        var count: usize = 0;
        var bad_frames: usize = 0;
        while (true) {
            if (decoder.next()) |maybeFrame| {
                if (maybeFrame) |frame| {
                    try bw.writer().print("Version {}\n", .{frame.header.mpeg_version});
                    try bw.writer().print("Sampling rate {}\n", .{frame.header.freq});
                    try bw.writer().print("big_count {}\n", .{frame.side_info.granules[0][1].big_values});
                    try bw.writer().print("Data {any}\n", .{frame.data[1][0].data});

                    var q_frame = mp3_requant.requantize(frame);
                    mp3_alias.alias_reduction(&q_frame);
                    const samples = mp3_imdct.convertToSamples(null, q_frame);

                    try bw.writer().print("Quantized data: {any}\n", .{samples[0][1]});

                    try bw.flush();
                    count += 1;
                } else {
                    break; // End of file
                }
            } else |err| switch (err) {
                mp3_t.MP3_ERROR.MalformedData => {
                    try bw.writer().print("Found bad frame (main)\n", .{});
                    bad_frames += 1;
                    continue;
                },
                mp3_t.MP3_ERROR.MalformedSideData => {
                    try bw.writer().print("Found bad frame (side)\n", .{});
                    bad_frames += 1;
                    continue;
                },
                else => {
                    std.debug.print("Error occured {}\n", .{err});
                    break;
                },
            }
        }
        try bw.writer().print("Found {} frames, skipped {} frames\n", .{ count, bad_frames });
    }
    try bw.flush();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
