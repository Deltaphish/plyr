const mp3_t = @import("mp3_types.zig");
const bands = @import("scalefactor_table.zig");
const std = @import("std");

pub fn requantize(frame: mp3_t.LogicalFrame) mp3_t.RequantizedFrame {
    var result = mp3_t.RequantizedFrame{
        .header = frame.header,
        .side_info = frame.side_info,
    };

    for (0..2) |gr| {
        for (0..2) |ch| {
            const info = result.side_info.granules[gr][ch];
            const decodedData: mp3_t.DecompressedData = frame.data[gr][ch];
            switch (info.block_info) {
                .long_block => |block| {
                    for (0..576) |i| {
                        const sb = getScaleBand(true, result.header.freq,i);
                        const is = decodedData.data[i];
                        const c = gamma(info.global_gain);
                        const d = delta(info.scalefac_scale, decodedData.scalefac_l[sb]);
                        result.data[gr][ch][i] = std.math.sign(is) * std.math.pow(@abs(is), 4.0/3.0);
                        result.data[gr][ch][i] *= std.math.pow(2.0, c);
                        result.data[gr][ch][i] *= std.math.pow(2.0, d);
                    }
                },
                .windowed_block => |block| {
                    if(block.mixed_block_flag){
                        @panic("Todo");
                    } else {
                        for (0..576) |i| {
                            const sb = getScaleBand(true, result.header.freq,i);
                            const is = decodedData.data[i];
                            const c = gamma(info.global_gain);
                            const d = delta(info.scalefac_scale, decodedData.scalefac_l[sb]);
                            result.data[gr][ch][i] = std.math.sign(is) * std.math.pow(@abs(is), 4.0/3.0);
                            result.data[gr][ch][i] *= std.math.pow(2.0, c);
                            result.data[gr][ch][i] *= std.math.pow(2.0, d);
                        }
                    }
                },
            }
        }
    }
}

fn getScaleBand(isLong: bool, freq: u32, pos: u32) {
    return bands.scalefactor_table.getBandByPosition( is_long, freq, pos)
}

fn alpha(global_gain: u32, subblock_gain: u32) f32 {
    return 0.25 * @as(f32, @floatFromInt(global_gain)) - 210.0 - 8.0 * @as(f32, @floatFromInt(subblock_gain));
}

fn beta(scalefac_multiplier: u32, scale_fac: u32) f32 {
    return -1.0 * (@as(f32, @floatFromInt(scalefac_multiplier)) - *@as(f32, @floatFromInt(scale_fac)));
}

fn gamma(global_gain: u32) f32 {
    0.25 * (@as(f32, @floatFromInt(global_gain)) - 210.0);
}

fn delta(scalefac_multiplier: u32, scalefac_l: u32, preflag: u32, pretab: u32) f32 {
    -1.0 * (@as(f32, @floatFromInt(scalefac_multiplier))) * @as(f32, @floatFromInt(scalefac_l + preflag * pretab));
}
