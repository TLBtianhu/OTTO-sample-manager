//! Vorbis floor type 1: packet decode, prediction and curve synthesis.
//!
//! Three steps, in the order the specification gives them:
//!
//!  1. *packet decode* reads one wrapped magnitude per post — the two endpoint
//!     posts first, then one partition class at a time;
//!  2. *amplitude value synthesis* unwraps those magnitudes into a signed
//!     difference against a value predicted by `render_point` between the two
//!     already-known neighbours of each post, and marks the posts that carry a
//!     non-zero difference (`step2_flag`);
//!  3. *curve synthesis* walks the posts in ascending X order and draws the
//!     straight segments with `render_line`, multiplying the residue spectrum by
//!     a gain taken from the 256-entry dB table.
//!
//! Step 2 is where implementations go wrong: the neighbours are *list* indices
//! found over posts with a lower number (not over X order), and the prediction
//! is applied in list order even though the curve is later drawn in X order. The
//! two orders are precomputed here in `Table`, so packet decode does no
//! searching at all.
//!
//! Floor type 0 is not implemented; `vorbis_decoder` rejects a stream that maps
//! a channel through one, rather than silently decoding it as silence.

const std = @import("std");
const types = @import("types.zig");
const vorbis = @import("vorbis.zig");
const vorbis_bits = @import("vorbis_bits.zig");
const huffman = @import("vorbis_huffman.zig");

pub const Error = types.Error;
const AudioBits = vorbis_bits.AudioBits;
const ilog = vorbis_bits.ilog;

/// The specification caps the floor 1 X list at 65 entries.
pub const max_posts: usize = vorbis.max_floor1_x;

