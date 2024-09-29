const std = @import("std");

const MP3_ERROR = error{
    InvalidHeader,
    UnsupportedFormat,
    UnsupportedSamplingRate,
    InvalidBitrate,
    InvalidMPEGVersion,
    OutOfMemory,
};

const MP3_FRAME = struct {
    header: MP3_HEADER,
    data: []const u8,
};

const MP3_HEADER = struct {
    crc: bool,
    padding: bool,
    priv: bool,
    original: bool,
    emphasis: u32,
    intensity_stereo: bool,
    ms_stereo: bool,
    copyright: bool,
    mpeg_version: MPEG_VERSION,
    bit_rate: u32,
    freq: u32,
    mode: CHANNEL_MODE,

    pub fn frame_size(self: *const MP3_HEADER) usize {
        return (144 * self.bit_rate / self.freq) + if (self.padding) @as(usize, 1) else @as(usize, 0);
    }
};

pub const CHANNEL_MODE = enum {
    STEREO,
    JOINT,
    DUAL,
    MONO,
};

const MPEG_LAYER = enum(u8) {
    LAYER_3 = 0x2,
    LAYER_2 = 0x4,
    LAYER_1 = 0x6,
};

pub const MPEG_VERSION = enum(u8) {
    MPEG_25 = 0,
    MPEG_2 = 0x10,
    MPEG_1 = 0x18,
};

pub fn MP3_parse_frames(data: []const u8, alloc: std.mem.Allocator) MP3_ERROR!std.ArrayList(MP3_FRAME) {
    var frames = std.ArrayList(MP3_FRAME).init(alloc);
    var remainingBuffer = data;
    while (remainingBuffer.len > 4) {
        const header = try MP3_parse_header(data);
        if (remainingBuffer.len < 4 + header.frame_size()) {
            break;
        }
        const frame_data = remainingBuffer[4..header.frame_size()];

        const new_frame = frames.addOne() catch return MP3_ERROR.OutOfMemory;
        new_frame.* = MP3_FRAME{ .header = header, .data = frame_data };
        remainingBuffer = remainingBuffer[header.frame_size()..];
    }
    return frames;
}

pub fn MP3_debug_frame(frame: MP3_FRAME) void {
    switch (frame.header.mpeg_version) {
        MPEG_VERSION.MPEG_25 => {
            std.debug.print("MP3 :: MPEG_VERSION: 2.5\n", .{});
        },
        MPEG_VERSION.MPEG_2 => {
            std.debug.print("MP3 :: MPEG_VERSION: 2.0\n", .{});
        },
        MPEG_VERSION.MPEG_1 => {
            std.debug.print("MP3 :: MPEG_VERSION: 1\n", .{});
        },
    }

    std.debug.print("MP3 :: CRC: {}\n", .{frame.header.crc});
    std.debug.print("MP3 :: BITRATE: {d} bps\n", .{frame.header.bit_rate});
    std.debug.print("MP3 :: SAMPLE_RATE: {d} hz\n", .{frame.header.freq});
    std.debug.print("MP3 :: Padding: {}\n", .{frame.header.padding});
    switch (frame.header.mode) {
        CHANNEL_MODE.DUAL => {
            std.debug.print("MP3 :: Channel Mode: DUAL\n", .{});
        },
        CHANNEL_MODE.JOINT => {
            std.debug.print("MP3 :: Channel Mode: JOINT\n", .{});
        },
        CHANNEL_MODE.STEREO => {
            std.debug.print("MP3 :: Channel Mode: STEREO\n", .{});
        },
        CHANNEL_MODE.MONO => {
            std.debug.print("MP3 :: Channel Mode: MONO\n", .{});
        },
    }
    std.debug.print("MP3 :: Copyright: {}\n", .{frame.header.copyright});
    std.debug.print("MP3 :: Original: {}\n", .{frame.header.original});
    std.debug.print("MP3 :: Emphasis: {}\n", .{frame.header.emphasis});
    std.debug.print("MP3 :: Framesize: {d} bytes\n", .{frame.header.frame_size()});
}

pub fn MP3_parse_header(data: []const u8) MP3_ERROR!MP3_HEADER {
    if (data[0] != 0xFF or data[1] < 0xE0) {
        std.debug.print("Frame sync not found", .{});
        return MP3_ERROR.InvalidHeader;
    }

    const mpeg_version = switch (@shrExact(data[1] & 0x18, 3)) {
        0 => MPEG_VERSION.MPEG_25,
        2 => MPEG_VERSION.MPEG_2,
        3 => MPEG_VERSION.MPEG_1,
        else => {
            return MP3_ERROR.InvalidMPEGVersion;
        },
    };

    switch (@shrExact(data[1] & 0x6, 1)) {
        1 => {},
        2, 3 => {
            std.debug.print("This is a gosh darn mp3 player, get the mp1/mp2 stuff out of here!", .{});
            return MP3_ERROR.UnsupportedFormat;
        },
        else => {
            return MP3_ERROR.UnsupportedFormat;
        },
    }

    const crc = !((data[1] & 1) == 1);

    const bitrate_bits = @shrExact(data[2] & 0xf0, 4);

    const bitrate: u32 = switch (mpeg_version) {
        MPEG_VERSION.MPEG_2, MPEG_VERSION.MPEG_25 => switch (bitrate_bits) {
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
                return MP3_ERROR.InvalidBitrate;
            },
        },
        MPEG_VERSION.MPEG_1 => switch (bitrate_bits) {
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
                return MP3_ERROR.InvalidBitrate;
            },
        },
    };

    const sampling_bits = @shrExact(data[2] & 0xC, 2);

    const sampling_rate_hz: u32 = switch (mpeg_version) {
        MPEG_VERSION.MPEG_25 => switch (sampling_bits) {
            0 => 11024,
            1 => 12000,
            2 => 8000,
            else => {
                return MP3_ERROR.UnsupportedSamplingRate;
            },
        },
        MPEG_VERSION.MPEG_2 => switch (sampling_bits) {
            0 => 22050,
            1 => 24000,
            2 => 16000,
            else => {
                return MP3_ERROR.UnsupportedSamplingRate;
            },
        },
        MPEG_VERSION.MPEG_1 => switch (sampling_bits) {
            0 => 44100,
            1 => 48000,
            2 => 32000,
            else => {
                return MP3_ERROR.UnsupportedSamplingRate;
            },
        },
    };

    const padding = (data[2] & 2) == 2;
    const private = (data[2] & 1) == 1;

    const channel_mode = switch (@shrExact(data[3] & 0xC0, 6)) {
        0 => CHANNEL_MODE.STEREO,
        1 => CHANNEL_MODE.JOINT,
        2 => CHANNEL_MODE.DUAL,
        3 => CHANNEL_MODE.MONO,
        else => {
            unreachable;
        },
    };

    const intensity_stereo = (data[3] & 0x20) == 0x20;
    const ms_stereo = (data[3] & 0x10) == 0x10;

    const copyright = (data[3] & 0x8) == 0x8;
    const original = (data[3] & 0x4) == 0x4;
    const emphasis: u8 = switch (data[3] & 0x3) {
        0 => 0,
        else => 0, // Pray n hope nobody uses this...
    };

    return MP3_HEADER{ .mpeg_version = mpeg_version, .crc = crc, .copyright = copyright, .emphasis = emphasis, .original = original, .ms_stereo = ms_stereo, .intensity_stereo = intensity_stereo, .mode = channel_mode, .priv = private, .padding = padding, .freq = sampling_rate_hz, .bit_rate = bitrate };
}
