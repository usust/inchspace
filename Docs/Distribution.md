# GitHub 自动编译与发布

当前阶段只启用 GitHub Actions 自动测试、编译和 GitHub Release。Sparkle 自动更新、EdDSA 密钥和 GitHub Pages 暂不参与发布。

```text
Pull Request / main push
        └── CI：解析依赖 → 无签名构建 → 运行全部单元测试

vX.Y.Z tag
        └── Release：测试 → 通用 Archive → Ad-hoc 签名
                    → ditto ZIP → SHA-256 → GitHub Release
```

## 工作流

- `.github/workflows/ci.yml`：在 Pull Request 和推送 `main` 时运行。
- `.github/workflows/release.yml`：只在推送严格符合 `vX.Y.Z` 的 Tag 时运行。
- Runner 使用 `macos-26`，以提供当前项目所需的 macOS 26.5 SDK。
- Release 同时构建 `arm64` 和 `x86_64`。
- 显示版本来自 Tag，例如 `v1.2.0` 对应 `1.2.0`。
- 内部构建号使用 GitHub Actions `run_number`。
- Release 使用 Ad-hoc 签名，不需要 Apple 付费开发者账号或证书。

## GitHub 仓库设置

仓库需要启用 GitHub Actions。工作流已经显式声明最小权限：

- CI：`contents: read`
- Release：`contents: write`

通常不需要创建 Token 或 Secret，Release 使用 GitHub 自动提供的 `GITHUB_TOKEN`。如果 Release 创建时报资源不可访问，请在仓库 `Settings → Actions → General → Workflow permissions` 中确认没有组织策略禁止工作流申请写权限。

建议为 `main` 设置分支保护，要求 CI 成功后才能合并。首次推送 workflow 后，在 `Settings → Branches` 或 Rulesets 中把 CI 的 `Build and test` 设为 required status check。

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

先确保所有修改已经提交并推送到 `main`，再创建版本 Tag：

```bash
git tag v1.0.0
git push origin v1.0.0
```

工作流成功后，GitHub Releases 页面会出现：

```text
inchspace-1.0.0.zip
inchspace-1.0.0.zip.sha256
```

不要复用已经发布过的版本号或 Tag。发现错误时，优先修复后发布构建号更高的新版本。

## 用户首次运行

由于没有 Developer ID 和 Apple 公证，用户首次运行仍会看到 Gatekeeper 提示：

1. 解压 ZIP，把 `inchspace.app` 移到 `/Applications`。
2. 正常尝试打开一次。
3. 前往“系统设置 → 隐私与安全性”。
4. 找到 inchspace 提示，选择“仍要打开”。

不要关闭 Gatekeeper，也不要把删除 quarantine 属性作为正常安装步骤。

## 后续接入 Sparkle

Sparkle 代码目前保留但在公钥为占位值时禁用。将来启用自动更新时，再恢复以下发布步骤：

- 生成并保护 EdDSA 私钥。
- 把真实公钥写入应用。
- 为 Release ZIP 生成签名和 `appcast.xml`。
- 使用 GitHub Pages 发布 appcast。
- 从旧版本执行真实下载、替换和重启测试。