/// `floor1_inverse_dB_table` from the specification's tables section: gain for
/// each quantized amplitude step, 0 = -140 dB, 255 = 0 dB.
pub const db_table = [256]f32{
    1.0649863e-07, 1.1341951e-07, 1.2079015e-07, 1.2863978e-07,
    1.3699951e-07, 1.4590251e-07, 1.5538408e-07, 1.6548181e-07,
    1.7623575e-07, 1.8768855e-07, 1.9988561e-07, 2.128753e-07,
    2.2670913e-07, 2.4144197e-07, 2.5713223e-07, 2.7384213e-07,
    2.9163793e-07, 3.1059021e-07, 3.3077411e-07, 3.5226968e-07,
    3.7516214e-07, 3.9954229e-07, 4.2550680e-07, 4.5315863e-07,
    4.8260743e-07, 5.1396998e-07, 5.4737065e-07, 5.8294187e-07,
    6.2082472e-07, 6.6116941e-07, 7.0413592e-07, 7.4989464e-07,
    7.9862701e-07, 8.5052630e-07, 9.0579828e-07, 9.6466216e-07,
    1.0273513e-06, 1.0941144e-06, 1.1652161e-06, 1.2409384e-06,
    1.3215816e-06, 1.4074654e-06, 1.4989305e-06, 1.5963394e-06,
    1.7000785e-06, 1.8105592e-06, 1.9282195e-06, 2.0535261e-06,
    2.1869758e-06, 2.3290978e-06, 2.4804557e-06, 2.6416497e-06,
    2.8133190e-06, 2.9961443e-06, 3.1908506e-06, 3.3982101e-06,
    3.6190449e-06, 3.8542308e-06, 4.1047004e-06, 4.3714470e-06,
    4.6555282e-06, 4.9580707e-06, 5.2802740e-06, 5.6234160e-06,
    5.9888572e-06, 6.3780469e-06, 6.7925283e-06, 7.2339451e-06,
    7.7040476e-06, 8.2047000e-06, 8.7378876e-06, 9.3057248e-06,
    9.9104632e-06, 1.0554501e-05, 1.1240392e-05, 1.1970856e-05,
    1.2748789e-05, 1.3577278e-05, 1.4459606e-05, 1.5399272e-05,
    1.6400004e-05, 1.7465768e-05, 1.8600792e-05, 1.9809576e-05,
    2.1096914e-05, 2.2467911e-05, 2.3928002e-05, 2.5482978e-05,
    2.7139006e-05, 2.8902651e-05, 3.0780908e-05, 3.2781225e-05,
    3.4911534e-05, 3.7180282e-05, 3.9596466e-05, 4.2169667e-05,
    4.4910090e-05, 4.7828601e-05, 5.0936773e-05, 5.4246931e-05,
    5.7772202e-05, 6.1526565e-05, 6.5524908e-05, 6.9783085e-05,
    7.4317983e-05, 7.9147585e-05, 8.4291040e-05, 8.9768747e-05,
    9.5602426e-05, 0.00010181521, 0.00010843174, 0.00011547824,
    0.00012298267, 0.00013097477, 0.00013948625, 0.00014855085,
    0.00015820453, 0.00016848555, 0.00017943469, 0.00019109536,
    0.00020351382, 0.00021673929, 0.00023082423, 0.00024582449,
    0.00026179955, 0.00027881276, 0.00029693158, 0.00031622787,
    0.00033677814, 0.00035866388, 0.00038197188, 0.00040679456,
    0.00043323036, 0.00046138411, 0.00049136745, 0.00052329927,
    0.00055730621, 0.00059352311, 0.00063209358, 0.00067317058,
    0.00071691700, 0.00076350630, 0.00081312324, 0.00086596457,
    0.00092223983, 0.00098217216, 0.0010459992, 0.0011139742,
    0.0011863665, 0.0012634633, 0.0013455702, 0.0014330129,
    0.0015261382, 0.0016253153, 0.0017309374, 0.0018434235,
    0.0019632195, 0.0020908006, 0.0022266726, 0.0023713743,
    0.0025254795, 0.0026895994, 0.0028643847, 0.0030505286,
    0.0032487691, 0.0034598925, 0.0036847358, 0.0039241906,
    0.0041792066, 0.0044507950, 0.0047400328, 0.0050480668,
    0.0053761186, 0.0057254891, 0.0060975636, 0.0064938176,
    0.0069158225, 0.0073652516, 0.0078438871, 0.0083536271,
    0.0088964928, 0.009474637, 0.010090352, 0.010746080,
    0.011444421, 0.012188144, 0.012980198, 0.013823725,
    0.014722068, 0.015678791, 0.016697687, 0.017782797,
    0.018938423, 0.020169149, 0.021479854, 0.022875735,
    0.024362330, 0.025945531, 0.027631618, 0.029427276,
    0.031339626, 0.033376252, 0.035545228, 0.037855157,
    0.040315199, 0.042935108, 0.045725273, 0.048696758,
    0.051861348, 0.055231591, 0.058820850, 0.062643361,
    0.066714279, 0.071049749, 0.075666962, 0.080584227,
    0.085821044, 0.091398179, 0.097337747, 0.10366330,
    0.11039993, 0.11757434, 0.12521498, 0.13335215,
    0.14201813, 0.15124727, 0.16107617, 0.17154380,
    0.18269168, 0.19456402, 0.20720788, 0.22067342,
    0.23501402, 0.25028656, 0.26655159, 0.28387361,
    0.30232132, 0.32196786, 0.34289114, 0.36517414,
    0.38890521, 0.41417847, 0.44109412, 0.46975890,
    0.50028648, 0.53279791, 0.56742212, 0.60429640,
    0.64356699, 0.68538959, 0.72993007, 0.77736504,
    0.82788260, 0.88168307, 0.9389798, 1.0,
};

/// Decoded amplitude state for one channel of one block.
pub const State = struct {
    /// Final Y per post, list order, already unwrapped and range-checked.
    final_y: [max_posts]u16 = @splat(0),
    /// Posts carrying a non-zero difference; only these end a curve segment.
    step2: [max_posts]bool = @splat(false),
};

