#!/bin/zsh

set -euo pipefail
script_name="${0:t}"

usage() {
  echo "Usage: $script_name <X.Y.Z> [commit message]" >&2
  echo "Example: $script_name 0.0.3 \"Release v0.0.3\"" >&2
}

if (( $# < 1 || $# > 2 )); then
  usage
  exit 2
fi

version="${1#v}"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Version must match X.Y.Z using numeric components." >&2
  exit 2
fi

tag="v$version"
commit_message="${2:-Release $tag}"
repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Run this script from inside the inchspace Git repository." >&2
  exit 1
}
cd "$repository_root"

current_branch="$(git branch --show-current)"
if [[ "$current_branch" != "main" ]]; then
  echo "Release must be created from main; current branch is '$current_branch'." >&2
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "Git remote 'origin' is not configured." >&2
  exit 1
fi

echo "Checking origin/main and existing tags..."
git fetch origin main --tags

if git show-ref --verify --quiet "refs/tags/$tag"; then
  echo "Tag $tag already exists locally or was fetched from origin." >&2
  exit 1
fi

if ! git merge-base --is-ancestor origin/main HEAD; then
  echo "Local main is behind or has diverged from origin/main. Synchronize it before releasing." >&2
  exit 1
fi

echo
echo "Changes that will be committed and released as $tag:"
git status --short
echo
read "reply?Continue with commit, push main, and push $tag? [y/N] "
if [[ ! "$reply" =~ '^[Yy]$' ]]; then
  echo "Release cancelled."
  exit 0
fi

git add -A
if git diff --cached --quiet; then
  echo "No new file changes; releasing the current HEAD commit."
else
  git commit -m "$commit_message"
fi

git push origin main
git tag -a "$tag" -m "$commit_message"
git push origin "$tag"

echo
echo "Published $tag. The GitHub Release workflow will build and upload the DMG on this Mac runner."
