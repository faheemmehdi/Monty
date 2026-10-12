#!/bin/zsh
# Builds Monty.app into app/build.noindex/ (".noindex" keeps Spotlight and Launchpad
# from listing this copy next to the one in /Applications).
# Usage: ./build.sh          build only
#        ./build.sh run      build, install into /Applications, then (re)start it
set -e
cd "$(dirname "$0")"

swift build -c release

APP="build.noindex/Monty.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Monty "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/vocab-default.txt "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# With the local certificate from setup-signing.sh, macOS keeps the Accessibility
# permission across rebuilds. Without it the build is signed ad-hoc, and the
# permission has to be given again after every rebuild.
IDENTITY="Monty Local Signing"
# Certificate made before the app was renamed from MyWispr; used until the new one exists.
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY="MyWispr Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --identifier com.faheemmehdi.monty "$APP"
  echo "Built $APP (signed with \"$IDENTITY\")"
else
  codesign --force --sign - --identifier com.faheemmehdi.monty "$APP"
  echo "Built $APP (ad-hoc signed; run ./setup-signing.sh once to keep permissions across rebuilds)"
fi

# "run" installs the build into Applications (so Launchpad and Spotlight find it) and
# starts that copy. Keeping one installed copy also keeps Open at Login pointing at it.
# Only the copy in /Applications should show up as an app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true

if [[ "$1" == "run" ]]; then
  pkill -x Monty 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Monty.app
  ditto "$APP" /Applications/Monty.app
  open /Applications/Monty.app
  echo "Installed /Applications/Monty.app"
fi
