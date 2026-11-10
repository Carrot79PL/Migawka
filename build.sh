#!/bin/zsh
# Buduje aplikację "Migawka.app" i instaluje ją w ~/Applications
set -e
cd "$(dirname "$0")"
APP="Migawka.app"
# Built and signed outside this (iCloud-synced) folder, which adds attributes that codesign rejects
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$APP/Contents/MacOS" "$STAGE/src"
# Compiled from a copy: iCloud may touch files here mid-build, which makes swiftc give up
cp *.swift "$STAGE/src/" && cp -R CMpv "$STAGE/src/"
# libmpv (brew install mpv) is linked weakly: the app still starts without it and then uses the macOS player
(cd "$STAGE/src" && swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
    -I CMpv -L/opt/homebrew/lib -Xlinker -weak-lmpv \
    PrzegladarkaZdjec.swift Scanner.swift SecureTemp.swift ZoomView.swift VideoView.swift FolderTree.swift \
    Adjustments.swift Security.swift Subprocess.swift MPVPlayer.swift Filmstrip.swift PhotoInfo.swift Printing.swift GridView.swift ExternalEditor.swift PlaybackBar.swift AppLock.swift PhotoLibrary.swift Metadata.swift \
    -o "$STAGE/$APP/Contents/MacOS/Migawka")
# Icon drawn by make_icon.swift (swift make_icon.swift icon.png, then iconutil)
mkdir -p "$STAGE/$APP/Contents/Resources"
cp AppIcon.icns "$STAGE/$APP/Contents/Resources/"
# Languages: English (also for every language without its own translation) and Polish
cp -R Localization/*.lproj "$STAGE/$APP/Contents/Resources/"
cat > "$STAGE/$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Migawka</string>
  <key>CFBundleIdentifier</key><string>local.przegladarka.zdjec</string>
  <key>CFBundleName</key><string>Migawka</string>
  <key>CFBundleDisplayName</key><string>Migawka</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5</string>
  <key>CFBundleVersion</key><string>0.5</string>
  <!-- Texts in the code are Polish; en.lproj translates them. Polish systems get Polish, all others English -->
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>pl</string></array>
  <key>NSHumanReadableCopyright</key><string>© 2026 Tomasz Marchewka</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- "Otwórz za pomocą" in Finder; Alternate, so the app never takes over as the default viewer -->
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>Zdjęcia, filmy i archiwa</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array>
        <string>public.image</string><string>public.movie</string><string>public.archive</string>
        <string>public.zip-archive</string><string>public.folder</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Inne archiwa i filmy</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array>
        <string>rar</string><string>7z</string><string>cbz</string><string>cbr</string><string>cb7</string>
        <string>cbt</string><string>tar</string><string>tgz</string><string>gz</string><string>bz2</string>
        <string>xz</string><string>lzh</string><string>lha</string><string>cab</string><string>iso</string>
        <string>avi</string><string>mkv</string><string>webm</string><string>wmv</string><string>flv</string>
      </array>
    </dict>
  </array>
  <key>NSPhotoLibraryUsageDescription</key><string>Migawka shows photos and videos from your Photos library. They are read into memory only and never copied, changed or sent anywhere.</string>
  <!-- Context-menu entry (Szybkie czynności / Usługi), which also works for folders -->
  <key>NSServices</key><array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Otwórz w Migawce</string></dict>
      <key>NSMessage</key><string>openInViewer</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array>
        <string>public.folder</string><string>public.image</string><string>public.movie</string>
        <string>public.archive</string><string>public.zip-archive</string>
      </array>
    </dict>
  </array>
</dict></plist>
EOF
xattr -cr "$STAGE/$APP"
# Hardened runtime: blocks code injection (DYLD_INSERT_LIBRARIES) and debugger attachment.
# Library validation is off (Entitlements.plist) so the app can load Homebrew's separately signed libmpv.
codesign --force --options runtime --entitlements Entitlements.plist -s - "$STAGE/$APP"
# Installed in the user's Applications folder (no admin needed), so Finder's context menu finds it
DEST="$HOME/Applications/$APP"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$STAGE/$APP" "$DEST"
codesign --verify "$DEST"
rm -rf "$APP"  # an older copy here would show up twice in "Otwórz za pomocą"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
/System/Library/CoreServices/pbs -update
echo "Gotowe: $DEST"
