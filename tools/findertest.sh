#!/bin/zsh
# Shows a pretend tablet (a /tmp folder) as a volume in Finder, in a test copy of the app, and has Finder itself
# copy out, copy in, make a folder, rename and delete on it. Then checks the pretend tablet's folder.
# It also checks that Finder's own files (._name, .DS_Store) never reach the tablet, and that quitting unmounts.
# It sends real keys to Finder: don't type while it runs (about a minute). Needs Accessibility and Automation (Finder)
# for the terminal app that runs it.
# Usage: tools/findertest.sh     (build first: ./build.sh)
#        tools/findertest.sh --keep     leave the app and the volume open afterwards, to look at it in Finder
set -u
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
here=${0:A:h}
mouse=/tmp/AndroidFiles-mouse
[[ $mouse -nt $here/mouse.swift ]] || swiftc -O -o $mouse $here/mouse.swift || exit 1
app=$($here/test-copy.sh finder) || exit 1
store=/tmp/AndroidFiles-finder.store
out=/private/tmp/AndroidFiles-finder.out
name="OnePlus Pad Go 2"
volume="$store/volumes/$name"
log=/tmp/AndroidFiles-finder.log
mount | grep -q "$store" && diskutil unmount force "$volume" > /dev/null
rm -rf $store $out && mkdir -p $out/in
mkdir -p $store/device/sdcard && print -n "tablet text" > $store/device/sdcard/tablet.txt
print -n "from the mac" > $out/in/hello.txt
head -c 3000000 /dev/urandom > $out/in/big.bin
osascript -e 'tell application "Finder" to get name of every disk' | grep -q "$name" && { echo "a disk named $name is already in Finder: quit AndroidFiles or eject it first"; exit 1; }

ANDROIDFILES_HTTP_LOG=1 APP_STORE=$store APP_SEED=1 APP_FINDER=1 $app > $log 2>&1 &
pid=$!
failures=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi }
wait() { for i in {1..32}; do eval "$1" && return 0; sleep 0.25; done; return 1 }
wait 'mount | grep -q "$store" && [[ -f $store/device/sdcard/notes.txt ]]' || wait 'mount | grep -q "$store"'
wait 'osascript -e "tell application \"Finder\" to get name of every disk" | grep -q "$name"'
check "S-016 the tablet mounts as a volume" 'mount | grep -q "$store"'
check "S-016 Finder lists it as a disk" 'osascript -e "tell application \"Finder\" to get name of every disk" | grep -q "$name"'

# Finder does the work itself, from real keys (⌘C, ⌘V, Return, ⌘⌫) in one window of its own: a scripted
# "duplicate" runs with this terminal's rights, and macOS keeps terminals off network volumes until you allow them.
finder() { osascript -e "tell application \"Finder\"" -e "set d to disk \"$name\"" "$@" -e "end tell" 2>>$log }
win=$(finder -e "set w to make new Finder window to d" -e "set bounds of w to {80, 80, 880, 580}" -e "set current view of w to list view" -e "return id of w")
# show <folder> [item]: the test window shows the folder, with the item selected.
show() { finder -e "set target of Finder window id $win to ($1)" ${2:+-e} ${2:+"select $2"} > /dev/null; sleep 1 }
# key <keycode> [cmd]: only when Finder is in front with the test window first, so no key lands elsewhere.
key() {
  finder -e "activate" > /dev/null; sleep 0.4
  [[ $(finder -e "return (id of front window) as text") == $win && $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>>$log) == Finder ]] || return 1
  $mouse key $(pgrep -x Finder) "$@"; sleep 0.5
}
# Keys can still come too early, so each step is tried up to 3 times until its check holds.
# step <name> <check> <commands>
step() {
  for t in 1 2 3; do
    eval "$3"
    wait "$2" && break
  done
  check "$1" "$2"
}
mac="POSIX file \"$out\" as alias"
# out <folder of d> <item of d>: ⌘C on the tablet's item, ⌘V in the test folder on the Mac.
out() { show "$1" "$2"; key 8 cmd && show "$mac" && key 9 cmd }
# into <Mac folder> <Mac item> <folder of d>: ⌘C on the Mac's item, ⌘V in the tablet's folder.
into() { show "$1" "$2"; key 8 cmd && show "$3" && key 9 cmd }

step "S-016 Finder copies a file out with its content" '[[ "$(cat $out/tablet.txt 2>/dev/null)" == "tablet text" ]]' \
  "out d 'file \"tablet.txt\" of d'"
step "S-016 Finder copies a folder out" '[[ $(stat -f %z $out/DCIM/Camera/IMG_20261102_101500.jpg 2>/dev/null) == 4402118 ]]' \
  "out d 'folder \"DCIM\" of d'"
src="POSIX file \"$out/in\" as alias"
step "S-016 Finder copies a file in" '[[ "$(cat $store/device/sdcard/Download/hello.txt 2>/dev/null)" == "from the mac" ]]' \
  "into '$src' 'file \"hello.txt\" of ($src)' 'folder \"Download\" of d'"
step "S-016 a 3 MB file arrives byte for byte" 'cmp -s $out/in/big.bin $store/device/sdcard/Download/big.bin' \
  "into '$src' 'file \"big.bin\" of ($src)' 'folder \"Download\" of d'"
step "S-016 Finder copies a folder in" 'cmp -s $out/in/big.bin $store/device/sdcard/Documents/in/big.bin && [[ -f $store/device/sdcard/Documents/in/hello.txt ]]' \
  "into '$mac' 'folder \"in\" of ($mac)' 'folder \"Documents\" of d'"
finder -e "make new folder at d with properties {name:\"From Finder\"}" > /dev/null
check "S-016 Finder makes a folder" '[[ -d "$store/device/sdcard/From Finder" ]]'
# Rename: Return, type "z", Return. Finder keeps the extension.
step "S-016 Finder renames" '[[ -f $store/device/sdcard/Documents/z.png && ! -e $store/device/sdcard/Documents/Sketch.png ]]' \
  "show 'folder \"Documents\" of d' 'file \"Sketch.png\" of folder \"Documents\" of d'; key 36 && key 6 && key 36"
# Delete: ⌘⌫, then Return on "will be deleted immediately" (a sheet on the test window).
step "S-016 Finder deletes" '[[ ! -e "$store/device/sdcard/Download/Reading list.epub" ]]' \
  "show 'folder \"Download\" of d' 'file \"Reading list.epub\" of folder \"Download\" of d'; key 51 cmd && sleep 1.5 && key 36"
check "S-016 Finder's own files stay off the tablet" '[[ -z "$(find $store/device \( -name "._*" -o -name .DS_Store -o -name "*androidfiles-part-*" \) -print -quit)" ]]'

[[ ${1:-} == --keep ]] || finder -e "close Finder window id $win" > /dev/null
if [[ ${1:-} == --keep ]]; then
  echo "left open: quit the test app (pid $pid) to unmount. Requests: $log"
else
  osascript -e 'quit app id "com.jmavila.androidfiles.finder"' 2>/dev/null
  for i in {1..40}; do kill -0 $pid 2>/dev/null || break; sleep 0.25; done
  check "S-016 quitting the app removes the volume" '! mount | grep -q "$store"'
fi
[[ $failures == 0 ]] && echo "FINDERTEST PASS" || { echo "FINDERTEST FAIL $failures (requests in $log)"; exit 1; }