/// Per-floor precomputed data. Built once at open, immutable afterwards.
pub const Table = struct {
    posts: u8 = 0,
    /// Quantization range: 256/128/86/64 for multipliers 1..4.
    quant_q: u16 = 0,
    multiplier: u8 = 1,
    /// Neighbours used by amplitude synthesis, indexed by `post - 2`.
    low: [max_posts]u8 = @splat(0),
    high: [max_posts]u8 = @splat(1),
    /// Posts in ascending X order; `forward[0]` is always post 0 (X = 0).
    forward: [max_posts]u8 = @splat(0),

    pub fn init(floor: vorbis.Floor1) Error!Table {
        var table = Table{};
        if (floor.x_list.len < 2 or floor.x_list.len > max_posts) return error.Corrupt;
        const posts: u8 = @intCast(floor.x_list.len);
        table.posts = posts;
        table.multiplier = floor.multiplier;
        table.quant_q = switch (floor.multiplier) {
            1 => 256,
            2 => 128,
            3 => 86,
            4 => 64,
            else => return error.Corrupt,
        };
        const n: usize = posts;

        // Sorted order by X. The *whole* list is sorted, including posts 0 and
        // 1: post 1 (X = 2^rangebits) is the largest, so it ends up last and is
        // rendered last. Sorting only 2..n-1 instead leaves post 1 in slot 1 and
        // draws every segment against the wrong endpoint.
        for (0..n) |i| table.forward[i] = @intCast(i);
        var index: usize = 1;
        while (index < n) : (index += 1) {
            var j = index;
            while (j > 0 and floor.x_list[table.forward[j - 1]] > floor.x_list[table.forward[j]]) : (j -= 1) {
                const swap = table.forward[j];
                table.forward[j] = table.forward[j - 1];
                table.forward[j - 1] = swap;
            }
        }

        // Neighbours for the prediction loop: for post i, the closest posts
        // with a lower number whose X straddle X[i].
        for (2..n) |i| {
            var lo: u8 = 0;
            var hi: u8 = 1;
            var lx: u16 = 0;
            var hx: u16 = floor.x_list[1];
            const current = floor.x_list[i];
            for (0..i) |j| {
                const x = floor.x_list[j];
                if (x > lx and x < current) {
                    lo = @intCast(j);
                    lx = x;
                }
                if (x < hx and x > current) {
                    hi = @intCast(j);
                    hx = x;
                }
            }
            table.low[i - 2] = lo;
            table.high[i - 2] = hi;
        }
        return table;
    }
};

/// `render_point` from the helper-equations section: integer interpolation of
/// Y at `x` between (x0,y0) and (x1,y1).
pub fn renderPoint(x0: u16, y0: u16, x1: u16, y1: u16, x: u16) i32 {
    const dy: i32 = @as(i32, @intCast(y1)) - @as(i32, @intCast(y0));
    const adx: i32 = @as(i32, @intCast(x1)) - @as(i32, @intCast(x0));
    const ady: i32 = if (dy < 0) -dy else dy;
    const err: i32 = ady * (@as(i32, @intCast(x)) - @as(i32, @intCast(x0)));
    const off: i32 = @divTrunc(err, adx);
    return if (dy < 0) @as(i32, @intCast(y0)) - off else @as(i32, @intCast(y0)) + off;
}

/// Packet decode plus amplitude value synthesis. Returns false when the
/// `nonzero` flag was clear, which means "this channel is absent this frame".
pub fn decodePacket(
    table: *const Table,
    floor: vorbis.Floor1,
    books: []const huffman.Table,
    bits: *AudioBits,
    state: *State,
) Error!bool {
    if (bits.readBits(1) == 0) return false;
    if (bits.overrun) return false;

    const range: i32 = table.quant_q;
    const value_bits: u6 = ilog(@intCast(range - 1));

    var y: [max_posts]u16 = @splat(0);
    y[0] = @intCast(bits.readBits(value_bits));
    y[1] = @intCast(bits.readBits(value_bits));

    var offset: usize = 2;
    for (floor.partition_class) |class_number| {
        const class = floor.classes[class_number];
        const cbits = class.subclasses;
        const csub: u32 = (@as(u32, 1) << @as(u5, @intCast(cbits))) - 1;
        var cval: u32 = 0;
        if (cbits != 0) {
            const masterbook = class.masterbook orelse return error.Corrupt;
            if (masterbook >= books.len) return error.Corrupt;
            cval = try books[masterbook].decode(bits);
        }
        var j: usize = 0;
        while (j < class.dimensions) : (j += 1) {
            if (offset + j >= max_posts) return error.Corrupt;
            const slot = class.subclass_books[cval & csub];
            cval >>= @as(u5, @intCast(cbits));
            if (slot) |book| {
                if (book >= books.len) return error.Corrupt;
                y[offset + j] = @intCast(try books[book].decode(bits));
            } else {
                y[offset + j] = 0;
            }
        }
        offset += class.dimensions;
    }
    if (bits.overrun) return false;

    const posts: usize = table.posts;
    state.final_y[0] = y[0];
    state.final_y[1] = y[1];
    state.step2[0] = true;
    state.step2[1] = true;

    var i: usize = 2;
    while (i < posts) : (i += 1) {
        const lo = table.low[i - 2];
        const hi = table.high[i - 2];
        const predicted = renderPoint(
            floor.x_list[lo],
            state.final_y[lo],
            floor.x_list[hi],
            state.final_y[hi],
            floor.x_list[i],
        );
        const highroom: i32 = range - predicted;
        const lowroom: i32 = predicted;
        const room: i32 = if (highroom < lowroom) highroom * 2 else lowroom * 2;
        const val: i32 = y[i];

        if (val != 0) {
            state.step2[lo] = true;
            state.step2[hi] = true;
            state.step2[i] = true;
            var value: i32 = undefined;
            if (val >= room) {
                value = if (highroom > lowroom)
                    val - lowroom + predicted
                else
                    predicted - val + highroom - 1;
            } else if ((val & 1) != 0) {
                value = predicted - @divTrunc(val + 1, 2);
            } else {
                value = predicted + @divTrunc(val, 2);
            }
            state.final_y[i] = @intCast(std.math.clamp(value, 0, 255));
        } else {
            state.step2[i] = false;
            state.final_y[i] = @intCast(std.math.clamp(predicted, 0, 255));
        }
    }
    return true;
}

