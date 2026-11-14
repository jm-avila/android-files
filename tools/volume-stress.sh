#!/bin/zsh
# Heavy test of the Finder volume with no tablet and no keyboard: starts the pretend tablet (tools/fake-tablet.sh,
# Docker), opens the installed app on it, and works on the mounted volume with cp, dd, mv, rm from this shell.
# Checks every result on the pretend tablet itself. The shell needs Full Disk Access or Network Volumes
# (an SSH session on the mini has it). Refuses to run while AndroidFiles is already open.
# Usage: tools/volume-stress.sh [big file size in MB, default 1024]     (build first: ./build.sh)
set -u
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
here=${0:A:h}
export PATH=$HOME/.docker/bin:/usr/local/bin:/opt/homebrew/bin:$PATH
big_mb=${1:-1024}
work=/tmp/AndroidFiles-stress
log=/tmp/AndroidFiles-stress.log
volumes="$HOME/Library/Application Support/AndroidFiles/Volumes"
V="$volumes/Pretend Tablet"
failures=0
pgrep -f 'AndroidFiles.app/Contents/MacOS/AndroidFiles' > /dev/null && { echo "AndroidFiles is open: quit it first"; exit 1; }

check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi }
wait() { for i in {1..${3:-60}}; do eval "$1" && return 0; sleep ${2:-0.5}; done; return 1 }
tablet() { $here/fake-tablet.sh sh "$@" }
# tcat <path>: a tablet file's content, the path given as it is (no shell in between).
tcat() { docker exec androidfiles-tablet cat -- "$1" 2>/dev/null }
sum() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 }
tsum() { tablet "sha256sum '$1' 2>/dev/null" | cut -d' ' -f1 }
mounted() { mount | grep -q "AndroidFiles/Volumes/Pretend Tablet" }
launch() { open -n ~/Applications/AndroidFiles.app --env ADB_PATH=$here/fake-adb --env ANDROIDFILES_HTTP_LOG=1 --stderr $log --stdout $log }
appquit() { pkill -TERM -f 'AndroidFiles.app/Contents/MacOS/AndroidFiles'; wait '! pgrep -f "AndroidFiles.app/Contents/MacOS/AndroidFiles" > /dev/null' }
# limit <seconds> <command...>: stops a command that hangs.
limit() { perl -e 'alarm shift; exec @ARGV' "$@" }

rm -rf $work /tmp/fake-adb.slow; mkdir -p $work/out $work/many
$here/fake-tablet.sh start || exit 1
defaults write com.jmavila.androidfiles showInFinder -bool true
: > $log; launch
wait mounted || { echo "FAIL the volume did not mount (see $log)"; exit 1; }
check "the volume mounts and lists the tablet's folders" '[[ "$(ls "$V" | sort | tr "\n" " ")" == "DCIM Documents Download " ]]'

# 1. Small files and awkward names, both ways.
names=("plain.txt" "with space.txt" "ñandú € 日本.txt" "it's.txt" 'dollar $(id) `x`;.txt' "amp & percent %20 #hash.txt" "-dash.txt" "trailing.dot." "UPPER.TXT")
ok=1
for n in $names; do
  print -n "content of $n" > "$work/$n"
  cp "$work/$n" "$V/Download/$n" 2>>$log || ok=0
  [[ "$(tcat "/sdcard/Download/$n")" == "content of $n" ]] || { ok=0; echo "  wrong on the tablet: $n"; }
  [[ "$(cat "$V/Download/$n" 2>>$log)" == "content of $n" ]] || { ok=0; echo "  wrong read back: $n"; }
done
check "9 files with awkward names arrive and read back" '(( ok ))'
# The accented name was typed here composed; macOS hands it over decomposed. The tablet must hold it composed.
check "an accented name is stored composed, as Android writes it" '[[ $(docker exec androidfiles-tablet ls /sdcard/Download | grep -c "^ñandú € 日本.txt$") -eq 1 ]]'
docker exec androidfiles-tablet sh -c 'printf viejo > "/sdcard/Documents/$(printf "can\\xcc\\x83o\\xcc\\x81n.txt")"'; sleep 3
check "a name the tablet holds decomposed opens when typed composed" '[[ "$(cat "$V/Documents/cañón.txt" 2>/dev/null)" == "viejo" ]]'
rm -f "$V/Documents/cañón.txt"
check "the folder lists exactly those names" '[[ $(ls "$V/Download" | wc -l) -eq 9 && $(tablet "ls /sdcard/Download | wc -l") -eq 9 ]]'
cp "$work/plain.txt" "$V/Download/bad:name.txt" 2>/dev/null
check "a name Android refuses is refused, and nothing is left" '[[ $(tablet "ls -a /sdcard/Download | wc -l") -eq 11 ]]'

