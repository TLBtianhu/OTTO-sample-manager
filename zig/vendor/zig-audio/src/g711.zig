//! ITU-T G.711 µ-law and A-law expansion to 16-bit linear PCM.
//!
//! The 256-entry tables are generated at comptime from the companding
//! definition itself, so the derivation is auditable here instead of being a
//! transcribed constant table:
//!
//!   µ-law:  u = ~code
//!           magnitude = ((((u & 0x0F) << 1) + 33) << ((u >> 4) & 0x07)) - 33
//!           value     = (u & 0x80) ? -4 * magnitude : 4 * magnitude
//!
//!   A-law:  a = code ^ 0x55
//!           magnitude = seg == 0 ? ((a & 0x0F) << 4) + 8
//!                                : (((a & 0x0F) << 4) + 0x108) << (seg - 1)
//!           value     = (a & 0x80) ? magnitude : -magnitude
//!
//! Both expressions are the ITU-T G.711 reference expansion: the µ-law
//! magnitude is a 13-bit value scaled by 4 into the 16-bit range, A-law is
//! already 16-bit. The sign bit is inverted in both laws (1 = positive).
//! Encoding is the exact inverse, but is not needed by a decoder.

const std = @import("std");

pub const Law = enum { mulaw, alaw };

/// Decoded samples for every 8-bit code, indexed by the raw byte.
pub const mulaw_table: [256]i16 = generate(.mulaw);
pub const alaw_table: [256]i16 = generate(.alaw);

pub fn tableFor(law: Law) *const [256]i16 {
    return switch (law) {
        .mulaw => &mulaw_table,
        .alaw => &alaw_table,
    };
}

pub fn expand(law: Law, code: u8) i16 {
    return tableFor(law)[code];
}

fn generate(law: Law) [256]i16 {
    var table: [256]i16 = undefined;
    for (&table, 0..) |*slot, code| {
        slot.* = switch (law) {
            .mulaw => mulawExpand(@intCast(code)),
            .alaw => alawExpand(@intCast(code)),
        };
    }
    return table;
}

fn mulawExpand(code: u8) i16 {
    const inverted: u8 = ~code;
    const exponent: u5 = @intCast((inverted >> 4) & 0x07);
    const mantissa: i32 = @intCast(inverted & 0x0F);
    const magnitude: i32 = (((mantissa << 1) + 33) << exponent) - 33;
    const value = magnitude * 4;
    return @intCast(if (inverted & 0x80 != 0) -value else value);
}

fn alawExpand(code: u8) i16 {
    const a: u8 = code ^ 0x55;
    const segment = (a >> 4) & 0x07;
    const mantissa: i32 = @intCast(a & 0x0F);
    const magnitude: i32 = if (segment == 0)
        (mantissa << 4) + 8
    else
        ((mantissa << 4) + 0x108) << @intCast(segment - 1);
    return @intCast(if (a & 0x80 != 0) magnitude else -magnitude);
}
