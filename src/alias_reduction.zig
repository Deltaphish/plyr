const mp3_t = @import("mp3_types.zig");
pub fn alias_reduction(reqFrame: *mp3_t.RequantizedFrame) void {
    for (0..2) |gr| {
        for (0..2) |ch| {
            const info = reqFrame.side_info.granules[gr][ch];
            switch (info.block_info) {
                .long_block => {
                    for (1..32) |sb| {
                        for (0..8) |i| {
                            const a = reqFrame.data[gr][ch][18 * sb - 1 - i] * CS[i] - reqFrame.data[gr][ch][18 * sb + i] * CA[i];
                            reqFrame.data[gr][ch][18 * sb + i] = reqFrame.data[gr][ch][18 * sb + i] * CS[i] + reqFrame.data[gr][ch][18 * sb - 1 - i] * CA[i];
                            reqFrame.data[gr][ch][18 * sb - 1 - i] = a;
                        }
                    }
                },
                .windowed_block => |block| {
                    if (block.mixed_block_flag) {
                        for (1..3) |sb| {
                            for (0..8) |i| {
                                const a = reqFrame.data[gr][ch][18 * sb - 1 - i] * CS[i] - reqFrame.data[gr][ch][18 * sb + i] * CA[i];
                                reqFrame.data[gr][ch][18 * sb + i] = reqFrame.data[gr][ch][18 * sb + i] * CS[i] + reqFrame.data[gr][ch][18 * sb - 1 - i] * CA[i];
                                reqFrame.data[gr][ch][18 * sb - 1 - i] = a;
                            }
                        }
                    }
                },
            }
        }
    }
}

// c = [-0.6,-0.535,-0.33,-0.185, -0.095, -0.041, -0.0142, -0.0037]
// [1/math.sqrt(1 + ci**2) for ci in c]
const CS = [8]f32{
    0.8574929257125443,
    0.8817419973177052,
    0.9496286491027328,
    0.9833145924917902,
    0.9955178160675858,
    0.9991605581781475,
    0.9998991952444471,
    0.9999931550702803,
};

// [ci/math.sqrt(1+ci**2) for ci in c]
const CA = [8]f32{
    -0.5144957554275266,
    -0.47173196856497235,
    -0.31337745420390184,
    -0.18191319961098118,
    -0.09457419252642066,
    -0.04096558288530405,
    -0.01419856857247115,
    -0.0036999746737600373,
};
