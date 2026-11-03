//! Presentation shape shared by file import and the library tree. Imported
//! samples keep their canonical id; original_id is legacy provenance metadata
//! and carries this app-owned marker without adding folder references.
const std = @import("std");
const core = @import("otto_core");

pub const flat_files_id = "otto:flat-files:v1";

pub fn isFlatFile(sample: core.model.Sample) bool {
    return std.mem.eql(u8, sample.original_id, flat_files_id);
}