/// Curve synthesis: multiply `spectrum` (the residue vector, n/2 long) by the
/// gain curve. `spectrum` is left untouched only if `posts` is degenerate.
pub fn applyCurve(table: *const Table, floor: vorbis.Floor1, state: *const State, spectrum: []f32) void {
    const multiplier: u16 = table.multiplier;
    const posts: usize = table.posts;
    if (spectrum.len == 0 or posts < 2) return;

    var ly: u16 = gain(state.final_y[0], multiplier);
    var lx: u16 = 0;
    var hx: u16 = 0;
    var hy: u16 = ly;

    var j: usize = 1;
    while (j < posts) : (j += 1) {
        const current = table.forward[j];
        if (!state.step2[current]) continue;
        hx = floor.x_list[current];
        hy = gain(state.final_y[current], multiplier);
        renderLine(spectrum, lx, hx, ly, hy);
        lx = hx;
        ly = hy;
    }

    // Anything beyond the last post keeps the last gain, as the specification's
    // "if hx < n, render_line(hx, hy, n, hy)" does.
    var k: usize = @min(@as(usize, hx), spectrum.len);
    const tail = db_table[ly];
    while (k < spectrum.len) : (k += 1) spectrum[k] *= tail;
}


fn gain(value: u16, multiplier: u16) u16 {
    const scaled = @as(u32, value) * @as(u32, multiplier);
    return if (scaled > 255) 255 else @intCast(scaled);
}

/// Bresenham line drawing with the specification's integer rounding: every
/// element of `v` from `x0` to `x1-1` is scaled by the gain at its Y.
fn renderLine(v: []f32, x0: u16, x1: u16, y0: u16, y1: u16) void {
    const start: usize = x0;
    const stop: usize = @min(@as(usize, x1), v.len);
    if (start >= stop) return;

    const dy: i32 = @as(i32, y1) - @as(i32, y0);
    const adx: i32 = @as(i32, x1) - @as(i32, x0);
    if (adx <= 0) {
        v[start] *= db_table[y0];
        return;
    }
    const base: i32 = @divTrunc(dy, adx);
    const sy: i32 = if (dy < 0) base - 1 else base + 1;
    var ady: i32 = if (dy < 0) -dy else dy;
    ady -= abs32(base) * adx;

    var x = start;
    var y: i32 = y0;
    var err: i32 = 0;
    v[x] *= db_table[@intCast(std.math.clamp(y, 0, 255))];
    while (true) {
        x += 1;
        if (x >= stop) break;
        err += ady;
        if (err >= adx) {
            err -= adx;
            y += sy;
        } else {
            y += base;
        }
        const index: usize = @intCast(std.math.clamp(y, 0, 255));
        v[x] *= db_table[index];
    }
}

fn abs32(value: i32) i32 {
    return if (value < 0) -value else value;
}


