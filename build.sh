#!/bin/zsh
# Builds Visor.app (with the media helper inside) into ./build.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/Visor.app
HELPER=$APP/Contents/Helpers/VisorMedia.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $HELPER/Contents/MacOS
cp $BIN/Visor $APP/Contents/MacOS/
cp $BIN/VisorMedia $HELPER/Contents/MacOS/
cp Resources/Assets.car Resources/visor.icns $APP/Contents/Resources/ # icon, see design/icon/compile.sh

plist() { # id name exe extra
cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$1</string>
<key>CFBundleName</key><string>$2</string>
<key>CFBundleExecutable</key><string>$3</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
$4
</dict></plist>
EOF
}
plist io.github.visor Visor Visor "<key>CFBundleIconFile</key><string>visor</string><key>CFBundleIconName</key><string>visor</string><key>NSBluetoothAlwaysUsageDescription</key><string>Visor shows the battery level of your AirPods, keyboard and mouse.</string><key>NSDownloadsFolderUsageDescription</key><string>Visor shows downloads in progress in the notch and adds finished ones to the tray.</string><key>NSDesktopFolderUsageDescription</key><string>Visor adds new screenshots saved to your Desktop to the tray.</string><key>NSDocumentsFolderUsageDescription</key><string>Visor adds new screenshots saved to your Documents folder to the tray.</string>" > $APP/Contents/Info.plist
# The com.apple. prefix is what lets MediaRemote answer on macOS 15.4+.
plist com.apple.controlcenter.VisorMedia VisorMedia VisorMedia "" > $HELPER/Contents/Info.plist

# A stable certificate keeps the Accessibility grant across rebuilds; ad-hoc ("-")
# changes identity every build. Create "Visor Dev" once in Keychain Access (see README).
SIGN="-"
security find-identity -p codesigning | grep -q '"Visor Dev"' && SIGN="Visor Dev"
codesign --force -s "$SIGN" --identifier com.apple.controlcenter.VisorMedia $HELPER
codesign --force -s "$SIGN" --identifier io.github.visor $APP
echo "Signed with: $SIGN"
echo "Built $APP"
