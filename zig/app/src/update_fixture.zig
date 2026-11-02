//! 更新链路测试的固定夹具：一段自造字节 + 一把**丢掉了私钥**的测试钥匙。
//!
//! 为什么不读 `zig\dist` 里的真安装包：那会让这几条测试只在这台机器上存在
//! （换台机器全部 Skip，而 `health` 把 Skip 算失败），还会把 `prune-dist.ps1`
//! 的清理纪律绑在两个老版本上。这里钉的是**判定**：给定签名与公钥，内容对 /
//! 错一个字节 / 截断各是什么结论——不依赖任何真实产物。
//!
//! 常量是离线生成的：私钥种子 = SHA-256("otto-lite update test fixture v1")，
//! key id = "OTTOTEST"，`ED` 变体（签名对象是内容的 BLAKE2b-512 摘要）。
//! 私钥没有保存；下面两个 base64 就是它能被复现的全部。

/// 夹具内容（190 字节）。测试把它写进 `testing.tmpDir`，不读 dist。
pub const content =
    "otto-lite update fixture -- not a real installer.\n" ++
    "These bytes exist so download -> hash -> verify has something to consume.\n" ++
    "The signature is over this exact text, made with a throwaway key.\n";

/// feed 里写的版本号。任意值：下载链路只把它拼进文件名，不读 dist。
pub const version = "0.3.0";

/// 测试公钥（minisign 公钥文件格式的外层 base64）。
pub const public_key_b64 = "dW50cnVzdGVkIGNvbW1lbnQ6IG90dG8tbGl0ZSB1cGRhdGUgdGVzdCBrZXkgKGZpeHR1cmU7IG5vdCB0aGUgcmVsZWFzZSBrZXkpClJXUlBWRlJQVkVWVFZMTDl6Uzd5U3liRGZKZmxCWHR2blgwQXZDZVAzOHhLWjJqTldFMFNBOEJ0Cg==";

/// 对 `content` 的 minisign `ED` 签名（`.sig` 文件格式的外层 base64）。
pub const signature_b64 = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIG90dG8tbGl0ZSB1cGRhdGUgdGVzdCBrZXkKUlVSUFZGUlBWRVZUVkVDN0lGZXdjcEllOWRMOGtaQm1IQXFFbXFHVWFKVWM2K2xkc0cyem9vYVFsMi8rS3FiL0thb0JyTTlFL21HYlFZVDNJcFBwQllIMGhuSDkyMUVTeFFnPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDowCWZpbGU6Zml4dHVyZQl2ZXJzaW9uOjAuMy4wCg==";
