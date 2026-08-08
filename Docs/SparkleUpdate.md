# Sparkle 2 更新发布指南

inchspace 通过 Swift Package Manager 集成 Sparkle 2。应用生命周期内只有一个
`SPUStandardUpdaterController`，设置页与 App 菜单共用它。App Sandbox、Hardened
Runtime、HTTPS Feed 和 Ed25519 签名验证均须保持启用。发布流程不使用 Apple
Developer 账号、公证或 App Store Connect。

> TODO: 首次启用自动更新前，必须替换工程中的 Feed 与公钥配置，并完成一次旧版本到
> 新版本的端到端测试。

## 1. 生成 EdDSA 密钥

从 Xcode 的 Sparkle package artifacts 中找到并运行 `generate_keys`：

```bash
./generate_keys
```

工具会把私钥存入当前用户的 Keychain，并输出 Ed25519 公钥。不要把私钥导出到项目，
不要将私钥、Keychain 导出文件或 CI 密钥材料提交到 Git。

## 2. 配置应用

- 将输出的公钥填入 target 的 `SPARKLE_PUBLIC_ED_KEY` Build Setting；它会展开为
  `Config/inchspace-Info.plist` 中的 `SUPublicEDKey`。
- `SUFeedURL` 必须指向公开可访问的 HTTPS `appcast.xml`。当前配置位置是
  `Config/inchspace-Info.plist`；若发布位置变化，应在此更新。
- 不要添加 ATS 例外，不要使用 HTTP Feed，也不要禁用 Sparkle 签名验证。
- `CFBundleShortVersionString` 来自 `MARKETING_VERSION`；`CFBundleVersion` 来自
  `CURRENT_PROJECT_VERSION`。每次发布的 `CFBundleVersion` 必须严格递增。

占位公钥存在、密钥格式错误或 Feed 不是 HTTPS 时，应用会安全地禁用更新按钮，避免
启动一个无法验证更新的 updater。

## 3. 构建更新包

用 Release 配置 Archive，并使用 `CODE_SIGN_IDENTITY=-` 做本地 Ad-hoc 签名。这样不需要
任何 Apple Developer 证书或在线服务。Sparkle framework、XPC services 和应用本体仍
必须保持签名结构有效，不能在归档后随意修改 bundle 内容。

Ad-hoc 签名不建立 Apple 信任链，也没有公证票据。用户第一次下载安装时可能需要在
Finder 中右键“打开”，或到“系统设置 → 隐私与安全性”确认。不要要求用户关闭
Gatekeeper。

## 4. 生成 appcast

把已签名并打包的新版归档（例如 DMG）放进仅包含待发布更新的目录，再运行：

```bash
./generate_appcast /path/to/updates
```

`generate_appcast` 使用 Keychain 中由 `generate_keys` 创建的私钥为归档生成 EdDSA
签名，并输出或更新 `appcast.xml`。检查 appcast 中的下载 URL、版本、文件长度和签名，
然后将归档与 appcast 一起发布到 HTTPS 站点。私钥不会随 appcast 发布。

## 5. 发布检查清单

1. 更新 `MARKETING_VERSION`，并将 `CURRENT_PROJECT_VERSION` 递增到从未发布过的值。
2. 对 Release archive 做 Ad-hoc 签名并用 `codesign --verify` 检查。
3. 制作最终 DMG，并运行 `generate_appcast` 生成 Ed25519 签名条目。
4. 先上传更新包，再上传 `appcast.xml`，避免 Feed 短暂指向不存在的文件。
5. 确认 `SUFeedURL` 使用 HTTPS，且应用内 `SUPublicEDKey` 与签名私钥配对。

## 6. 测试更新

保留一个版本号和构建号更低、但已使用同一 `SUPublicEDKey` 构建的旧版。
将测试 Feed 指向包含新版的隔离 HTTPS appcast，然后：

1. 启动旧版，确认“设置 → 关于与更新”与 App 菜单的“检查更新…”均可用。
2. 测试手动检查、自动检查 Toggle 的持久化，以及“无可用更新”标准 UI。
3. 安装更新并确认应用退出、替换、重新启动，版本与构建号均已变化。
4. 分别测试浅色/深色、增强对比度和减少透明度。
5. 用错误签名的隔离测试包确认 Sparkle 拒绝安装；不要在生产 Feed 上做此测试。

测试完成后恢复生产 `SUFeedURL`，不要把测试私钥或本地 Feed 地址提交到项目。

## 7. 使用项目发布脚本

项目使用独立的 Sparkle Keychain account `inchspace`。只需在第一台发布 Mac 上生成一次：

```bash
/path/to/Sparkle/bin/generate_keys --account inchspace
```

请离线备份私钥；不要把导出的私钥放进仓库。把输出的公钥填写到工程的
`SPARKLE_PUBLIC_ED_KEY`，方便普通 Debug 构建也能启用更新。发布脚本还会从 Keychain
读取同一公钥并注入 Release 构建，随后核对归档内的公钥是否一致。

确保代码已经提交、`main` 与 `origin/main` 完全一致，然后运行：

```bash
./Scripts/publish-sparkle.sh 1.1.0 Docs/ReleaseNotes/1.1.0.md
```

脚本会依次执行测试、通用 Archive、Ad-hoc 签名检查、DMG、Sparkle Ed25519 appcast
签名、GitHub Release 创建，以及 `gh-pages` Feed 发布。最后一步执行前会再次询问；
自动化环境可以传入 `--yes`。

内部构建号默认取已发布 appcast 与工程 `CURRENT_PROJECT_VERSION` 的较大值再加一。如需
特殊覆盖，可使用 `--build`，但该值仍必须大于 appcast 中已发布的最大构建号：

```bash
./Scripts/publish-sparkle.sh 1.1.0 --build 110
```

GitHub 仓库的 Pages Source 需要设置为 `gh-pages` 分支根目录。旧的 GitHub Release
workflow 已改为仅手动触发，以免推送发布 Tag 时同时产生一份 Ad-hoc 构建。

注意：只有已经内置真实 `SUPublicEDKey` 的旧版本才能通过 Sparkle 收到后续版本。如果
当前公开版本仍使用占位公钥，需要先人工分发一次带真实公钥的“引导版本”；从这个版本
开始，后续更新才能走 Sparkle。
