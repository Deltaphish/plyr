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
    expected_version: ?mp3_t.MPEG_VERSION,
    data_buffer: std.RingBuffer,

    pub fn init(data: []const u8, alloc: std.mem.Allocator) mp3_t.MP3_ERROR!DecoderState {
        if (find_sync_word(data, 0)) |offset| {
            const ring_buff = std.RingBuffer.init(alloc, 1248) catch return mp3_t.MP3_ERROR.OutOfMemory;
            return DecoderState{
                .bitstream = data,
                .cursor = offset,
                .data_buffer = ring_buff,
                .expected_version = null,
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

        //Read header
        const header = try mp3_unpack.unpack_header(self.bitstream[self.cursor..]);
        const side_info = try mp3_unpack.unpack_side_info(header, self.bitstream[(self.cursor + 4)..]);

        if (self.expected_version == null) {
            self.expected_version = header.mpeg_version;
        }

        const side_info_end = self.cursor + 4 + side_info.getSize();

        if (self.next_valid_frame(side_info_end)) |next_frame| {
            const main_data_size = next_frame.next_data_begin - side_info_end + side_info.getMainDataBegin();

            self.data_buffer.writeSlice(self.bitstream[side_info_end..next_frame.next_sync]) catch return mp3_t.MP3_ERROR.OutOfMemory;
            const buffer = alloc.alloc(u8, main_data_size) catch return mp3_t.MP3_ERROR.OutOfMemory;
            self.data_buffer.readFirst(buffer[0..], main_data_size) catch return mp3_t.MP3_ERROR.MalformedSideData;

            self.cursor = next_frame.next_sync;

            return LogicalFrame{
                .header = header,
                .side_info = side_info,
                .data = buffer,
            };
        }
        return null;
    }

    const FrameResult = struct { next_data_begin: usize, next_sync: usize };

    fn next_valid_frame(self: DecoderState, inital_offset: usize) ?FrameResult {
        var offset = inital_offset;
        while (find_sync_word(self.bitstream, offset)) |next_sync| : (offset += 2) {
            const next_header = mp3_unpack.unpack_header(self.bitstream[next_sync..]) catch {
                continue;
            };
            if (self.expected_version != null and self.expected_version != next_header.mpeg_version) {
                continue;
            }
            const next_side_info = mp3_unpack.unpack_side_info(next_header, self.bitstream[(next_sync + 4)..]) catch {
                continue;
            };
            const next_data_begin = next_sync - next_side_info.getMainDataBegin();

            return FrameResult{ .next_data_begin = next_data_begin, .next_sync = next_sync };
        }
        return null;
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
