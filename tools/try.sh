#!/bin/zsh
# Opens a test copy of the app (tools/test-copy.sh: /tmp/AndroidFiles-try.app) on a pretend tablet with sample
# files, shown in Finder as a disk. It runs beside your own AndroidFiles (a second icon in the menu bar) and
# touches nothing outside /tmp/AndroidFiles-try.store.
# Usage: tools/try.sh [state]     state: ready (default), none, unauthorized, offline, noadb. Quit it from its menu to end.
set -u
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
app=$(${0:A:h}/test-copy.sh try) || exit 1
store=/tmp/AndroidFiles-try.store
mount | grep -q " on /private$store/" && { echo "a volume is still mounted in $store: quit the test copy first"; exit 1; }
rm -rf $store
APP_STORE=$store APP_SEED=1 APP_FINDER=1 APP_DEVICE_STATE=${1:-ready} $app
