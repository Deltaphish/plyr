const std = @import("std");
const d_vector: DVector = @import("./d_vector.zon");

const ringBuffer = @import("./ring.zig");

const DVector = struct {
    vector: [512]f32,
};

const Filterbank = struct {
    v: ringBuffer.RingBuffer([32]f32, 32),

    fn getU(self: *const Filterbank) [512]f32 {
        var buffer: [16][64]f32 = @splat(@splat(0.0));
        var result: [512]f32 = @splat(0.0);
        const items = self.v.read(&buffer[0..]);
        self.v.unget(buffer);
        for (0..items) |i| {
            if (i % 2 == 0) {
                @memcpy(result[i * 32 ..], buffer[i][0..32]);
            } else {
                @memcpy(result[i * 32 ..], buffer[i][32..]);
            }
        }
        return result;
    }
};

fn sum_vector(v: *const [512]f32) [32]f32 {
    var res: [32]f32 = @splat(0.0);
    for (0..16) |i| {
        for (0..32) |j| {
            res[j] += v[i * 32 + j];
        }
    }
    return res;
}

fn applyD(v: *[512]f32) void {
    for (0..512) |i| {
        v[i] *= d_vector.vector[i];
    }
}

fn matrix(samples: *const [32]f32) [64]f32 {
    var vout: [64]f32 = @splat(0.0);
    for (0..64) |i| {
        for (0..32) |k| {
            vout[i] += N(i, k) * samples[k];
        }
    }
    return vout;
}

fn N(i: f32, k: f32) f32 {
    return std.math.cos((16.0 + i) * (2.0 * k + i) * (std.math.pi / 64.0));
}
