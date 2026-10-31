//! The Opus range decoder (RFC 6716 section 4.1).
//!
//! Opus packs everything into one arithmetic coder per frame: the symbols are
//! decoded in a fixed order, and "how many bits are left" is itself a value the
//! decoder asks for at dozens of decision points (`tell`, `tellFrac`). That is
//! why this file is the foundation of the CELT layer and not just a helper:
//! the bit allocation literally cannot be reproduced without bit-exact
//! accounting, and `tellFrac` (1/8 bit resolution) must return exactly what the
//! reference does or every later band decision diverges.
//!
//! Two read paths share the buffer: symbols come from the front, and "raw
//! bits" (used for the fine energy refinement, sign bits and the pitch field)
//! come from the back, least-significant bit first. Both must advance the same
//! `nbits_total`, so the two are interleaved by construction and not by
//! convention.
//!
//! Range coder state is 32-bit unsigned throughout; the only operations that
//! can overflow are the shifts in `normalize`, which are modular by design.

const std = @import("std");

pub const Error = error{Corrupt};

// RFC 6716 4.1: EC_SYM_BITS = 8, EC_CODE_BITS = 32, EC_CODE_EXTRA = 7.
const sym_bits: u5 = 8;
const code_bits: u6 = 32;
const code_extra: u5 = 7;
const sym_max: u32 = (1 << sym_bits) - 1;
const code_top: u32 = @as(u32, 1) << (code_bits - 1);
const code_bot: u32 = (@as(u32, 1) << (code_bits - sym_bits - 1)) - 1;

/// The number of bits used for the range-coded part of `decodeUint`.
const uint_bits: u32 = 8;

/// Resolution of `tellFrac`: three bits, i.e. 1/8 bit.
pub const bitres: u5 = 3;

pub fn ilog(v: u32) u32 {
    return if (v == 0) 0 else 32 - @as(u32, @clz(v));
}

