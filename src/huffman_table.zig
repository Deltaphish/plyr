pub fn HuffmanCode(comptime value: anytype) type {
    return struct {
        code: u32,
        val: ?HuffmanValue(value),

        pub fn init(code: u32, len: u5, val: value) @This() {
            return @This(){
                .code = code,
                .val = HuffmanValue(value){ .len = len, .val = val },
            };
        }

        pub fn default() @This() {
            return @This(){
                .code = 0,
                .val = null,
            };
        }

        pub fn getValue(self: @This()) ?HuffmanValue(value) {
            return self.val;
        }
    };
}

pub fn HuffmanValue(comptime value: anytype) type {
    return struct {
        len: u5,
        val: value,
    };
}
