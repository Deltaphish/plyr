const std = @import("std");

const mp3_t = @import("mp3_types.zig");
const mp3_unpack = @import("mp3_unpacker.zig");

pub const LogicalFrame = struct {
    header: mp3_t.MP3_HEADER,
    side_info: mp3_t.MP3_SIDE_INFO,
    data: []u8,
};

pub const DecoderState = struct {
    bitstream: []const u8,
    cursor: usize,
    data_buffer: std.RingBuffer,

    pub fn init(data: []const u8, alloc: std.mem.Allocator) mp3_t.MP3_ERROR!DecoderState {
        if (find_sync_word(data, 0)) |offset| {
            const ring_buff = std.RingBuffer.init(alloc, 1248) catch return mp3_t.MP3_ERROR.OutOfMemory;
            return DecoderState{
                .bitstream = data,
                .cursor = offset,
                .data_buffer = ring_buff,
            };
        } else {
            return mp3_t.MP3_ERROR.NoSyncWordsFound;
        }
    }

    pub fn next(self: *DecoderState, alloc: std.mem.Allocator) mp3_t.MP3_ERROR!?LogicalFrame {
        if (self.cursor > self.bitstream.len - 2) {
            return null;
        }
        //Cursor is at syncword
        std.debug.assert(self.bitstream[self.cursor] == 0xFF);
        std.debug.assert(self.bitstream[self.cursor + 1] & 0xE0 == 0xE0);

        const header = try mp3_unpack.unpack_header(self.bitstream[self.cursor..]);
        const side_info = try mp3_unpack.unpack_side_info(header, self.bitstream[(self.cursor + 4)..]);

        var back_pointer: usize = 0;
        const side_info_size = side_info.getSize();
        var main_data_size: usize = self.bitstream.len - 1;
        var next_frame: usize = self.bitstream.len;

        switch (side_info) {
            .mpeg1_stereo => |info| {
                back_pointer = @intCast(info.main_data_begin);
            },
        }

        const side_info_end = self.cursor + 4 + side_info_size;

        if (find_sync_word(self.bitstream, self.cursor + 4 + side_info_size)) |offset| {
            const next_header = mp3_unpack.unpack_header(self.bitstream[offset..]) catch {
                std.debug.print("{}\n", .{offset});
                return mp3_t.MP3_ERROR.InvalidHeader;
            };
            const next_side_info = mp3_unpack.unpack_side_info(next_header, self.bitstream[(offset + 4)..]) catch {
                mp3_unpack.debug_header(next_header, std.io.getStdErr().writer().any());
                std.debug.print("{}\n", .{offset});
                return mp3_t.MP3_ERROR.InvalidHeader;
            };
            const mde = next_side_info.getMainDataBegin();
            next_frame = offset;
            main_data_size = (offset - mde) - (self.cursor - side_info.getMainDataBegin()) - 4 - side_info_size;
        }

        self.data_buffer.writeSlice(self.bitstream[(side_info_end)..next_frame]) catch return mp3_t.MP3_ERROR.OutOfMemory;

        const buffer = alloc.alloc(u8, main_data_size) catch return mp3_t.MP3_ERROR.OutOfMemory;
        self.data_buffer.readFirst(buffer[0..], main_data_size) catch return mp3_t.MP3_ERROR.MalformedSideData;

        self.cursor = next_frame;

        return LogicalFrame{
            .header = header,
            .side_info = side_info,
            .data = buffer,
        };
    }
};

fn find_sync_word(data: []const u8, inital_offset: usize) ?usize {
    var offset: usize = inital_offset;
    while (std.mem.indexOfPos(u8, data, offset, &[_]u8{0xff})) |pos| {
        if (valid_header(data[pos..])) {
            return pos;
        } else {
            offset += 2;
            continue;
        }
    }
    return null;
}

fn valid_header(data: []const u8) bool {
    const valid_syncword = data[1] & 0xE0 == 0xE0;
    const valid_id = data[1] & 0x18 != 0x8;
    const valid_layer = data[1] & 0x6 == 0x2;
    const valid_bitrate = data[2] & 0xF0 != 0xF0;
    const valid_hz = data[2] & 0xC != 0xC;

    return valid_syncword and valid_id and valid_layer and valid_bitrate and valid_hz;
}

pub fn getAllSyncWords(data: []const u8, alloc: std.mem.Allocator) !std.ArrayList(usize) {
    var syncWords = std.ArrayList(usize).init(alloc);
    var lastSyncWord: usize = 0;

    // Scout for the packages
    const firstSyncWord = find_sync_word(data, 0);
    if (firstSyncWord == null) {
        return mp3_t.MP3_ERROR.NoSyncWordsFound;
    }
    const firstHeader = try mp3_unpack.unpack_header(data[firstSyncWord.?..]);
    const frame_size = firstHeader.frame_size();

    while (std.mem.indexOfPos(u8, data, lastSyncWord, &[_]u8{0xff})) |pos| {
        if (data[pos + 1] & 0xE0 == 0xE0) {
            const newSyncWord = try syncWords.addOne();
            newSyncWord.* = pos;
            lastSyncWord = pos + frame_size;
        } else {
            lastSyncWord = pos + 1;
        }
    }
    return syncWords;
}

pub fn parse_frames(data: []const u8, alloc: std.mem.Allocator) mp3_t.MP3_ERROR!std.ArrayList(mp3_t.MP3_FRAME) {
    var frames = std.ArrayList(mp3_t.MP3_FRAME).init(alloc);
    const syncWords = try getAllSyncWords(data, alloc);
    for (syncWords.items) |syncWord| {
        const header = mp3_unpack.unpack_header(data[syncWord..]) catch continue;
        const sideInfo = mp3_unpack.unpack_side_info(header, data[syncWord + 4 ..]) catch continue;

        const newFrame = try frames.addOne();
        newFrame.* = mp3_t.MP3_FRAME{ .header = header, .sideInfo = sideInfo };
    }
    return frames;
}
