const mp3_t = @import("mp3_types.zig");
const bands = @import("scalefactor_table.zig");
const std = @import("std");

pub fn requantize(frame: mp3_t.LogicalFrame) mp3_t.RequantizedFrame {
    var result = mp3_t.RequantizedFrame{
        .header = frame.header,
        .side_info = frame.side_info,
        .data = @splat(@splat(@splat(0.0))),
    };

    for (0..2) |gr| {
        for (0..2) |ch| {
            const info = result.side_info.granules[gr][ch];
            const decodedData: mp3_t.DecompressedData = frame.data[gr][ch];
            switch (info.block_info) {
                .long_block => |_| {
                    for (0..576) |ix| {
                        const i: u32 = @intCast(ix);
                        const sb = getScaleBand(true, result.header.freq, i);
                        const is: f32 = @floatFromInt(decodedData.data[i]);
                        const c = gamma(info.global_gain);
                        const d = delta(@intFromBool(info.scalefac_scale), decodedData.scalefac_l[sb], @intFromBool(info.preflag), PRETAB[sb]); //TODO: Check index for out of bounds
                        result.data[gr][ch][i] = std.math.sign(is) * std.math.pow(f32, @abs(is), 4.0 / 3.0);
                        result.data[gr][ch][i] *= std.math.pow(f32, 2.0, c);
                        result.data[gr][ch][i] *= std.math.pow(f32, 2.0, d);
                    }
                },
                .windowed_block => |block| {
                    if (block.mixed_block_flag) {
                        switch (block.block_type) {
                            0b01 => { // Start window
                                for (0..576) |ix| {
                                    const i: u32 = @intCast(ix);
                                    const sb = getScaleBand(true, result.header.freq, i);
                                    const is: f32 = @floatFromInt(decodedData.data[i]);
                                    const c = gamma(info.global_gain);
                                    const d = delta(@intFromBool(info.scalefac_scale), decodedData.scalefac_l[sb], @intFromBool(info.preflag), PRETAB[sb]); //TODO: Check index for out of bounds
                                    result.data[gr][ch][i] = std.math.sign(is) * std.math.pow(f32, @abs(is), 4.0 / 3.0);
                                    result.data[gr][ch][i] *= std.math.pow(f32, 2.0, c);
                                    result.data[gr][ch][i] *= std.math.pow(f32, 2.0, d);
                                }
                            },
                            0b10 => { // Stop window
                                for (0..576) |ix| {
                                    const i: u32 = @intCast(ix);
                                    const sb = getScaleBand(true, result.header.freq, i);
                                    const is: f32 = @floatFromInt(decodedData.data[i]);
                                    const c = gamma(info.global_gain);
                                    const d = delta(@intFromBool(info.scalefac_scale), decodedData.scalefac_l[sb], @intFromBool(info.preflag), PRETAB[sb]); //TODO: Check index for out of bounds
                                    result.data[gr][ch][i] = std.math.sign(is) * std.math.pow(f32, @abs(is), 4.0 / 3.0);
                                    result.data[gr][ch][i] *= std.math.pow(f32, 2.0, c);
                                    result.data[gr][ch][i] *= std.math.pow(f32, 2.0, d);
                                }
                            },
                            0b11 => { // 3 short windows
                                var i: u32 = 0;
                                while (i < 576) : (i += 1) {
                                    const sb = getScaleBand(true, result.header.freq, i);
                                    if (sb > 7) {
                                        break;
                                    }
                                    const is: f32 = @floatFromInt(decodedData.data[i]);
                                    const c = gamma(info.global_gain);
                                    const d = delta(@intFromBool(info.scalefac_scale), decodedData.scalefac_l[sb], @intFromBool(info.preflag), PRETAB[sb]); //TODO: Check index for out of bounds
                                    result.data[gr][ch][i] = std.math.sign(is) * std.math.pow(f32, @abs(is), 4.0 / 3.0);
                                    result.data[gr][ch][i] *= std.math.pow(f32, 2.0, c);
                                    result.data[gr][ch][i] *= std.math.pow(f32, 2.0, d);
                                }
                                while (i < 576) : (i += 1) {
                                    const window, const sb = bands.scalefactor_table.getBandAndWindowByPosition(result.header.freq, i);
                                    // Short block covers 3-12
                                    std.debug.assert(sb >= 3);
                                    const is: f32 = @floatFromInt(decodedData.data[i]);
                                    const a = alpha(info.global_gain, block.subblock_gain[window]);
                                    const b = beta(@intFromBool(info.scalefac_scale), decodedData.scalefac_s[sb][window]);
                                    result.data[gr][ch][i] = std.math.sign(is) * std.math.pow(f32, @abs(is), 4.0 / 3.0);
                                    result.data[gr][ch][i] *= std.math.pow(f32, 2.0, a);
                                    result.data[gr][ch][i] *= std.math.pow(f32, 2.0, b);
                                }
                            },
                            0 => {
                                continue;
                            },
                        }
                    } else {
                        for (0..576) |ix| {
                            const i: u32 = @intCast(ix);
                            const window, const sb = bands.scalefactor_table.getBandAndWindowByPosition(result.header.freq, i);
                            const is: f32 = @floatFromInt(decodedData.data[i]);
                            const a = alpha(info.global_gain, block.subblock_gain[window]);
                            const b = beta(@intFromBool(info.scalefac_scale), decodedData.scalefac_s[sb][window]);
                            result.data[gr][ch][i] = std.math.sign(is) * std.math.pow(f32, @abs(is), 4.0 / 3.0);
                            result.data[gr][ch][i] *= std.math.pow(f32, 2.0, a);
                            result.data[gr][ch][i] *= std.math.pow(f32, 2.0, b);
                        }
                    }
                },
            }
        }
    }
    return result;
}

fn getScaleBand(isLong: bool, freq: u32, pos: u32) u32 {
    return bands.scalefactor_table.getBandByPosition(isLong, freq, pos);
}

fn alpha(global_gain: u32, subblock_gain: u32) f32 {
    return 0.25 * (@as(f32, @floatFromInt(global_gain)) - 210.0 - 8.0 * @as(f32, @floatFromInt(subblock_gain)));
}

fn beta(scalefac_multiplier: u32, scale_fac: u32) f32 {
    return -1.0 * (@as(f32, @floatFromInt(scalefac_multiplier)) * @as(f32, @floatFromInt(scale_fac)));
}

fn gamma(global_gain: u32) f32 {
    return 0.25 * (@as(f32, @floatFromInt(global_gain)) - 210.0);
}

fn delta(scalefac_multiplier: u32, scalefac_l: u32, preflag: u32, pretab: u32) f32 {
    return -1.0 * (@as(f32, @floatFromInt(scalefac_multiplier))) * @as(f32, @floatFromInt(scalefac_l + preflag * pretab));
}

const PRETAB = [21]u3{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2,
};
