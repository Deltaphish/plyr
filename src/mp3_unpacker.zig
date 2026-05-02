const std = @import("std");
const mp3_t = @import("mp3_types.zig");
const bit_reader = @import("bit_reader.zig");

const assert = std.debug.assert;

const BitReaderWrapper = struct {
    internal: bit_reader.BitReader,

    pub fn read(self: *BitReaderWrapper, comptime T: type) !T {
        return switch (@typeInfo(T)) {
            .bool => {
                defer _ = self.internal.walkForward(1);
                return (self.internal.readBits(1) orelse @panic("Out of input")) == 1;
            },
            .int => {
                defer _ = self.internal.walkForward(@sizeOf(T));
                return @truncate(self.internal.readBits(@sizeOf(T)) orelse @panic("Out of input"));
            },
            else => std.debug.panic("Can't deserialize type {}", .{T}),
        };
    }
};

fn bitReaderWrapper(bitReader: bit_reader.BitReader) BitReaderWrapper {
    return BitReaderWrapper{ .internal = bitReader };
}

//TODO refactor out to seperate file
fn parse_mpeg1_stereo_data(data: []const u8) !mp3_t.MP3_SIDE_INFO {
    const bits = bit_reader.BitReader.init(data);

    //TODO use a constructor
    var b = bitReaderWrapper(bits);
    const main_data_begin = try b.read(u9);
    const private_bits = try b.read(u3);

    var scfsi: [2][4]bool = [_][4]bool{[_]bool{false} ** 4} ** 2;

    for (0..2) |channel| {
        for (0..4) |band| {
            scfsi[channel][band] = try b.read(bool);
        }
    }

    var granules: [2][2]mp3_t.MP3_GRANULE_MPEG1 = undefined;

    for (0..2) |gr| {
        for (0..2) |ch| {
            const part2_3_lenght = try b.read(u12);
            const big_values = try b.read(u9);
            const global_gain = try b.read(u8);
            const scalefac_compress = try b.read(u4);
            const window_switching_flag = try b.read(bool);

            //TODO use initializer
            var block: mp3_t.BlockInfo = undefined;

            if (window_switching_flag) {
                const block_type = try b.read(u2);
                const mixed_block_flag = try b.read(bool);
                var table_select: [2]u5 = undefined;
                for (0..1) |region| {
                    table_select[region] = try b.read(u5);
                }
                var subblock_gain: [3]u3 = undefined;
                for (0..2) |window| {
                    subblock_gain[window] = try b.read(u3);
                }

                block = @unionInit(mp3_t.BlockInfo, "windowed_block", mp3_t.WindowedBlockInfo{
                    .block_type = block_type,
                    .mixed_block_flag = mixed_block_flag,
                    .table_select = table_select,
                    .subblock_gain = subblock_gain,
                });
            } else {
                var table_select: [3]u5 = undefined;
                for (0..2) |region| {
                    table_select[region] = try b.read(u5);
                }
                const region0_count = try b.read(u4);
                const region1_count = try b.read(u3);

                block = @unionInit(mp3_t.BlockInfo, "long_block", mp3_t.LongBlockInfo{
                    .table_select = table_select,
                    .region0_count = region0_count,
                    .region1_count = region1_count,
                });
            }
            const preflag = try b.read(bool);
            const scalefac_scale = try b.read(bool);
            const count1table_select = try b.read(bool);
            granules[gr][ch] = mp3_t.MP3_GRANULE_MPEG1{
                .part2_3_length = part2_3_lenght,
                .big_values = big_values,
                .global_gain = global_gain,
                .scalefac_compress = scalefac_compress,
                .block_info = block,
                .preflag = preflag,
                .scalefac_scale = scalefac_scale,
                .count1table_select = count1table_select,
            };
        }
    }

    return mp3_t.MP3_SIDE_INFO{ .mpeg1_stereo = mp3_t.SideInfoMpeg1Stereo{
        .main_data_begin = main_data_begin,
        .private_bits = private_bits,
        .scfsi = scfsi,
        .granules = granules,
    } };
}
pub fn MP3_parse_frames(data: []const u8, alloc: std.mem.Allocator) mp3_t.MP3_ERROR!std.ArrayList(mp3_t.MP3_FRAME) {
    var frames = std.ArrayList(mp3_t.MP3_FRAME).init(alloc);
    var remainingBuffer = data;
    while (remainingBuffer.len > 4) {
        const header = try unpack_header(data);
        if (remainingBuffer.len < 4 + header.frame_size()) {
            break;
        }
        const frame_data = remainingBuffer[4..header.frame_size()];

        const mp3_data = try unpack_side_info(header, frame_data);

        const new_frame = frames.addOne() catch return mp3_t.MP3_ERROR.MP3OutOfMemory;
        new_frame.* = mp3_t.MP3_FRAME{ .header = header, .sideInfo = mp3_data };
        remainingBuffer = remainingBuffer[header.frame_size()..];
    }
    return frames;
}

pub fn unpack_side_info(header: mp3_t.MP3_HEADER, raw_data: []const u8) mp3_t.MP3_ERROR!mp3_t.MP3_SIDE_INFO {
    return switch (header.mpeg_version) {
        mp3_t.MPEG_VERSION.MPEG_1 => {
            return parse_mpeg1_stereo_data(raw_data) catch {
                return mp3_t.MP3_ERROR.MalformedSideData;
            };
        },
        mp3_t.MPEG_VERSION.MPEG_2, mp3_t.MPEG_VERSION.MPEG_25 => return mp3_t.MP3_ERROR.UnsupportedFormat,
    };
}

