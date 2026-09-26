#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [[ ! -x Vendor/Perl/bin/perl ]]; then
  echo "缺少内置 Perl。先运行 scripts/build-runtime.sh。" >&2
  exit 1
fi
./scripts/generate-app-icon.sh
swift build --disable-sandbox -c release --product PhotoArchive -debug-info-format none
APP="$PWD/dist/拾光.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PhotoArchive "$APP/Contents/MacOS/PhotoArchive"
cp assets/AppIcon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rsync -a --delete Vendor/ExifTool/ "$APP/Contents/Resources/ExifTool/"
rsync -a --delete Vendor/Perl/ "$APP/Contents/Resources/Perl/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhotoArchive</string>
<key>CFBundleIdentifier</key><string>local.shiguang.PhotoArchive</string>
<key>CFBundleName</key><string>拾光</string>
<key>CFBundleDisplayName</key><string>拾光 · 照片归档</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
find "$APP/Contents/Resources/Perl" -type f \( -name '*.bundle' -o -name 'perl' -o -name 'perl5.*' \) -exec codesign --force --sign - {} \;
codesign --force --deep --sign - "$APP"
"$APP/Contents/Resources/Perl/bin/perl" "$APP/Contents/Resources/ExifTool/exiftool" -ver
printf '已构建：%s\n' "$APP"
