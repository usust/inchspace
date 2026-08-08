#!/bin/zsh

set -euo pipefail

script_name="${0:t}"
assume_yes=false

usage() {
  echo "Usage: $script_name [--yes] <X.Y.Z> [--build <number>] [release-notes.md]" >&2
  echo "Example: $script_name 1.1.0 Docs/ReleaseNotes/1.1.0.md" >&2
  echo "Override: $script_name 1.1.0 --build 110 Docs/ReleaseNotes/1.1.0.md" >&2
  echo >&2
  echo "Optional environment variables:" >&2
  echo "  SPARKLE_ACCOUNT           generate_keys account (default: inchspace)" >&2
  echo "  SPARKLE_BIN_DIR           Directory containing Sparkle command-line tools" >&2
  echo "  SPARKLE_SOURCE_PACKAGES_DIR  Reusable SwiftPM cache directory" >&2
}

fail() {
  echo "Error: $1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

build_number=""
positional_arguments=()

while (( $# > 0 )); do
  case "$1" in
    --yes)
      assume_yes=true
      ;;
    --build)
      shift
      [[ -n "${1:-}" ]] || fail "--build requires a positive integer."
      build_number="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      fail "Unknown option: $1"
      ;;
    *)
      positional_arguments+=("$1")
      ;;
  esac
  shift
done

