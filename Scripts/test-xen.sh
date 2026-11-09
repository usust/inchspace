#!/bin/zsh
set -eu
# Build all native Xen sources in isolation from optional app dependencies.
# HTTP and RFB integration fixtures bind only to 127.0.0.1.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/inchspace-xen-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/Sources/inchspace" "$test_dir/Tests/inchspaceTests"
cp "$repo_dir"/inchspace/Xen/*.swift "$test_dir/Sources/inchspace/"
cp "$repo_dir/inchspace/Components/AppFeatureHeader.swift" "$test_dir/Sources/inchspace/"
cp "$repo_dir/inchspaceTests/XenProtocolTests.swift" "$test_dir/Tests/inchspaceTests/"
cat > "$test_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "XenNativeTests", platforms: [.macOS(.v26)], products: [], targets: [
    .target(name: "inchspace", swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor", "-enable-upcoming-feature", "MemberImportVisibility", "-Xfrontend", "-disable-sandbox"])]), .testTarget(name: "inchspaceTests", dependencies: ["inchspace"])
], swiftLanguageModes: [.v5])
PACKAGE
export CLANG_MODULE_CACHE_PATH="$test_dir/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$test_dir/modules"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path "$test_dir" --scratch-path "$test_dir/build" --cache-path "$test_dir/cache" --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$test_dir/modules"