# 2. A big file in and out, byte for byte, with timing.
dd if=/dev/urandom of=$work/big.bin bs=1m count=$big_mb 2>/dev/null
src=$(sum $work/big.bin)
t=$(date +%s); limit 900 cp $work/big.bin "$V/DCIM/big.bin" 2>>$log; up=$(( $(date +%s) - t ))
check "a $big_mb MB file arrives byte for byte (${up}s)" '[[ "$(tsum /sdcard/DCIM/big.bin)" == $src ]]'
t=$(date +%s); limit 900 cp "$V/DCIM/big.bin" $work/out/big.bin 2>>$log; down=$(( $(date +%s) - t ))
check "and comes back byte for byte (${down}s)" '[[ "$(sum $work/out/big.bin)" == $src ]]'
check "no part file is left on the tablet" '[[ -z "$(tablet "find /sdcard -name \"*androidfiles-part-*\" -o -name \"*.old-*\"")" ]]'

# 3. Reads from the middle (a video player seeking). A second file, written on the tablet, so macOS has no copy of it.
tablet "dd if=/dev/urandom of=/sdcard/DCIM/seek.bin bs=1048576 count=64 2>/dev/null"
docker cp androidfiles-tablet:/sdcard/DCIM/seek.bin $work/seek.bin > /dev/null
sleep 3; ok=1
for off in 0 1 65535 65536 65537 1000003 33554432 67108000; do
  a=$(dd if="$V/DCIM/seek.bin" bs=1 skip=$off count=777 2>/dev/null | shasum | cut -d' ' -f1)
  b=$(dd if=$work/seek.bin bs=1 skip=$off count=777 2>/dev/null | shasum | cut -d' ' -f1)
  [[ $a == $b ]] || { ok=0; echo "  wrong bytes at offset $off"; }
done
check "reads at 8 offsets inside a 64 MB file match" '(( ok ))'
check "a file made on the tablet shows up and reads whole" '[[ "$(sum "$V/DCIM/seek.bin")" == "$(sum $work/seek.bin)" ]]'

# 4. Many small files.
for i in {1..400}; do print -n "file $i" > $work/many/f$i.txt; done
mkdir -p $work/many/sub/deeper; print -n deep > $work/many/sub/deeper/d.txt
t=$(date +%s); limit 600 cp -R $work/many "$V/Documents/many" 2>>$log; many=$(( $(date +%s) - t ))
check "a folder of 401 files copies in (${many}s)" '[[ $(tablet "find /sdcard/Documents/many -type f | wc -l") -eq 401 && "$(tablet "cat /sdcard/Documents/many/f400.txt")" == "file 400" ]]'
limit 600 cp -R "$V/Documents/many" $work/out/many 2>>$log
check "and copies out the same" 'diff -r $work/many $work/out/many > /dev/null'
check "listing 400 files shows them all" '[[ $(ls "$V/Documents/many" | wc -l) -eq 401 ]]'

# 5. Rename, move, replace, folders, delete.
mv "$V/Download/plain.txt" "$V/Download/renamed.txt" 2>>$log
check "rename" '[[ "$(tablet "cat /sdcard/Download/renamed.txt; ls /sdcard/Download/plain.txt 2>&1 | grep -c No")" == "content of plain.txt1" ]]'
mv "$V/Download/renamed.txt" "$V/Documents/renamed.txt" 2>>$log
check "move to another folder" '[[ "$(tablet "cat /sdcard/Documents/renamed.txt")" == "content of plain.txt" && ! -e "$V/Download/renamed.txt" ]]'
print -n "newer" > "$V/Documents/newer.txt"; mv -f "$V/Documents/newer.txt" "$V/Documents/renamed.txt" 2>>$log
check "moving a file over another replaces it" '[[ "$(tablet "cat /sdcard/Documents/renamed.txt")" == "newer" && $(tablet "ls -a /sdcard/Documents | grep -c old-") -eq 0 ]]'
mkdir -p "$V/Documents/a/b/c" 2>>$log; print -n nested > "$V/Documents/a/b/c/n.txt"
check "nested folders" '[[ "$(tablet "cat /sdcard/Documents/a/b/c/n.txt")" == "nested" ]]'
mv "$V/Documents/a" "$V/Download/a-moved" 2>>$log
check "move a folder with its contents" '[[ "$(tablet "cat /sdcard/Download/a-moved/b/c/n.txt")" == "nested" && ! -e "$V/Documents/a" ]]'
print -n "0123456789" > "$V/Documents/edit.txt"; print -n "ABC" >> "$V/Documents/edit.txt"
check "appending to a file in place" '[[ "$(tablet "cat /sdcard/Documents/edit.txt")" == "0123456789ABC" ]]'
print -n "short" > "$V/Documents/edit.txt"
check "overwriting with something shorter" '[[ "$(tablet "cat /sdcard/Documents/edit.txt")" == "short" ]]'
: > "$V/Documents/empty.txt"
check "an empty file" '[[ "$(tablet "stat -c %s /sdcard/Documents/empty.txt")" == 0 ]]'
rm -rf "$V/Documents/many" 2>>$log
check "deleting a folder of 401 files" '[[ -z "$(tablet "ls /sdcard/Documents/many 2>/dev/null")" && ! -e "$V/Documents/many" ]]'
rm "$V/DCIM/seek.bin" 2>>$log
check "deleting a file" '[[ "$(tablet "ls /sdcard/DCIM")" == "big.bin" ]]'

