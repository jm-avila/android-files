#!/bin/zsh
# Unit tests for AndroidFilesKit. Works with Command Line Tools only (see the mac-app skill's toolchain notes).
# Usage: tools/test.sh [swift test options, like --filter Operations]
#        ANDROIDFILES_DEVICE=1 tools/test.sh --filter Device    also run against the connected tablet
set -euo pipefail
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
package=${0:A:h:h}
plugins=$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing
args=()
[[ -d "$plugins" ]] && args=(-Xswiftc -plugin-path -Xswiftc "${plugins:A}")
# Older Command Line Tools (macOS 26) don't look for Testing.framework by themselves.
dev=/Library/Developer/CommandLineTools/Library/Developer
[[ -d $dev/Frameworks/Testing.framework ]] && args+=(-Xswiftc -F -Xswiftc $dev/Frameworks -Xlinker -F -Xlinker $dev/Frameworks
  -Xlinker -rpath -Xlinker $dev/Frameworks -Xlinker -L -Xlinker $dev/usr/lib -Xlinker -rpath -Xlinker $dev/usr/lib)
swift test --package-path "$package" --scratch-path ~/Library/Developer/AndroidFiles/test-build "${args[@]}" "$@" 2>&1 \
  | grep -v "ld: warning: search path"
