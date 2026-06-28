#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS icon cache refresh is only needed on macOS."
  exit 0
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

rm -rf "$HOME/Library/Caches/com.apple.iconservices.store"
rm -rf "$HOME/Library/Caches/com.apple.iconservices"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -r -domain local -domain system -domain user
fi

killall iconservicesagent >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true

echo "macOS icon cache refreshed. Restart the app with: npm run desktop:dev"
