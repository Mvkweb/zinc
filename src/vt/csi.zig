//! CSI dispatch table: maps final byte + params to terminal ops.
//! Full list mirrors sfte csi.zig coverage (ICH/CUU/CUD/CUF/CUB/CNL/CPL/
//! CHA/CUP/ED/EL/IL/DL/DCH/SU/SD/ECH/DA/VPA/HVP/TBC/SM/RM/SGR/DSR/DECSTR/
//! DECSCUSR/DECSTBM/SCOSC/XTWINOPS/kitty-kb).

const std = @import("std");

pub const Final = enum(u8) {
    ich_at = '@',
    cuu_A = 'A',
    cud_B = 'B',
    cuf_C = 'C',
    cub_D = 'D',
    cnl_E = 'E',
    cpl_F = 'F',
    cha_G = 'G',
    cup_H = 'H',
    ed_J = 'J',
    el_K = 'K',
    il_L = 'L',
    dl_M = 'M',
    dch_P = 'P',
    su_S = 'S',
    sd_T = 'T',
    ech_X = 'X',
    da_c = 'c',
    vpa_d = 'd',
    hvp_f = 'f',
    tbc_g = 'g',
    sm_h = 'h',
    rm_l = 'l',
    sgr_m = 'm',
    dsr_n = 'n',
    decstr_p = 'p',
    decscusr_q = 'q',
    decstbm_r = 'r',
    scosc_s = 's',
    xtwinops_t = 't',
    scorc_u = 'u',
    unknown = 0,
};

pub const Op = union(enum) {
    noop,
    cursor_up: u16,
    cursor_down: u16,
    cursor_fwd: u16,
    cursor_back: u16,
    cursor_pos: struct { row: u16, col: u16 },
    erase_display: u16,
    erase_line: u16,
    sgr: void,
    decset: void,
    decrst: void,
};

pub fn classify(final_byte: u8) Final {
    return std.enums.fromInt(Final, final_byte) orelse .unknown;
}

test "csi classify" {
    try std.testing.expectEqual(Final.sgr_m, classify('m'));
    try std.testing.expectEqual(Final.cup_H, classify('H'));
    try std.testing.expectEqual(Final.unknown, classify('Z'));
}