# 6. Four copies at once, while another reads.
for i in 1 2 3 4; do dd if=/dev/urandom of=$work/par$i.bin bs=1m count=48 2>/dev/null; done
for i in 1 2 3 4; do (limit 300 cp $work/par$i.bin "$V/DCIM/par$i.bin" 2>>$log) & done
limit 300 cp "$V/DCIM/big.bin" $work/out/big2.bin 2>>$log & 
builtin wait
ok=1; for i in 1 2 3 4; do [[ "$(tsum /sdcard/DCIM/par$i.bin)" == "$(sum $work/par$i.bin)" ]] || ok=0; done
check "four uploads at once arrive intact" '(( ok ))'
check "a download during them is intact" '[[ "$(sum $work/out/big2.bin)" == $src ]]'

# 7. macOS's own files never reach the tablet.
xattr -w com.example.test "some attribute" "$V/Documents/edit.txt" 2>>$log
check "an extended attribute is kept by the volume" '[[ "$(xattr -p com.example.test "$V/Documents/edit.txt" 2>/dev/null)" == "some attribute" ]]'
check "no ._ files, .DS_Store or part files on the tablet (before the unplug test)" '[[ -z "$(tablet "find /sdcard \\( -name \"._*\" -o -name .DS_Store -o -name \"*androidfiles-part-*\" -o -name \"*.old-*\" \\)")" ]]'

# 8. Unplugged in the middle of an upload, then plugged back in.
touch /tmp/fake-adb.slow
(limit 200 cp $work/par1.bin "$V/Download/unplugged.bin" 2>>$log; echo $? > $work/unplug.rc) &
wait '[[ -n "$(tablet "ls -a /sdcard/Download | grep part-")" ]]' 0.5 40
check "the upload is on its way when the tablet is unplugged" '[[ ! -f $work/unplug.rc && -n "$(tablet "ls -a /sdcard/Download | grep part-")" ]]'
$here/fake-tablet.sh stop > /dev/null; rm -f /tmp/fake-adb.slow
wait '[[ -f $work/unplug.rc ]]' 0.5 240
check "an upload cut by unplugging ends, not hangs" '[[ -f $work/unplug.rc ]]'
echo "  (cp ended with status $(cat $work/unplug.rc 2>/dev/null))"
wait '! mounted' 0.5 60
check "unplugging removes the volume" '! mounted'
check "the app is still running" 'pgrep -f "AndroidFiles.app/Contents/MacOS/AndroidFiles" > /dev/null'
$here/fake-tablet.sh resume > /dev/null
wait mounted 0.5 60
check "plugging back in brings the volume back" 'mounted && [[ -d "$V/DCIM" ]]'
check "the cut upload left nothing half-written under its name (absent or empty)" '[[ "$(tablet "stat -c %s /sdcard/Download/unplugged.bin 2>/dev/null || echo 0")" == 0 ]]'
check "its unfinished part is not listed" '[[ -z "$(ls -a "$V/Download" | grep part-)" ]]'
check "the earlier files survived" '[[ "$(tsum /sdcard/DCIM/big.bin)" == $src ]]'

# 9. Eject, quit, and a crash.
diskutil unmount "$V" > /dev/null 2>&1; sleep 3
check "ejecting keeps it away (it does not come back by itself)" '! mounted'
appquit; launch; wait mounted
check "it is back after the app restarts" 'mounted'
appquit; wait '! mounted' 0.5 20
check "quitting the app removes the volume and its folder" '! mounted && [[ -z "$(ls "$volumes" 2>/dev/null)" ]]'
launch; wait mounted
pkill -9 -f 'AndroidFiles.app/Contents/MacOS/AndroidFiles'; sleep 1
(limit 20 ls "$V" > /dev/null 2>&1; echo $? > $work/dead.rc) &
wait '[[ -f $work/dead.rc ]]' 0.5 50
check "after a crash, reading the dead volume ends within 20 s" '[[ -f $work/dead.rc ]]'
launch; wait mounted 0.5 80
check "the next launch clears the dead volume and mounts again" 'mounted && [[ "$(limit 20 cat "$V/Documents/edit.txt" 2>/dev/null)" == "short" ]]'
check "the tablet's files survived the crash and the cleanup" '[[ "$(tsum /sdcard/DCIM/big.bin)" == $src && $(tablet "ls /sdcard/Download | wc -l") -ge 8 ]]'
appquit; wait '! mounted' 0.5 20

echo "times: upload ${up}s, download ${down}s for $big_mb MB; 401 small files in ${many}s"
if (( failures == 0 )); then echo "VOLUME STRESS PASS"; $here/fake-tablet.sh rm > /dev/null; rm -rf $work
else echo "VOLUME STRESS FAIL $failures (requests: $log, files: $work, tablet left running)"; exit 1; fi