pub const Decoder = struct {
    buf: []const u8,
    /// Front offset: the next byte the range coder will read.
    offs: usize = 0,
    /// Back offset: raw bits are read from `buf[buf.len - 1 - end_offs]`.
    end_offs: usize = 0,
    /// Raw bits already shifted out of the back.
    end_window: u32 = 0,
    nend_bits: i32 = 0,
    /// Whole bits consumed. Partial bits still inside the range are not counted.
    nbits_total: i32 = 0,
    rng: u32 = 0,
    val: u32 = 0,
    /// Saved `rng / ft` from the last `decode` call.
    ext: u32 = 0,
    rem: u32 = 0,
    /// Set when an out-of-range uniform integer was decoded (redundancy in the
    /// coder, not a structural error); callers may ignore it.
    errored: bool = false,

    pub fn init(buf: []const u8) Decoder {
        var self = Decoder{ .buf = buf };
        // "This is the offset from which ec_tell() will subtract partial bits."
        self.nbits_total = @as(i32, code_bits) + 1 -
            @as(i32, (code_bits - code_extra) / sym_bits) * @as(i32, sym_bits);
        self.rng = @as(u32, 1) << code_extra;
        self.rem = self.readByte();
        self.val = self.rng - 1 - (self.rem >> (sym_bits - code_extra));
        self.normalize();
        return self;
    }

    fn readByte(self: *Decoder) u32 {
        if (self.offs < self.buf.len) {
            defer self.offs += 1;
            return self.buf[self.offs];
        }
        return 0;
    }

    fn readByteFromEnd(self: *Decoder) u32 {
        if (self.end_offs < self.buf.len) {
            self.end_offs += 1;
            return self.buf[self.buf.len - self.end_offs];
        }
        return 0;
    }

    fn normalize(self: *Decoder) void {
        while (self.rng <= code_bot) {
            self.nbits_total += @intCast(sym_bits);
            self.rng = self.rng << sym_bits;
            // Reuse the bits still pending in `rem`, then top up from the next
            // byte; `sym` is the high tail of that pair.
            var sym = self.rem;
            self.rem = self.readByte();
            sym = (sym << sym_bits | self.rem) >> (sym_bits - code_extra);
            // `val * 256` is modular on purpose: the shift throws the high bits
            // away, exactly like the reference's unsigned arithmetic.
            self.val = (self.val *% 256 +% (sym_max & ~sym)) & (code_top - 1);
        }
    }

    /// Number of bits used so far, rounded up.
    pub fn tell(self: *const Decoder) i32 {
        return self.nbits_total - @as(i32, @intCast(ilog(self.rng)));
    }

    const correction = [8]u32{ 35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535 };

    /// Number of bits used so far in 1/8 bit units, rounded up.
    ///
    /// The reference does this with a linear approximation plus an eight-entry
    /// threshold table rather than the exact log; the table *is* the normative
    /// behaviour, because the allocation depends on the returned value.
    pub fn tellFrac(self: *const Decoder) u32 {
        const nbits: u32 = @as(u32, @intCast(self.nbits_total)) << bitres;
        const l: u32 = ilog(self.rng);
        const r = self.rng >> @intCast(l - 16);
        var b: u32 = (r >> 12) - 8;
        if (r > correction[b]) b += 1;
        return nbits - (l << 3) - b;
    }

    /// `ec_decode`: the low end of the current interval for a symbol of
    /// frequency `ft`, as a value in `[0, ft)`.
    pub fn decode(self: *Decoder, ft: u32) u32 {
        self.ext = self.rng / ft;
        const s = self.val / self.ext;
        return ft - @min(s + 1, ft);
    }

    fn decodeBin(self: *Decoder, bits: u5) u32 {
        self.ext = self.rng >> bits;
        const s = self.val / self.ext;
        return (@as(u32, 1) << bits) - @min(s + 1, @as(u32, 1) << bits);
    }

    pub fn update(self: *Decoder, fl: u32, fh: u32, ft: u32) void {
        const s = self.ext *% (ft - fh);
        self.val -%= s;
        self.rng = if (fl > 0) self.ext *% (fh - fl) else self.rng -% s;
        self.normalize();
    }

    /// A single bit whose probability of being one is `1 / (1 << logp)`.
    pub fn decodeBitLogp(self: *Decoder, logp: u5) u1 {
        const r = self.rng;
        const d = self.val;
        const s = r >> logp;
        const ret: u1 = @intFromBool(d < s);
        if (ret == 0) self.val = d - s;
        self.rng = if (ret == 1) s else r - s;
        self.normalize();
        return ret;
    }

    /// A symbol from an inverse cumulative distribution: `icdf[i]` is the
    /// *remaining* probability after symbol `i`, and the table ends with 0.
    pub fn decodeIcdf(self: *Decoder, icdf: []const u8, ftb: u5) u32 {
        var s = self.rng;
        const d = self.val;
        const r = s >> ftb;
        var ret: i32 = -1;
        var t: u32 = 0;
        while (true) {
            t = s;
            ret += 1;
            s = r *% icdf[@intCast(ret)];
            if (d >= s) break;
        }
        self.val = d - s;
        self.rng = t - s;
        self.normalize();
        return @intCast(ret);
    }

    /// A uniformly distributed integer in `[0, ft)`. Above 2^8 the high part is
    /// range coded and the low part comes from the raw-bit tail.
    pub fn decodeUint(self: *Decoder, ft_in: u32) u32 {
        if (ft_in <= 1) return 0;
        var ft = ft_in - 1;
        // `ilog` reaches 32 for values >= 2^31, so the counter is a u32 and is
        // narrowed to a shift amount only where the width is known to be small.
        var ftb: u32 = ilog(ft);
        if (ftb > uint_bits) {
            ftb -= uint_bits;
            const high = (ft >> @intCast(ftb)) + 1;
            const s = self.decode(high);
            self.update(s, s + 1, high);
            const t = (s << @intCast(ftb)) | self.decodeBits(@intCast(ftb));
            if (t <= ft) return t;
            self.errored = true;
            return ft;
        }
        ft += 1;
        const s = self.decode(ft);
        self.update(s, s + 1, ft);
        return s;
    }

    /// Raw bits, read from the end of the buffer, least significant bit first.
    pub fn decodeBits(self: *Decoder, bits: u5) u32 {
        var window = self.end_window;
        var available = self.nend_bits;
        if (available < @as(i32, bits)) {
            while (true) {
                window |= self.readByteFromEnd() << @intCast(available);
                available += @intCast(sym_bits);
                if (available > @as(i32, 32) - @as(i32, sym_bits)) break;
            }
        }
        const ret = window & ((@as(u32, 1) << bits) - 1);
        window >>= bits;
        available -= @intCast(bits);
        self.end_window = window;
        self.nend_bits = available;
        self.nbits_total += @intCast(bits);
        return ret;
    }

    /// Advance the "bits consumed" counter past everything left, for a frame
    /// whose silence flag says the rest of the payload is unused.
    pub fn skipToEnd(self: *Decoder, len_bits: i32) void {
        const used = self.tell();
        self.nbits_total += len_bits - used;
    }
};

