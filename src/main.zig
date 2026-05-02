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
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const files = [_][]const u8{
        "./data1.mp3",
    };

    const alloc = init.gpa;

    //const alloc = init.gpa;
    var huffman_tables = mp3_tables.Decoder.init(alloc);
    defer huffman_tables.big_val.deinit();
    defer huffman_tables.r4.deinit();

    var buffer = [_]u8{0} ** 2332227;

    for (files) |file| {
        _ = try std.Io.Dir.cwd().readFile(io, file, &buffer);

        var tag = try id3.parse_id3_tag(&buffer, alloc);
        defer tag.frames.deinit(alloc);

        if (config.verbose_id3) {
            id3.debug_id3_tag(tag);
        }

        const mp3_data = buffer[(tag.header.size + 10)..];

        var decoder = try mp3_decode.DecoderState.init(huffman_tables, mp3_data);

        var count: usize = 0;
        var bad_frames: usize = 0;
        while (true) {
            var maybe_frame: ?mp3_t.LogicalFrame = null;
            if (decoder.next(&maybe_frame)) {
                if (maybe_frame) |frame| {
                    try stdout.print("Version {}\n", .{frame.header.mpeg_version});
                    try stdout.print("Sampling rate {}\n", .{frame.header.freq});
                    try stdout.print("big_count {}\n", .{frame.side_info.granules[0][1].big_values});
                    //try stdout.print("Data {any}\n", .{frame.data[1][0].data[0..576]});

                    var q_frame = mp3_requant.requantize(frame);
                    mp3_alias.alias_reduction(&q_frame);
                    //const samples = mp3_imdct.convertToSamples(null, q_frame);
                    //try stdout.print("{any}\n", .{samples.data[0][0]});
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
            try stdout.flush();
        }
        try stdout.print("Found {} frames, skipped {} frames\n", .{ count, bad_frames });
    }
    try stdout.flush();
}
