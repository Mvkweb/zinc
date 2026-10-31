const builtin = @import("builtin");

const glibc = if (builtin.os.tag == .linux and builtin.abi.isGnu())
    struct {
        extern "c" fn malloc_trim(pad: usize) c_int;
    }
else
    struct {};

pub fn trimMemory() void {
    if (builtin.os.tag == .linux and builtin.abi.isGnu()) {
        _ = glibc.malloc_trim(0);
    }
}