/// A Laplace-distributed integer, used for coarse energy deltas.
///
/// `fs` is the probability of zero out of 32768 and `decay` is the geometric
/// decay rate; both come straight from the per-band model table. Beyond the
/// decaying tail every value gets probability 1/32768, which is what the
/// `LAPLACE_MINP` arithmetic below implements.
pub fn laplaceDecode(dec: *Decoder, fs_in: u32, decay: i32) i32 {
    const minp: u32 = 1;
    const nmin: u32 = 16;

    var val: i32 = 0;
    var fl: u32 = 0;
    var fs = fs_in;
    const fm = dec.decodeBin(15);
    if (fm >= fs) {
        val += 1;
        fl = fs;
        const ft: u32 = 32768 - minp * (2 * nmin) - fs;
        fs = (ft *% @as(u32, @intCast(16384 - decay))) >> 15;
        fs += minp;
        while (fs > minp and fm >= fl + 2 * fs) {
            fs *= 2;
            fl += fs;
            fs = ((fs - 2 * minp) *% @as(u32, @intCast(decay))) >> 15;
            fs += minp;
            val += 1;
        }
        if (fs <= minp) {
            const di = (fm - fl) >> 1;
            val += @intCast(di);
            fl += 2 * di * minp;
        }
        if (fm < fl + fs) {
            val = -val;
        } else {
            fl += fs;
        }
    }
    dec.update(fl, @min(fl + fs, 32768), 32768);
    return val;
}

test "initial state claims one bit" {
    const bytes: [16]u8 = @splat(0x00);
    var dec = Decoder.init(&bytes);
    try std.testing.expectEqual(@as(i32, 1), dec.tell());
    try std.testing.expectEqual(@as(u32, 8), dec.tellFrac());
}

test "raw bits read from the end, LSB first" {
    // 0xA5 at the end of the buffer: the low bits come out first.
    const bytes = [_]u8{ 0x11, 0x22, 0xA5 };
    var dec = Decoder.init(&bytes);
    try std.testing.expectEqual(@as(u32, 0b101), dec.decodeBits(3));
    try std.testing.expectEqual(@as(u32, 0b0100), dec.decodeBits(4));
}

test "bit_logp of one and of zero" {
    // After init `rng` is 1<<23 and a zero payload leaves `val` at rng-1, i.e.
    // just below the split point, so the first logp=1 symbol is a zero. An
    // all-ones payload lands on the other side.
    const zeros: [8]u8 = @splat(0x00);
    var dec = Decoder.init(&zeros);
    try std.testing.expectEqual(@as(u1, 0), dec.decodeBitLogp(1));
    try std.testing.expect(dec.tell() > 1);

    const ones: [8]u8 = @splat(0xFF);
    var dec2 = Decoder.init(&ones);
    try std.testing.expectEqual(@as(u1, 1), dec2.decodeBitLogp(1));
}

test "uniform uint round trips through the two-part path" {
    // ft large enough to need the raw-bit tail (ilog(ft) > 8).
    const bytes: [40]u8 = @splat(0x5A);
    var dec = Decoder.init(&bytes);
    const v = dec.decodeUint(1000);
    try std.testing.expect(v < 1000);
}

test "tellFrac is monotone across symbol decodes" {
    const bytes: [64]u8 = @splat(0x3C);
    var dec = Decoder.init(&bytes);
    var prev = dec.tellFrac();
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        _ = dec.decodeBitLogp(2);
        const now = dec.tellFrac();
        try std.testing.expect(now >= prev);
        prev = now;
    }
}

test "decodeIcdf walks a three-way table" {
    // icdf {2, 1, 0} with ftb=2: symbol 0 keeps 2/4, symbol 1 keeps 1/4.
    const bytes: [8]u8 = @splat(0x00);
    var dec = Decoder.init(&bytes);
    const v = dec.decodeIcdf(&[_]u8{ 2, 1, 0 }, 2);
    try std.testing.expect(v < 3);
}
