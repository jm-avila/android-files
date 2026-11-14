#!/bin/zsh
# Makes a copy of the installed app with its own bundle id in /tmp and prints its program's path, so test runs
# go beside your own AndroidFiles (same bundle id: macOS would hand the launch to it) and keep their own saved state.
# Usage: tools/test-copy.sh <name>     e.g. try → /tmp/AndroidFiles-try.app, com.jmavila.androidfiles.try
set -u
[[ ${1:-} == -h || ${1:-} == --help || -z ${1:-} ]] && { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
app=/tmp/AndroidFiles-$1.app
rm -rf $app && cp -R ~/Applications/AndroidFiles.app $app || exit 1
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.jmavila.androidfiles.$1" $app/Contents/Info.plist
codesign --force --sign - $app 2>/dev/null
rm -rf ~/Library/Saved\ Application\ State/com.jmavila.androidfiles.$1.savedState
echo $app/Contents/MacOS/AndroidFiles
