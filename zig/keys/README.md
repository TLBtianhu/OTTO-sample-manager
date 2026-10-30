# 更新签名密钥

这个目录只放**公钥**。私钥永远不进仓库、不进聊天、不进构建日志。

```
otto-lite.key.pub    ← 提交进仓库；应用内置它，用来验更新包
（私钥不在这里）      ← 生成在哪、谁保管，见下
```

## 现状

密钥对已于 2026-10-31 生成，与 OTTO（Tauri 那条线）的 `otto-updater.key` **无关**，
两套应用各自独立。

- 公钥：本目录的 `otto-lite.key.pub`（base64，minisign 格式）；
- 私钥：`C:\Users\30680\otto-keys\otto-lite.key`，**生成时未设口令**。

## 私钥的保管规则

1. **不要提交**、不要贴聊天、不要写进脚本或环境变量的默认值；
2. 第一次公开发版之前，把它移到离线介质（U 盘 / 密码管理器附件），并考虑
   **重新生成一对带口令的**——现在的私钥在磁盘上是明文，任何能读这个文件的人都能
   伪造一次更新；
3. 换机、重装系统前先备份；丢了私钥 = 再也签不了更新，只能换公钥重新发布一版；
4. 签名时用环境变量传入，不落盘：
   ```powershell
   $env:TAURI_SIGNING_PRIVATE_KEY = Get-Content -Raw C:\path\to\otto-lite.key
   $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = ''   # 若有口令
   npx @tauri-apps/cli@2 signer sign <安装包>
   ```

## 公钥怎么用

更新清单（`latest.json`）里的签名由它验证。**只验签名是不够的**：公钥保护的是
"这个更新包确实出自我们"，不保护"第一次下载的安装包"——首次获取仍然要靠
SHA-256 和来源可信（GitHub Releases 页面）。

## 重新生成（会换信任根）

```powershell
npx @tauri-apps/cli@2 signer generate -w C:\path\otto-lite.key
```

换公钥意味着**所有已装的旧版本都验不过新更新**，必须走一次手动升级。所以尽量一次定好。
