# GitHub 自动编译与发布

当前保留手动 CI。Sparkle 更新使用 `Scripts/publish-sparkle.sh` 在发布 Mac 上完成
Ad-hoc 签名、GitHub Release 和 GitHub Pages appcast 发布，不使用 Apple Developer
账号、公证或 App Store Connect。

```text
GitHub Actions 手动运行 CI
        └── 本机 Runner：解析依赖 → 无签名构建 → 运行全部单元测试

publish-sparkle.sh
        └── 测试 → 通用 Archive → Ad-hoc 签名
                → DMG → Sparkle appcast → GitHub Release + GitHub Pages
```

## 工作流

- `.github/workflows/ci.yml`：只通过 GitHub Actions 页面手动运行。
- `.github/workflows/release.yml`：保留为手动运行的旧发布诊断流程，不用于正式 Sparkle 发布。
- 两个手动工作流都使用本机 `[self-hosted, macOS, ARM64]` Runner。
- 正式发布脚本同时构建 `arm64` 和 `x86_64`。
- 显示版本与内部构建号由发布命令明确传入。
- 发布不要求 Apple Developer 账号或证书。
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

正式更新请使用 Sparkle 发布脚本；完整的首次配置见
`Docs/SparkleUpdate.md`：

```bash
./Scripts/publish-sparkle.sh 1.1.0 Docs/ReleaseNotes/1.1.0.md
```

`Scripts/release.sh` 是此前 Ad-hoc GitHub Release 流程的辅助脚本，不要再用它发布
Sparkle 更新。

脚本成功后，GitHub Releases 页面会出现：

```text
inchspace-1.0.0.dmg
inchspace-1.0.0.dmg.sha256
```

不要复用已经发布过的版本号或 Tag。发现错误时，优先修复后发布构建号更高的新版本。

## 用户首次运行

发布包只使用 Ad-hoc 签名，未经过 Apple 公证。用户首次运行时可能被 Gatekeeper 拦截：

1. 打开 DMG，把 `inchspace.app` 拖到 DMG 中的 `Applications` 快捷方式。
2. 在 Finder 中右键应用并选择“打开”；如果系统仍拦截，则到“系统设置 → 隐私与
   安全性”确认打开。

不要要求用户全局关闭 Gatekeeper，也不要把删除 quarantine 属性作为安装步骤。

## Sparkle

首次密钥配置、发布脚本参数、安全要求和端到端更新测试见 `Docs/SparkleUpdate.md`。
