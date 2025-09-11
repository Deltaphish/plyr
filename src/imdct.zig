const mp3_t = @import("./mp3_types.zig");
const math = @import("std").math;
const std = @import("std");

const SampledFrame = struct {
    header: mp3_t.MP3_HEADER,
    side_info: mp3_t.SideInfoMpeg1Stereo,
    data: [2][2][32][18]f32,
    rest: [2][32][18]f32,
};

pub fn convertToSamples(maybePreviousRest: ?[2][32][18]f32, frame: mp3_t.RequantizedFrame) SampledFrame {
    var res = SampledFrame{
        .header = frame.header,
        .side_info = frame.side_info,
        .data = @splat(@splat(@splat(@splat(0.0)))),
        .rest = @splat(@splat(@splat(0.0))),
    };

    var buffer: [2][2][32][36]f32 = @splat(@splat(@splat(@splat(0.0))));

    for (0..2) |gr| {
        for (0..2) |ch| {
            switch (frame.side_info.granules[gr][ch].block_info) {
                .long_block => {
                    buffer[gr][ch] = IMDCT_long(frame.data[gr][ch]);
                },
                .windowed_block => |blck| {
                    switch (blck.block_type) {
                        1 => {
                            buffer[gr][ch] = IMDCT_start(frame.data[gr][ch]);
                        },
                        2 => {
                            buffer[gr][ch] = IMDCT_short(frame.data[gr][ch]);
                        },
                        3 => {
                            buffer[gr][ch] = IMDCT_stop(frame.data[gr][ch]);
                        },
                        else => unreachable,
                    }
                },
            }
        }
    }

    //TODO: refactor out to caller?
    if (maybePreviousRest) |previous| {
        for (0..2) |ch| {
            for (0..32) |subband| {
                const addOp1 = add(buffer[0][ch][subband], previous[ch][subband]);
                res.data[0][ch][subband] = addOp1.result;
                const addOp2 = add(buffer[1][ch][subband], addOp1.rest);
                res.data[1][ch][subband] = addOp2.result;
                res.rest[ch][subband] = addOp2.rest;
            }
        }
    } else {
        for (0..2) |ch| {
            for (0..32) |subband| {
                var temp: [18]f32 = [_]f32{undefined} ** 18;
                @memcpy(temp[0..], buffer[0][ch][subband][18..]);
                const addOp = add(buffer[1][ch][subband], temp);
                res.data[1][ch][subband] = addOp.result;
                res.rest[ch][subband] = addOp.rest;
            }
        }
    }

    return res;
}

const AddResult = struct {
    result: [18]f32,
    rest: [18]f32,
};

fn add(input: [36]f32, saved: [18]f32) AddResult {
    var out = AddResult{
        .result = @splat(0.0),
        .rest = @splat(0.0),
    };
    for (0..18) |i| {
        out.result[i] = input[i] + saved[i];
    }
    std.mem.copyForwards(f32, out.rest[0..], input[18..]);
    return out;
}

fn shortWindow(i: f32) f32 {
    return math.sin((math.pi / 12.0) * (i + 1 / 2));
}

fn startWindow(i: usize) f32 {
    return switch (i) {
        0...17 => math.sin(math.pi / 36.0 * (@as(f32, @floatFromInt(i)) + 1.0 / 2.0)),
        18...23 => 1.0,
        24...29 => math.sin(math.pi / 12.0 * (@as(f32, @floatFromInt(i)) - 18 + 1 / 2)),
        30...35 => 0.0,
        else => unreachable,
    };
}

fn stopWindow(i: usize) f32 {
    return switch (i) {
        30...35 => 0.0,
        24...29 => math.sin(math.pi / 12.0 * (@as(f32, @floatFromInt(i)) - 6 + 1 / 2)),
        18...23 => 1.0,
        0...17 => math.sin(math.pi / 36.0 * (@as(f32, @floatFromInt(i)) + 1 / 2)),
        else => unreachable,
    };
}

fn longWindow(i: f32) f32 {
    return math.sin((math.pi / 36.0) * (i + 1 / 2));
}

fn IMDCT_short(data: [576]f32) [32][36]f32 {
    var res: [32][36]f32 = @splat(@splat(0.0));

    var chunks = [3][32][12]f32{
        IMDCT(12, data[0..192]),
        IMDCT(12, data[192..384]),
        IMDCT(12, data[384..]),
    };

    for (0..3) |block| {
        for (0..32) |band| {
            for (0..12) |i| {
                chunks[block][band][i] *= shortWindow(@floatFromInt(i));
            }
        }
    }

    for (0..32) |band| {
        for (0..36) |sample| {
            res[band][sample] = switch (sample) {
                0...5 => 0,
                6...11 => chunks[0][band][sample - 6],
                12...17 => chunks[0][band][sample - 6] + chunks[1][band][sample - 12],
                18...23 => chunks[1][band][sample - 12] + chunks[2][band][sample - 18],
                24...29 => chunks[2][band][sample - 18],
                30...35 => 0,
                else => unreachable,
            };
        }
    }
    return res;
}

fn IMDCT_long(data: [576]f32) [32][36]f32 {
    var res = IMDCT(36, &data);
    for (0..32) |band| {
        for (0..36) |i| {
            res[band][i] *= longWindow(@floatFromInt(i));
        }
    }
    return res;
}

fn IMDCT_start(data: [576]f32) [32][36]f32 {
    var res = IMDCT(36, &data);
    for (0..32) |band| {
        for (0..36) |i| {
            res[band][i] *= startWindow(i);
        }
    }
    return res;
}

fn IMDCT_stop(data: [576]f32) [32][36]f32 {
    var res = IMDCT(36, &data);
    for (0..32) |band| {
        for (0..36) |i| {
            res[band][i] *= stopWindow(i);
        }
    }
    return res;
}

fn IMDCT(N: comptime_int, data: *const [32 * ((N / 2))]f32) [32][N]f32 {
    var res: [32][N]f32 = @splat(@splat(0.0));
    for (0..32) |subband| {
        for (0..N) |i| {
            var sum: f32 = 0.0;
            for (0..((N / 2) - 1)) |k| {
                const xk = data[subband * ((N / 2) - 1) + k];
                sum += xk * math.cos(math.pi / (2.0 * @as(f32, @floatFromInt(N))) * (2.0 * @as(f32, @floatFromInt(i)) + 1.0 + @as(f32, @floatFromInt(N)) / 2.0) * (2 * @as(f32, @floatFromInt(k)) + 1));
            }
            res[subband][i] = sum;
        }
    }
    return res;
}
