const std = @import("std");

const bands = @import("scalefactor_table.zig");
const bt = @import("bit_reader.zig");
const huffman = @import("mp3_table.zig");
const mp3_t = @import("mp3_types.zig");
const mp3_unpack = @import("mp3_unpacker.zig");
const ring = @import("ring.zig");

pub const DecoderState = struct {
    bitstream: []const u8,
    cursor: usize,
    expected_version: ?mp3_t.MPEG_VERSION,
    main_data_fifo: ring.RingBuffer(2000),
    huffman_table: huffman.Decoder,

    pub fn init(decoder_table: huffman.Decoder, data: []const u8) mp3_t.MP3_ERROR!DecoderState {
        if (find_sync_word(data, 0)) |offset| {
            return DecoderState{
                .bitstream = data,
                .cursor = offset,
                .main_data_fifo = ring.RingBuffer(2000).init(),
                .expected_version = null,
                .huffman_table = decoder_table,
            };
        } else {
            return mp3_t.MP3_ERROR.NoSyncWordsFound;
        }
    }

    pub fn next(self: *DecoderState, dest: *?mp3_t.LogicalFrame) mp3_t.MP3_ERROR!void {
        if (self.cursor > self.bitstream.len - 2) {
            dest.* = null;
            return mp3_t.MP3_ERROR.MP3OutOfMemory;
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
            const physical_data_size = next_frame.next_sync - side_info_end;
            std.debug.print("Physical size {}\n", .{physical_data_size});
            if (physical_data_size > 960) {
                self.cursor = next_frame.next_sync;
                return mp3_t.MP3_ERROR.MalformedSideData;
            }
            self.main_data_fifo.write(self.bitstream[side_info_end..next_frame.next_sync]);

            const main_data_size = self.main_data_fifo.to_read() - next_frame.next_data_begin;
            std.debug.print("main data size {}\n", .{main_data_size});

            var buffer: [960]u8 = @splat(0);
            const read_count = self.main_data_fifo.read(buffer[0..main_data_size]);

            // Make sure that we read main_data_size, if not there was not enough data in the buffer
            if (read_count != main_data_size) {
                std.debug.print("Tried to read {} but only {} was available\n", .{ main_data_size, read_count });
            }
            std.debug.assert(read_count == main_data_size);

            self.cursor = next_frame.next_sync;

            //         const huffman_values: [575]i32 = huffman_decode(buffer[0..]);
            switch (side_info) {
                .mpeg1_stereo => |info| {
                    dest.* = mp3_t.LogicalFrame{
                        .header = header,
                        .side_info = info,
                        .data = @splat(@splat(mp3_t.DecompressedData.default)),
                    };
                    errdefer dest.* = null;

                    if (self.huffman_decode(header, info, buffer[0..], &dest.*.?.data)) |_| {
                        return;
                    } else |err| {
                        std.debug.print("Header: {}\nSideInfo: {}\n g00: {}\n g01: {}\n g10: {}\n g11: {}\n", .{
                            header,
                            side_info,
                            side_info.mpeg1_stereo.granules[0][0].big_values,
                            side_info.mpeg1_stereo.granules[0][1].big_values,
                            side_info.mpeg1_stereo.granules[1][0].big_values,
                            side_info.mpeg1_stereo.granules[1][1].big_values,
                        });
                        return err;
                    }
                },
            }
        }
        return;
    }

    fn huffman_decode(self: @This(), header: mp3_t.MP3_HEADER, side_info: mp3_t.SideInfoMpeg1Stereo, bits: []u8, dest: *[2][2]mp3_t.DecompressedData) mp3_t.MP3_ERROR!void {
        var reader = bt.BitReader.init_with_limit(bits, 0);

        for (0..2) |gr| {
            for (0..2) |ch| {
                const info = side_info.granules[gr][ch];
                const scalefac_size = scalefac_compress_table[info.scalefac_compress];
                const bits_to_read = info.part2_3_length;
                if (bits_to_read == 0) {
                    //Nothing to do here...
                    continue;
                }

                var regionSize: [2]u32 = @splat(0);

                reader.inc_limit(bits_to_read);

                var table_select: [3]u8 = @splat(0);
                switch (info.block_info) {
                    .long_block => |block| {
                        table_select[0] = block.table_select[0];
                        table_select[1] = block.table_select[1];
                        table_select[2] = block.table_select[2];

                        if (@max(table_select[0], table_select[1], table_select[2]) > 40) {
                            //Invalid table_select
                            return;
                        }

                        regionSize[0] = @min(info.big_values, bands.scalefactor_table.getBandSize(
                            header.freq,
                            true,
                            block.region0_count,
                        ) / 2);
                        regionSize[1] = @min(info.big_values, bands.scalefactor_table.getBandSize(
                            header.freq,
                            true,
                            block.region1_count,
                        ) / 2);

                        if (!side_info.scfsi[ch][0] or gr == 0) {
                            for (0..6) |sfb| {
                                dest[gr][ch].scalefac_l[sfb] = @truncate(reader.readBits(scalefac_size.slen1) orelse return mp3_t.MP3_ERROR.MalformedData);
                            }
                        }
                        if (!side_info.scfsi[ch][1] or gr == 0) {
                            for (6..11) |sfb| {
                                dest[gr][ch].scalefac_l[sfb] = @truncate(reader.readBits(scalefac_size.slen1) orelse return mp3_t.MP3_ERROR.MalformedData);
                            }
                        }
                        if (!side_info.scfsi[ch][2] or gr == 0) {
                            for (11..16) |sfb| {
                                dest[gr][ch].scalefac_l[sfb] = @truncate(reader.readBits(scalefac_size.slen2) orelse return mp3_t.MP3_ERROR.MalformedData);
                            }
                        }
                        if (!side_info.scfsi[ch][3] or gr == 0) {
                            for (16..21) |sfb| {
                                dest[gr][ch].scalefac_l[sfb] = @truncate(reader.readBits(scalefac_size.slen2) orelse return mp3_t.MP3_ERROR.MalformedData);
                            }
                        }
                    },
                    .windowed_block => |block| {
                        table_select[0] = block.table_select[0];
                        table_select[1] = block.table_select[1];
                        table_select[2] = 0;
                        if (@max(table_select[0], table_select[1], table_select[2]) > 40) {
                            //Invalid table_select
                            return;
                        }
                        if (block.mixed_block_flag) {
                            regionSize[0] = @min(info.big_values, bands.scalefactor_table.getBandSize(
                                header.freq,
                                false,
                                7,
                            ) / 2);
                            regionSize[1] = info.big_values - regionSize[0];

                            for (0..8) |sfb| {
                                dest[gr][ch].scalefac_l[sfb] = @truncate(reader.readBits(scalefac_size.slen1) orelse return mp3_t.MP3_ERROR.MalformedData);
                            }
                            for (3..6) |sfb| {
                                for (0..3) |window| {
                                    dest[gr][ch].scalefac_s[sfb][window] = @truncate(reader.readBits(scalefac_size.slen1) orelse return mp3_t.MP3_ERROR.MalformedData);
                                }
                            }
                            for (6..12) |sfb| {
                                for (0..3) |window| {
                                    dest[gr][ch].scalefac_s[sfb][window] = @truncate(reader.readBits(scalefac_size.slen2) orelse return mp3_t.MP3_ERROR.MalformedData);
                                }
                            }
                        } else {
                            regionSize[0] = @min(info.big_values, bands.scalefactor_table.getBandSize(
                                header.freq,
                                false,
                                8,
                            ) / 2);
                            regionSize[1] = info.big_values - regionSize[0];
                            for (0..6) |sfb| {
                                for (0..3) |window| {
                                    dest[gr][ch].scalefac_s[sfb][window] = @truncate(reader.readBits(scalefac_size.slen1) orelse return mp3_t.MP3_ERROR.MalformedData);
                                }
                            }
                            for (6..12) |sfb| {
                                for (0..3) |window| {
                                    dest[gr][ch].scalefac_s[sfb][window] = @truncate(reader.readBits(scalefac_size.slen2) orelse return mp3_t.MP3_ERROR.MalformedData);
                                }
                            }
                        }
                    },
                }
                _ = self.huffman_table.huffman_decode(&reader, table_select, info.count1table_select, info.big_values, regionSize, dest[gr][ch].data[0..576]);
            }
        }
    }

    const Scalefac_Size = struct {
        slen1: u8,
        slen2: u8,
    };

    const scalefac_compress_table = [16]Scalefac_Size{
        Scalefac_Size{ .slen1 = 0, .slen2 = 0 },
        Scalefac_Size{ .slen1 = 0, .slen2 = 1 },
        Scalefac_Size{ .slen1 = 0, .slen2 = 2 },
        Scalefac_Size{ .slen1 = 0, .slen2 = 3 },
        Scalefac_Size{ .slen1 = 3, .slen2 = 0 },
        Scalefac_Size{ .slen1 = 1, .slen2 = 1 },
        Scalefac_Size{ .slen1 = 1, .slen2 = 2 },
        Scalefac_Size{ .slen1 = 1, .slen2 = 3 },
        Scalefac_Size{ .slen1 = 2, .slen2 = 1 },
        Scalefac_Size{ .slen1 = 2, .slen2 = 2 },
        Scalefac_Size{ .slen1 = 2, .slen2 = 3 },
        Scalefac_Size{ .slen1 = 3, .slen2 = 1 },
        Scalefac_Size{ .slen1 = 3, .slen2 = 2 },
        Scalefac_Size{ .slen1 = 3, .slen2 = 3 },
        Scalefac_Size{ .slen1 = 4, .slen2 = 2 },
        Scalefac_Size{ .slen1 = 4, .slen2 = 3 },
    };

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

            return FrameResult{ .next_data_begin = next_side_info.getMainDataBegin(), .next_sync = next_sync };
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
