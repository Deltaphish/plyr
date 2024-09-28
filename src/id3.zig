const std = @import("std");

const ZERO_FRAME = [4]u8{ 0, 0, 0, 0 };

pub const ID3_Error = error{
    InvalidHeaderSize,
    InvalidMagicSignature,
    InvalidFrameSize,
    AllocatorError,
};

pub const ID3_TAG = struct {
    header: ID3_HEADER,
    frames: std.ArrayList(ID3_FRAME),
};

pub const ID3_HEADER = struct {
    major_version: u8,
    minor_version: u8,
    flags: u8,
    size: u28,
};

pub const ID3_FRAME = struct { id: *const [4]u8, size: u32, flags: u16, data: []const u8 };

pub fn parse_id3_tag(data: []const u8, alloc: std.mem.Allocator) ID3_Error!ID3_TAG {
    const header = try parse_id3_header(data);

    var frames = std.ArrayList(ID3_FRAME).init(alloc);

    const frame_data = data[10..];
    var cursor: usize = 0;

    while (cursor < frame_data.len - 10) {
        const frame = try parse_id3_frame(header.major_version, frame_data[cursor..]);
        if (std.mem.eql(u8, frame.id, &ZERO_FRAME)) {
            break;
        }
        cursor += frame.size + 10;
        const frame_ptr = frames.addOne() catch return ID3_Error.AllocatorError;
        frame_ptr.* = frame;
    }

    return ID3_TAG{ .header = header, .frames = frames };
}

fn parse_syncsafe_int(data: []const u8) ID3_Error!u28 {
    if (data.len != 4) {
        return ID3_Error.InvalidHeaderSize;
    }
    var result: u28 = 0;
    for (0..4) |i| {
        const safe_value = @as(u28, data[3 - i]);
        const offset: u5 = @intCast(7 * i);
        result |= @shlExact(safe_value, offset);
    }
    return result;
}

test "parse syncsafe integers" {
    const data_1 = [4]u8{ 0x00, 0x47, 0x2C, 0x25 };
    const data_2 = [4]u8{ 0x00, 0x00, 0x11, 0x6A };

    const res_1 = try parse_syncsafe_int(data_1[0..4]);
    const res_2 = try parse_syncsafe_int(data_2[0..4]);

    try std.testing.expectEqual(0x11D625, res_1);
    try std.testing.expectEqual(0x8EA, res_2);
}

fn parse_id3_header(data: []const u8) ID3_Error!ID3_HEADER {
    if (data.len < 10) {
        return ID3_Error.InvalidHeaderSize;
    }
    if ((data[0] != 0x49) or (data[1] != 0x44) or (data[2] != 0x33)) {
        return ID3_Error.InvalidMagicSignature;
    }

    const major_version = data[3];
    const minor_version = data[4];
    const flags = data[5];

    const size = try parse_syncsafe_int(data[6..10]);

    return ID3_HEADER{ .major_version = major_version, .minor_version = minor_version, .flags = flags, .size = size };
}

fn parse_id3_frame(major_version: u8, data: []const u8) ID3_Error!ID3_FRAME {
    if (data.len < 10) {
        return ID3_Error.InvalidHeaderSize;
    }
    const id: *const [4]u8 = data[0..4];

    const size: u32 = if (major_version >= 4)
        try parse_syncsafe_int(data[4..8])
    else
        (@as(u32, data[4]) << 24) + (@as(u32, data[5]) << 16) + (@as(u32, data[6]) << 8) + @as(u32, data[7]);

    const flags: u16 = (@as(u16, data[8]) << 8) + @as(u16, data[9]);

    const frame_data = data[10..];

    if (frame_data.len < size) {
        std.debug.print("ID3 Frame size overflow error, frame size: {d}, remaining tag size: {d}", .{ size, frame_data.len });
        return ID3_Error.InvalidFrameSize;
    }

    const payload = frame_data[0..size];

    return ID3_FRAME{ .id = id, .size = size, .flags = flags, .data = payload };
}

test "parse headers" {
    const header_data = [10]u8{ 0x49, 0x44, 0x33, 0x3, 0x0, 0x0, 0x0, 0x0, 0x11, 0x6A };
    const header = try parse_id3_header(&header_data);
    try std.testing.expectEqual(3, header.major_version);
    try std.testing.expectEqual(0, header.minor_version);
    try std.testing.expectEqual(0, header.flags);
    try std.testing.expectEqual(2282, header.size);
}

test "parse frames" {
    const frame_data = [13]u8{ 'C', 'O', 'M', 'M', 0, 0, 0, 0x03, 0, 0, 'e', 'n', 'g' };
    const frame = try parse_id3_frame(3, &frame_data);
    try std.testing.expectEqualStrings("COMM", frame.id);
    try std.testing.expectEqual(3, frame.size);
    try std.testing.expectEqual(0, frame.flags);
    try std.testing.expectEqualStrings("eng", frame.data);
}
