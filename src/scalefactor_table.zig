const bands_data: Payload = @import("scalefactor_bands.zon");
const std = @import("std");

pub const scalefactor_table = ScalefactorTable.init();

const ScalefactorTable = struct {
    long_table: [16][21]Band,
    short_table: [16][12]Band,
    pub fn init() ScalefactorTable {
        var self = ScalefactorTable{
            .long_table = @splat(@splat(Band.default)),
            .short_table = @splat(@splat(Band.default)),
        };

        for (bands_data.long_tables) |table| {
            std.mem.copyForwards(Band, self.long_table[hash(table.freq)][0..], table.bands[0..]);
        }
        for (bands_data.short_tables) |table| {
            std.mem.copyForwards(Band, self.short_table[hash(table.freq)][0..], table.bands[0..]);
        }
        return self;
    }

    pub fn getBandByPosition(self: ScalefactorTable, is_long: bool, freq: u32, pos: u32) u32 {
        if (is_long) {
            for (self.long_table[hash(freq)]) |row| {
                if (pos <= row.end) {
                    return row.band;
                }
            }
            unreachable;
        } else {
            for (self.short_table[hash(freq)]) |row| {
                if (pos <= row.end) {
                    return row.band;
                }
            }
        }
        return 0;
    }

    pub fn getBandSize(self: ScalefactorTable, freq: u32, is_long: bool, subband_count: u8) u32 {
        if (subband_count == 0) {
            return 0;
        }
        if (is_long) {
            return self.long_table[hash(freq)][subband_count - 1].end;
        } else {
            return self.short_table[hash(freq)][subband_count - 1].end;
        }
    }

    // "Perfect hash", maps valid frequencies into 0..16 bitspace.
    fn hash(freq: u32) u8 {
        return @truncate((freq % 23) - 7);
    }
};

const Payload = struct {
    long_tables: [9]LongBandTable,
    short_tables: [9]ShortBandTable,
};

const LongBandTable = struct {
    freq: u32,
    isLong: bool,
    bands: [21]Band,
};

const ShortBandTable = struct {
    freq: u32,
    isLong: bool,
    bands: [12]Band,
};

const Band = struct {
    band: u8,
    width: u16,
    start: u16,
    end: u16,
    const default: Band = Band{ .band = 0, .width = 0, .start = 0, .end = 0 };
};

test "parse" {
    const data: Payload = @import("scalefactor_bands.zon");
    try std.testing.expect(data.long_tables[0].freq == 8000);
}