if (( ${#positional_arguments} < 1 || ${#positional_arguments} > 2 )); then
  usage
  exit 2
fi

version="${positional_arguments[1]#v}"
release_notes="${positional_arguments[2]:-}"

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "Version must match X.Y.Z."
if [[ -n "$build_number" ]]; then
  [[ "$build_number" =~ '^[1-9][0-9]*$' ]] || fail "Build number must be a positive integer."
fi

sparkle_account="${SPARKLE_ACCOUNT:-inchspace}"
tag="v$version"

if [[ -n "$release_notes" ]]; then
  [[ -f "$release_notes" ]] || fail "Release notes file not found: $release_notes"
  release_notes="${release_notes:A}"
fi

for command_name in xcodebuild codesign ditto hdiutil git gh shasum plutil lipo find xmllint grep sed awk; do
  require_command "$command_name"
done

repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "Run from the inchspace repository."
cd "$repository_root"

[[ -z "$(git status --porcelain)" ]] || fail "The worktree must be clean. Commit the release changes first."
[[ "$(git branch --show-current)" == "main" ]] || fail "Release from the main branch."

echo "Fetching origin/main and tags..."
git fetch origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || \
  fail "Local main must exactly match origin/main. Push or synchronize it first."

if git show-ref --verify --quiet "refs/tags/$tag" || \
   git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  fail "Tag $tag already exists. Never reuse a released version."
fi

gh auth status >/dev/null
repo_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
if gh release view "$tag" --repo "$repo_slug" >/dev/null 2>&1; then
  fail "GitHub Release $tag already exists."
fi

temporary_root="$(mktemp -d /private/tmp/inchspace-sparkle-release.XXXXXX)"
source_packages="${SPARKLE_SOURCE_PACKAGES_DIR:-/private/tmp/inchspace-source-packages}"
derived_data="$temporary_root/DerivedData"
test_derived_data="$temporary_root/TestDerivedData"
archive_path="$temporary_root/inchspace.xcarchive"
updates_dir="$temporary_root/Updates"
dmg_root="$temporary_root/DmgRoot"
pages_repo="$temporary_root/Pages"
release_dir="$temporary_root/Release"
app_path="$archive_path/Products/Applications/inchspace.app"
dmg_path="$release_dir/inchspace-$version.dmg"
checksum_path="$release_dir/inchspace-$version.dmg.sha256"
mounted_device=""

cleanup() {
  if [[ -n "$mounted_device" ]]; then
    hdiutil detach "$mounted_device" >/dev/null 2>&1 || true
  fi
  if [[ -d "$temporary_root" && "$temporary_root" == /private/tmp/inchspace-sparkle-release.* ]]; then
    rm -rf "$temporary_root"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$source_packages" "$updates_dir" "$dmg_root" "$release_dir"

echo "Resolving Sparkle package..."
xcodebuild -resolvePackageDependencies \
  -project inchspace.xcodeproj \
  -scheme inchspace \
  -clonedSourcePackagesDirPath "$source_packages"

sparkle_bin_dir="${SPARKLE_BIN_DIR:-}"
if [[ -z "$sparkle_bin_dir" ]]; then
  generate_keys_path="$(find "$source_packages/artifacts" -type f -path '*/bin/generate_keys' -print -quit)"
  [[ -n "$generate_keys_path" ]] || fail "Could not locate Sparkle tools in resolved package artifacts."
  sparkle_bin_dir="${generate_keys_path:h}"
fi

generate_keys="$sparkle_bin_dir/generate_keys"
generate_appcast="$sparkle_bin_dir/generate_appcast"
[[ -x "$generate_keys" && -x "$generate_appcast" ]] || \
  fail "SPARKLE_BIN_DIR must contain executable generate_keys and generate_appcast tools."

sparkle_public_key="$($generate_keys --account "$sparkle_account" -p)" || \
  fail "Sparkle signing key '$sparkle_account' is not available in the Keychain."
[[ "$sparkle_public_key" =~ '^[A-Za-z0-9+/]{43}=$' ]] || \
  fail "Sparkle public key returned by generate_keys is not a 32-byte base64 Ed25519 key."

echo "Preparing the gh-pages repository..."
origin_url="$(git remote get-url origin)"
git_author_name="$(git config user.name)" || fail "Configure git user.name before publishing."
git_author_email="$(git config user.email)" || fail "Configure git user.email before publishing."
git init -q "$pages_repo"
git -C "$pages_repo" remote add origin "$origin_url"
git -C "$pages_repo" config user.name "$git_author_name"
git -C "$pages_repo" config user.email "$git_author_email"
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
  git -C "$pages_repo" fetch -q --depth=1 origin gh-pages
  git -C "$pages_repo" checkout -q -b gh-pages FETCH_HEAD
  if [[ -f "$pages_repo/appcast.xml" ]]; then
    ditto "$pages_repo/appcast.xml" "$updates_dir/appcast.xml"
  else
    echo "gh-pages has no appcast.xml; a new feed will be created."
  fi
else
  git -C "$pages_repo" checkout -q --orphan gh-pages
  touch "$pages_repo/.nojekyll"
  echo "gh-pages does not exist; the script will create the first feed branch."
fi

latest_published_build=0
if [[ -f "$updates_dir/appcast.xml" ]]; then
  xmllint --noout "$updates_dir/appcast.xml" || fail "Existing appcast.xml is not valid XML."
  published_builds="$(grep -oE 'sparkle:version="[0-9]+"' "$updates_dir/appcast.xml" \
    | sed -E 's/[^0-9]//g' || true)"
  while IFS= read -r candidate_build; do
    [[ -n "$candidate_build" ]] || continue
    candidate_value=$(( 10#$candidate_build ))
    if (( candidate_value > latest_published_build )); then
      latest_published_build=$candidate_value
    fi
  done <<< "$published_builds"
fi

project_build="$(xcodebuild \
  -project inchspace.xcodeproj \
  -scheme inchspace \
  -clonedSourcePackagesDirPath "$source_packages" \
  -showBuildSettings \
  | awk '/^[[:space:]]*CURRENT_PROJECT_VERSION = [0-9]+$/ { print $3; exit }')"
[[ "$project_build" =~ '^[0-9]+$' ]] || fail "Could not read CURRENT_PROJECT_VERSION."
project_build_value=$(( 10#$project_build ))

minimum_build=$latest_published_build
if (( project_build_value > minimum_build )); then
  minimum_build=$project_build_value
fi

if [[ -z "$build_number" ]]; then
  build_number=$(( minimum_build + 1 ))
  echo "Automatically selected build number $build_number (previous maximum: $minimum_build)."
else
  build_number_value=$(( 10#$build_number ))
  (( build_number_value > latest_published_build )) || \
    fail "Manual build $build_number must be greater than published build $latest_published_build."
  echo "Using manually selected build number $build_number."
fi

echo "Running unit tests..."
xcodebuild test \
  -project inchspace.xcodeproj \
  -scheme inchspace \
  -destination 'platform=macOS' \
  -clonedSourcePackagesDirPath "$source_packages" \
  -derivedDataPath "$test_derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  SPARKLE_PUBLIC_ED_KEY="$sparkle_public_key"

echo "Archiving universal ad-hoc signed build..."
xcodebuild archive \
  -project inchspace.xcodeproj \
  -scheme inchspace \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -clonedSourcePackagesDirPath "$source_packages" \
  -derivedDataPath "$derived_data" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  SPARKLE_PUBLIC_ED_KEY="$sparkle_public_key" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES

[[ -d "$app_path" ]] || fail "Archive did not contain inchspace.app."
info_plist="$app_path/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw "$info_plist")" == "$version" ]] || \
  fail "Archived marketing version does not match $version."
[[ "$(plutil -extract CFBundleVersion raw "$info_plist")" == "$build_number" ]] || \
  fail "Archived build number does not match $build_number."
[[ "$(plutil -extract SUPublicEDKey raw "$info_plist")" == "$sparkle_public_key" ]] || \
  fail "Archived Sparkle public key does not match the Keychain signing key."
[[ "$(plutil -extract SUFeedURL raw "$info_plist")" == https://* ]] || \
  fail "Archived SUFeedURL is not HTTPS."

codesign --verify --deep --strict --verbose=2 "$app_path"
code_signing_details="$(codesign -dvv "$app_path" 2>&1)"
[[ "$code_signing_details" == *"Signature=adhoc"* ]] || \
  fail "Archive is not ad-hoc signed as requested."
archived_entitlements_path="$temporary_root/ArchivedEntitlements.plist"
codesign -d --entitlements :- "$app_path" > "$archived_entitlements_path" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$archived_entitlements_path")" == "true" ]] || \
  fail "Ad-hoc Sparkle builds require the disable-library-validation entitlement."
architectures="$(lipo -archs "$app_path/Contents/MacOS/inchspace")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || \
  fail "Archive must contain both arm64 and x86_64."

echo "Creating DMG..."
ditto "$app_path" "$dmg_root/inchspace.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
  -volname "inchspace $version" \
  -srcfolder "$dmg_root" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dmg_path"
hdiutil verify "$dmg_path"

(cd "$release_dir" && shasum -a 256 "${dmg_path:t}" > "${checksum_path:t}")

ditto "$dmg_path" "$updates_dir/${dmg_path:t}"
if [[ -n "$release_notes" ]]; then
  ditto "$release_notes" "$updates_dir/inchspace-$version.md"
fi

feed_url="$(plutil -extract SUFeedURL raw "$info_plist")"
repo_owner="${repo_slug%%/*}"
repo_name="${repo_slug#*/}"
expected_feed_url="https://${repo_owner:l}.github.io/$repo_name/appcast.xml"
[[ "$feed_url" == "$expected_feed_url" ]] || \
  fail "SUFeedURL must be $expected_feed_url for this GitHub Pages publisher."

download_prefix="https://github.com/$repo_slug/releases/download/$tag/"
echo "Generating signed Sparkle appcast..."
appcast_arguments=(
  --account "$sparkle_account"
  --download-url-prefix "$download_prefix"
  --link "https://github.com/$repo_slug"
  --versions "$build_number"
  --maximum-deltas 0
)
if [[ -n "$release_notes" ]]; then
  appcast_arguments+=(--embed-release-notes)
fi
"$generate_appcast" "${appcast_arguments[@]}" "$updates_dir"
[[ -s "$updates_dir/appcast.xml" ]] || fail "generate_appcast did not create appcast.xml."

echo "Preparing the gh-pages update..."
ditto "$updates_dir/appcast.xml" "$pages_repo/appcast.xml"
git -C "$pages_repo" add appcast.xml
if [[ -f "$pages_repo/.nojekyll" ]]; then
  git -C "$pages_repo" add .nojekyll
fi
if git -C "$pages_repo" diff --cached --quiet; then
  fail "Generated appcast has no changes; refusing to publish a duplicate update."
fi
git -C "$pages_repo" commit -q -m "Publish inchspace $version ($build_number) appcast"
git -C "$pages_repo" push --dry-run origin HEAD:gh-pages

echo
echo "Ready to publish:"
echo "  Repository: $repo_slug"
echo "  Version:    $version ($build_number)"
echo "  Tag:        $tag"
echo "  Asset:      ${dmg_path:t}"
echo "  Feed:       $feed_url"
echo

if [[ "$assume_yes" != true ]]; then
  read "reply?Create the GitHub Release and publish appcast.xml to gh-pages? [y/N] "
  [[ "$reply" =~ '^[Yy]$' ]] || fail "Publishing cancelled."
fi

echo "Creating GitHub Release..."
release_arguments=(
  release create "$tag"
  "$dmg_path"
  "$checksum_path"
  --repo "$repo_slug"
  --target "$(git rev-parse HEAD)"
  --title "inchspace $version"
)
if [[ -n "$release_notes" ]]; then
  release_arguments+=(--notes-file "$release_notes")
else
  release_arguments+=(--generate-notes)
fi
gh "${release_arguments[@]}"

echo "Publishing appcast.xml to gh-pages..."
git -C "$pages_repo" push origin HEAD:gh-pages

echo
echo "Published inchspace $version ($build_number)."
echo "Release: https://github.com/$repo_slug/releases/tag/$tag"
echo "Feed:    $feed_url"
echo "After GitHub Pages deploys, test the update from a lower signed build."
