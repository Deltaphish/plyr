const std = @import("std");
const d_vector: DVector = @import("./d_vector.zon");

const DVector = struct {
    vector: [512]f32,
};

const Filterbank = struct {
    v: std.fifo.LinearFifo([32][18]f32, @sizeOf([32][18]f32) * 32),
};
