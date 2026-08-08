# GitHub 自动编译与发布

当前阶段启用手动 CI 和基于版本 Tag 的自动编译、GitHub Release。Sparkle 自动更新、EdDSA 密钥和 GitHub Pages 暂不参与发布。

```text
GitHub Actions 手动运行 CI
        └── 本机 Runner：解析依赖 → 无签名构建 → 运行全部单元测试

vX.Y.Z tag
        └── 本机 Runner：测试 → 通用 Archive → Ad-hoc 签名
                       → DMG → SHA-256 → GitHub Release
```

## 工作流

- `.github/workflows/ci.yml`：只通过 GitHub Actions 页面手动运行。
- `.github/workflows/release.yml`：只在推送严格符合 `vX.Y.Z` 的 Tag 时运行。
- 两个工作流都使用本机 `[self-hosted, macOS, ARM64]` Runner。
- Release 同时构建 `arm64` 和 `x86_64`。
- 显示版本来自 Tag，例如 `v1.2.0` 对应 `1.2.0`。
- 内部构建号使用 GitHub Actions `run_number`。
- Release 使用 Ad-hoc 签名，不需要 Apple 付费开发者账号或证书。
- DMG 中包含 `inchspace.app` 和指向 `/Applications` 的快捷方式。

## GitHub 仓库设置

仓库需要启用 GitHub Actions。工作流已经显式声明最小权限：

- CI：`contents: read`
- Release：`contents: write`

通常不需要创建 Token 或 Secret，Release 使用 GitHub 自动提供的 `GITHUB_TOKEN`。如果 Release 创建时报资源不可访问，请在仓库 `Settings → Actions → General → Workflow permissions` 中确认没有组织策略禁止工作流申请写权限。

由于 CI 当前只允许手动运行，不要把它设置为 `main` 的 required status check；将来恢复自动 CI 后再启用该分支保护规则。

## 本地验证

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -resolvePackageDependencies \
  -project inchspace.xcodeproj \
  -scheme inchspace \
  -clonedSourcePackagesDirPath /private/tmp/inchspace-source-packages

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project inchspace.xcodeproj \
  -scheme inchspace \
  -destination 'platform=macOS' \
  -clonedSourcePackagesDirPath /private/tmp/inchspace-source-packages \
  -derivedDataPath /private/tmp/inchspace-test-derived \
  CODE_SIGNING_ALLOWED=NO
```

## 发布版本

推荐使用发布脚本。它会检查当前分支和远端状态，展示待提交文件并请求确认，然后依次提交修改、推送 `main`、创建并推送版本 Tag：

```bash
./Scripts/release.sh 1.0.0 "Release v1.0.0"
```

推送 `main` 不会触发编译；脚本最后推送的 `vX.Y.Z` Tag 才会触发一次自动发布流程。版本参数可以写成 `1.0.0` 或 `v1.0.0`。

工作流成功后，GitHub Releases 页面会出现：

```text
inchspace-1.0.0.dmg
inchspace-1.0.0.dmg.sha256
```

不要复用已经发布过的版本号或 Tag。发现错误时，优先修复后发布构建号更高的新版本。

## 用户首次运行

由于没有 Developer ID 和 Apple 公证，用户首次运行仍会看到 Gatekeeper 提示：

1. 打开 DMG，把 `inchspace.app` 拖到 DMG 中的 `Applications` 快捷方式。
2. 正常尝试打开一次。
3. 前往“系统设置 → 隐私与安全性”。
4. 找到 inchspace 提示，选择“仍要打开”。

不要关闭 Gatekeeper，也不要把删除 quarantine 属性作为正常安装步骤。

## 后续接入 Sparkle

Sparkle 代码目前保留但在公钥为占位值时禁用。将来启用自动更新时，再恢复以下发布步骤：

- 生成并保护 EdDSA 私钥。
- 把真实公钥写入应用。
- 为 Release DMG 生成签名和 `appcast.xml`。
- 使用 GitHub Pages 发布 appcast。
- 从旧版本执行真实下载、替换和重启测试。
