//! Vorbis I header data model.
//!
//! Identification and setup-header structures, each with the `deinit` that
//! releases its slices. The readers that fill them are in `vorbis_meta.zig`;
//! `vorbis.zig` is the public entry point.

const std = @import("std");
const codebook_mod = @import("vorbis_codebook.zig");

const Codebook = codebook_mod.Codebook;

pub const Floor0 = struct {
    order: u8 = 0,
    rate: u16 = 0,
    bark_map_size: u16 = 0,
    amplitude_bits: u8 = 0,
    amplitude_offset: u8 = 0,
    books: []u8 = &.{},

    pub fn deinit(self: *Floor0, allocator: std.mem.Allocator) void {
        if (self.books.len != 0) allocator.free(self.books);
        self.* = .{};
    }
};

pub const Floor1Class = struct {
    dimensions: u8 = 0,
    subclasses: u8 = 0,
    masterbook: ?u8 = null,
    /// `2^subclasses` entries; null means this subclass uses no book.
    subclass_books: []?u8 = &.{},

    pub fn deinit(self: *Floor1Class, allocator: std.mem.Allocator) void {
        if (self.subclass_books.len != 0) allocator.free(self.subclass_books);
        self.* = .{};
    }
};

pub const Floor1 = struct {
    partition_class: []u8 = &.{},
    classes: []Floor1Class = &.{},
    multiplier: u8 = 0,
    rangebits: u4 = 0,
    /// X positions in *list* order: [0] = 0, [1] = 2^rangebits, then the
    /// per-partition values read from the header.
    x_list: []u16 = &.{},

    pub fn deinit(self: *Floor1, allocator: std.mem.Allocator) void {
        if (self.partition_class.len != 0) allocator.free(self.partition_class);
        for (self.classes) |*class| class.deinit(allocator);
        if (self.classes.len != 0) allocator.free(self.classes);
        if (self.x_list.len != 0) allocator.free(self.x_list);
        self.* = .{};
    }
};

pub const Floor = union(enum) {
    floor0: Floor0,
    floor1: Floor1,

    pub fn deinit(self: *Floor, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .floor0 => |*floor| floor.deinit(allocator),
            .floor1 => |*floor| floor.deinit(allocator),
        }
    }

    /// 0 or 1, matching the header's 16-bit floor type field.
    pub fn kind(self: Floor) u16 {
        return switch (self) {
            .floor0 => 0,
            .floor1 => 1,
        };
    }
};

pub const Residue = struct {
    residue_type: u16 = 0,
    begin: u32 = 0,
    end: u32 = 0,
    partition_size: u32 = 0,
    classifications: u8 = 0,
    classbook: u8 = 0,
    /// One 8-bit cascade bitmap per classification.
    cascade: []u8 = &.{},
    /// `classifications * 8`, indexed `[classification * 8 + stage]`.
    /// 0xFF marks an unused stage.
    books: []u8 = &.{},

    pub fn deinit(self: *Residue, allocator: std.mem.Allocator) void {
        if (self.cascade.len != 0) allocator.free(self.cascade);
        if (self.books.len != 0) allocator.free(self.books);
        self.* = .{};
    }

    pub fn book(self: Residue, classification: u8, stage: u8) ?u8 {
        if (classification >= self.classifications or stage >= 8) return null;
        const value = self.books[@as(usize, classification) * 8 + stage];
        return if (value == 0xFF) null else value;
    }
};

pub const Coupling = struct {
    magnitude: u8 = 0,
    angle: u8 = 0,
};

pub const Mapping = struct {
    submaps: u8 = 1,
    coupling: []Coupling = &.{},
    /// One 4-bit value per channel; empty when `submaps == 1`.
    mux: []u8 = &.{},
    submap_floor: []u8 = &.{},
    submap_residue: []u8 = &.{},

    pub fn deinit(self: *Mapping, allocator: std.mem.Allocator) void {
        if (self.coupling.len != 0) allocator.free(self.coupling);
        if (self.mux.len != 0) allocator.free(self.mux);
        if (self.submap_floor.len != 0) allocator.free(self.submap_floor);
        if (self.submap_residue.len != 0) allocator.free(self.submap_residue);
        self.* = .{};
    }
};

pub const Mode = struct {
    blockflag: bool = false,
    mapping: u8 = 0,
};

pub const Setup = struct {
    codebooks: []Codebook = &.{},
    time_count: u8 = 0,
    floors: []Floor = &.{},
    residues: []Residue = &.{},
    mappings: []Mapping = &.{},
    modes: []Mode = &.{},

    pub fn deinit(self: *Setup, allocator: std.mem.Allocator) void {
        for (self.codebooks) |*book| book.deinit(allocator);
        if (self.codebooks.len != 0) allocator.free(self.codebooks);
        for (self.floors) |*floor| floor.deinit(allocator);
        if (self.floors.len != 0) allocator.free(self.floors);
        for (self.residues) |*residue| residue.deinit(allocator);
        if (self.residues.len != 0) allocator.free(self.residues);
        for (self.mappings) |*mapping| mapping.deinit(allocator);
        if (self.mappings.len != 0) allocator.free(self.mappings);
        if (self.modes.len != 0) allocator.free(self.modes);
        self.* = .{};
    }
};

pub const Identification = struct {
    version: u32,
    channels: u16,
    sample_rate: u32,
    bitrate_maximum: i32,
    bitrate_nominal: i32,
    bitrate_minimum: i32,
    blocksize_0: u16,
    blocksize_1: u16,
};
