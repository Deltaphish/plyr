pub const MP3_FRAME = struct {
    header: MP3_HEADER,
    sideInfo: MP3_SIDE_INFO,
};

pub const MP3_ERROR = error{
    InvalidHeader,
    UnsupportedFormat,
    UnsupportedSamplingRate,
    InvalidBitrate,
    InvalidMPEGVersion,
    OutOfMemory,
    MalformedSideData,
    NoSyncWordsFound,
};

pub const MP3_HEADER = struct {
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
        return (144 * (self.bit_rate / self.freq)) + @as(usize, @intFromBool(self.padding));
    }
};

pub const MP3_SIDE_INFO_TYPE = enum {
    mpeg1_stereo,

    pub fn jsonStringify(self: MP3_SIDE_INFO_TYPE, output: anytype) !void {
        switch (self) {
            .mpeg1_stereo => |block| {
                try output.print("\"mpeg1_stereo\":{}", .{block});
                return;
            },
        }
    }
};

pub const MP3_SIDE_INFO = union(MP3_SIDE_INFO_TYPE) {
    mpeg1_stereo: MP3_DATA_MPEG1_STEREO,

    pub fn getSize(self: MP3_SIDE_INFO) usize {
        switch (self) {
            .mpeg1_stereo => {
                return @bitSizeOf(MP3_DATA_MPEG1_STEREO);
            },
        }
    }

    pub fn getMainDataBegin(self: MP3_SIDE_INFO) usize {
        switch (self) {
            .mpeg1_stereo => |*data| {
                return @intCast(data.main_data_begin);
            },
        }
    }
};

pub const MP3_DATA_MPEG1_STEREO = struct {
    main_data_begin: u9,
    private_bits: u5,
    scfsi: [2][4]bool,
    granules: [2][2]MP3_GRANULE_MPEG1,
};

pub const MP3_GRANULE_MPEG1 = struct {
    part2_3_length: u12,
    big_values: u9,
    global_gain: u8,
    scalefac_compress: u4,
    block_data: MP3_BLOCK,
    preflag: bool,
    scalefac_scale: bool,
    count1table_select: bool,
};

pub const MP3_BLOCK_TYPE = enum {
    long_block,
    constelation_block,
};

pub const MP3_BLOCK = union(enum) {
    long_block: MP3_LONG_BLOCK,
    constelation_block: MP3_CONSTELATION_BLOCK,

    pub fn jsonStringify(self: MP3_BLOCK, output: anytype) !void {
        switch (self) {
            .long_block => |block| {
                try output.write(.{ .type = "long_block", .data = block });
                return;
            },
            .constelation_block => |block| {
                try output.write(.{ .type = "constelation_block", .data = block });
                //try output.print("\"constelation\":{}", .{block});
                return;
            },
        }
    }
};

pub const MP3_LONG_BLOCK = struct {
    table_select: [3]u5,
    region0_count: u4,
    region1_count: u3,
};

pub const MP3_CONSTELATION_BLOCK = struct {
    block_type: u2,
    mixed_block_flag: bool,
    table_select: [2]u5,
    subblock_gain: [3]u3,
};

pub const CHANNEL_MODE = enum {
    STEREO,
    JOINT,
    DUAL,
    MONO,
};

const MPEG_LAYER = enum {
    LAYER_3,
    LAYER_2,
    LAYER_1,
};

pub const MPEG_VERSION = enum {
    MPEG_25,
    MPEG_2,
    MPEG_1,
};
