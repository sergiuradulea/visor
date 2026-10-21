#!/bin/zsh
# Maintainers only: recompile visor.icon (edited in Icon Composer) into Resources/.
# Needs full Xcode (actool). The output is committed, so building Visor doesn't.
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d)
xcrun actool visor.icon --compile "$OUT" --app-icon visor --platform macosx --target-device mac \
  --minimum-deployment-target 14.0 --output-partial-info-plist "$OUT/partial.plist" >/dev/null
cp "$OUT/Assets.car" "$OUT/visor.icns" ../../Resources/
rm -rf "$OUT"
echo "Updated Resources/Assets.car and Resources/visor.icns"
