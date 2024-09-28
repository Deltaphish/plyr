const std = @import("std");

const ZERO_FRAME = [4]u8{ 0, 0, 0, 0 };

const ParsingError = error{
    InvalidHeaderSize,
    InvalidMagicSignature,
    InvalidFrameSize,
    AllocatorError,
};

const ID3_HEADER = struct {
    major_version: u8,
    minor_version: u8,
    flags: u8,
    size: u28,
};

const ID3_FRAME = struct { id: *const [4]u8, size: u32, flags: u16, data: []const u8 };

fn parse_id3_header(data: []const u8) ParsingError!ID3_HEADER {
    if (data.len < 10) {
        return ParsingError.InvalidHeaderSize;
    }
    if ((data[0] != 0x49) or (data[1] != 0x44) or (data[2] != 0x33)) {
        return ParsingError.InvalidMagicSignature;
    }

    const major_version = data[3];
    const minor_version = data[4];
    const flags = data[5];

    var size = @as(u28, ((data[8] & 1) << 7) | (0x7f & data[9]));
    size += @as(u28, ((data[7] & 1) << 7) | (data[8] >> 1)) << 8;
    size += @as(u28, ((data[6] & 1) << 7) | (data[7] >> 1)) << 16;
    size += @as(u28, data[6] >> 1) << 24;

    return ID3_HEADER{ .major_version = major_version, .minor_version = minor_version, .flags = flags, .size = size };
}

test "parse headers" {
    const header_data = [10]u8{ 0x49, 0x44, 0x33, 0x3, 0x0, 0x0, 0x0, 0x0, 0x11, 0x6A };
    const header = try parse_id3_header(&header_data);
    try std.testing.expectEqual(3, header.major_version);
    try std.testing.expectEqual(0, header.minor_version);
    try std.testing.expectEqual(0, header.flags);
    try std.testing.expectEqual(2282, header.size);
}

fn parse_id3_frame(data: []const u8) ParsingError!ID3_FRAME {
    if (data.len < 10) {
        return ParsingError.InvalidHeaderSize;
    }
    const id: *const [4]u8 = data[0..4];
    const size: u32 = (@as(u32, data[4]) << 24) + (@as(u32, data[5]) << 16) + (@as(u32, data[6]) << 8) + @as(u32, data[7]);
    const flags: u16 = (@as(u16, data[8]) << 8) + @as(u16, data[9]);

    if (data.len < size + 10) {
        return ParsingError.InvalidFrameSize;
    }

    const payload = data[10..(10 + size)];

    return ID3_FRAME{ .id = id, .size = size, .flags = flags, .data = payload };
}

test "parse frames" {
    const frame_data = [13]u8{ 'C', 'O', 'M', 'M', 0, 0, 0, 0x03, 0, 0, 'e', 'n', 'g' };
    const frame = try parse_id3_frame(&frame_data);
    try std.testing.expectEqualStrings("COMM", frame.id);
    try std.testing.expectEqual(3, frame.size);
    try std.testing.expectEqual(0, frame.flags);
    try std.testing.expectEqualStrings("eng", frame.data);
}

const ID3_TAG = struct {
    header: ID3_HEADER,
    frames: std.ArrayList(ID3_FRAME),
};

fn parse_id3_tag(data: []const u8, alloc: std.mem.Allocator) ParsingError!ID3_TAG {
    const header = try parse_id3_header(data);
    var frames = std.ArrayList(ID3_FRAME).init(alloc);
    var cursor: usize = 10;
    while (cursor < header.size + 10) {
        const frame = parse_id3_frame(data[cursor..]) catch break;
        if (std.mem.eql(u8, frame.id, &ZERO_FRAME)) {
            break;
        }
        cursor += frame.size + 10;
        const frame_ptr = frames.addOne() catch return ParsingError.AllocatorError;
        frame_ptr.* = frame;
    }
    return ID3_TAG{ .header = header, .frames = frames };
}

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const files = [_][]const u8{ "./data1.mp3", "./data2.mp3", "./data3.mp3" };

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};

    var buffer = [_]u8{0} ** 800343;

    for (files) |file| {
        _ = try std.fs.cwd().readFile(file, &buffer);

        try stdout.print("Reading file {s}\n", .{file});

        const tag = try parse_id3_tag(&buffer, alloc.allocator());

        try stdout.print("Found ID3 tag \n  version :: {d}.{d}\n  size :: {d} bytes\n", .{ tag.header.major_version, tag.header.minor_version, tag.header.size });

        try stdout.print("after tag: {x}\n", .{buffer[(tag.header.size + 10)..(tag.header.size + 30)]});

        tag.frames.deinit();
    }

    try bw.flush();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
