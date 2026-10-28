#!/bin/bash
set -e
# 소스 폴더로 이동
cd "$(dirname "$0")"

# 앱은 OneDrive 밖에 생성 (동기화 속성 때문에 codesign 실패 방지)
OUT_DIR="$HOME/Applications"
APP="$OUT_DIR/GlaNce.app"
TMP="$(mktemp -d)"

mkdir -p "$OUT_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Apple Silicon + Intel 모두 지원하는 Universal 바이너리
swiftc -O -parse-as-library -target arm64-apple-macos13.0  GlaNce.swift -o "$TMP/GlaNce-arm64"
swiftc -O -parse-as-library -target x86_64-apple-macos13.0 GlaNce.swift -o "$TMP/GlaNce-x86_64"
lipo -create "$TMP/GlaNce-arm64" "$TMP/GlaNce-x86_64" -output "$APP/Contents/MacOS/GlaNce"

# 앱 아이콘 (.icns)
swift make_icon.swift "$TMP/icon_1024.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

cp Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
touch "$APP"   # Finder 아이콘 캐시 갱신

# 배포용 zip (GitHub Releases에 올릴 파일)
if [ "$1" == "--zip" ]; then
    ZIP="$HOME/Desktop/GlaNce.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "배포용 zip: $ZIP"
fi

echo "빌드 완료: $APP"
