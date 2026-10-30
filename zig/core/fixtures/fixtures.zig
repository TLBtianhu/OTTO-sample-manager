//! 测试用合成数据入口。所有 JSON 均为手工构造，不含任何真实用户数据。
//!
//! 通过 build.zig 的 anonymous module "fixtures" 以 @embedFile 方式编译进测试二进制，
//! 因此测试不依赖运行目录，也不会读取仓库外的文件。

pub const legacy_v1 = @embedFile("legacy_v1.json");
pub const dangling_refs = @embedFile("dangling_refs.json");
pub const duplicate_ids = @embedFile("duplicate_ids.json");
pub const subfolders = @embedFile("subfolders.json");