pub fn MP3_debug_frame(frame: mp3_t.MP3_FRAME, writer: std.io.AnyWriter) void {
    std.json.stringify(frame, .{}, writer) catch |e| {
        std.debug.print("Failed to print mp3 frame {}", .{e});
    };
}

pub fn debug_header(header: mp3_t.MP3_HEADER, writer: std.io.AnyWriter) void {
    std.json.stringify(header, .{}, writer) catch |e| {
        std.debug.print("Failed to print header {}", .{e});
    };
}

pub fn unpack_header(data: []const u8) mp3_t.MP3_ERROR!mp3_t.MP3_HEADER {
    if (data[0] != 0xFF or ((data[1] & 0xE0) != 0xE0)) {
        std.debug.print("Frame sync not found", .{});
        return mp3_t.MP3_ERROR.InvalidHeader;
    }

    const mpeg_version = switch ((data[1] & 0x18) >> 3) {
        0 => mp3_t.MPEG_VERSION.MPEG_25,
        2 => mp3_t.MPEG_VERSION.MPEG_2,
        3 => mp3_t.MPEG_VERSION.MPEG_1,
        else => {
            return mp3_t.MP3_ERROR.InvalidMPEGVersion;
        },
    };

    switch (@shrExact(data[1] & 0x6, 1)) {
        1 => {},
        2, 3 => {
            return mp3_t.MP3_ERROR.UnsupportedFormat;
        },
        else => {
            return mp3_t.MP3_ERROR.InvalidHeader;
        },
    }

    const crc = (data[1] & 1) == 1;

    const bitrate_bits = @shrExact(data[2] & 0xF0, 4);

    const bitrate: u32 = switch (mpeg_version) {
        mp3_t.MPEG_VERSION.MPEG_2, mp3_t.MPEG_VERSION.MPEG_25 => switch (bitrate_bits) {
            0x1 => 8000,
            0x2 => 16000,
            0x3 => 24000,
            0x4 => 32000,
            0x5 => 40000,
            0x6 => 48000,
            0x7 => 56000,
            0x8 => 64000,
            0x9 => 80000,
            0xA => 96000,
            0xB => 112000,
            0xC => 128000,
            0xD => 144000,
            0xE => 160000,
            0 => 0, // "Free" bitrate
            else => {
                return mp3_t.MP3_ERROR.InvalidBitrate;
            },
        },
        mp3_t.MPEG_VERSION.MPEG_1 => switch (bitrate_bits) {
            0x1 => 32000,
            0x2 => 40000,
            0x3 => 48000,
            0x4 => 56000,
            0x5 => 64000,
            0x6 => 80000,
            0x7 => 96000,
            0x8 => 112000,
            0x9 => 128000,
            0xA => 160000,
            0xB => 192000,
            0xC => 224000,
            0xD => 256000,
            0xE => 320000,
            0 => 0, // "Free" bitrate
            else => {
                return mp3_t.MP3_ERROR.InvalidBitrate;
            },
        },
    };

    const sampling_bits: u2 = @intCast((data[2] & 0xC) >> 2);

    const sampling_rate_hz: u32 = switch (mpeg_version) {
        mp3_t.MPEG_VERSION.MPEG_25 => switch (sampling_bits) {
            0 => 11024,
            1 => 12000,
            2 => 8000,
            else => {
                return mp3_t.MP3_ERROR.UnsupportedSamplingRate;
            },
        },
        mp3_t.MPEG_VERSION.MPEG_2 => switch (sampling_bits) {
            0 => 22050,
            1 => 24000,
            2 => 16000,
            else => {
                return mp3_t.MP3_ERROR.UnsupportedSamplingRate;
            },
        },
        mp3_t.MPEG_VERSION.MPEG_1 => switch (sampling_bits) {
            0 => 44100,
            1 => 48000,
            2 => 32000,
            else => {
                return mp3_t.MP3_ERROR.UnsupportedSamplingRate;
            },
        },
    };

    const padding = (data[2] & 2) == 2;
    const private = (data[2] & 1) == 1;

    const channel_mode = switch (@shrExact(data[3] & 0xC0, 6)) {
        0 => mp3_t.CHANNEL_MODE.STEREO,
        1 => mp3_t.CHANNEL_MODE.JOINT,
        2 => mp3_t.CHANNEL_MODE.DUAL,
        3 => mp3_t.CHANNEL_MODE.MONO,
        else => {
            unreachable;
        },
    };

    const intensity_stereo = (data[3] & 0x20) == 0x20;
    const ms_stereo = (data[3] & 0x10) == 0x10;

    const copyright = (data[3] & 0x8) == 0x8;
    const original = (data[3] & 0x4) == 0x4;
    const emphasis: u8 = switch (data[3] & 3) {
        0 => 0,
        else => 0, // Pray n hope nobody uses this...
    };

    return mp3_t.MP3_HEADER{
        .mpeg_version = mpeg_version,
        .crc = crc,
        .copyright = copyright,
        .emphasis = emphasis,
        .original = original,
        .ms_stereo = ms_stereo,
        .intensity_stereo = intensity_stereo,
        .mode = channel_mode,
        .priv = private,
        .padding = padding,
        .freq = sampling_rate_hz,
        .bit_rate = bitrate,
    };
}
