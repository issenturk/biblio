#!/bin/bash
# Biblio'ı derler: build/Biblio.app üretir. Kullanım: ./build.sh [--install]
set -e
cd "$(dirname "$0")"
APP="build/Biblio.app"   # ASCII yol: derleyici Türkçe karakterli yollarda sorun çıkarabiliyor
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp icon/Biblio.icns "$APP/Contents/Resources/Biblio.icns"
# OneDrive eşitlemesi derleme sırasında dosyayı değiştirmesin diye kaynakları geçici klasörde derle
TMP=$(mktemp -d)
cp Sources/*.swift "$TMP/"
swiftc -O -swift-version 5 -parse-as-library "$TMP"/*.swift -o "$APP/Contents/MacOS/Biblio"
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Biblio</string>
<key>CFBundleDisplayName</key><string>Biblio</string>
<key>CFBundleIdentifier</key><string>local.biblio</string>
<key>CFBundleExecutable</key><string>Biblio</string>
<key>CFBundleIconFile</key><string>Biblio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSDownloadsFolderUsageDescription</key><string>İzlediğiniz klasördeki PDF'leri adlandırmak için.</string>
<key>NSDesktopFolderUsageDescription</key><string>İzlediğiniz klasördeki PDF'leri adlandırmak için.</string>
<key>NSDocumentsFolderUsageDescription</key><string>İzlediğiniz klasördeki PDF'leri adlandırmak için.</string>
</dict></plist>
PL
codesign --force --deep -s - "$APP"
if [ "$1" = "--install" ]; then rm -rf "/Applications/Biblio.app"; cp -R "$APP" "/Applications/Biblio.app"; echo "Kuruldu: /Applications/Biblio.app"; fi
echo "Hazır: $PWD/$APP"
