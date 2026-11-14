#!/bin/zsh
# A pretend tablet in a Docker container, for testing the adb code paths with no tablet plugged in. It runs toybox
# (the same file tools Android has: find, stat, du, df, dd, cat, mv) under mksh (Android's shell), with an empty /sdcard.
# tools/fake-adb stands in for adb and talks to it. Not emulated: Android's refused names and ignoring case.
# Usage: tools/fake-tablet.sh start     create and start it (pulls alpine and toybox once)
#        tools/fake-tablet.sh stop      stop it: the app sees the tablet unplugged
#        tools/fake-tablet.sh resume    start it again: plugged back in
#        tools/fake-tablet.sh rm        remove it and its files
#        tools/fake-tablet.sh sh <cmd>  run a command on it (as the app does through adb shell)
set -u
name=androidfiles-tablet
case ${1:-} in
  start)
    docker rm -f $name > /dev/null 2>&1
    docker run -d --name $name alpine:3.20 sleep infinity > /dev/null || exit 1
    docker exec $name sh -c '
      apk add --no-cache mksh curl > /dev/null &&
      curl -fsSL -o /usr/local/bin/toybox https://landley.net/toybox/bin/toybox-$(uname -m) &&
      chmod +x /usr/local/bin/toybox && mkdir -p /tb /storage/emulated/0 &&
      for t in $(toybox); do ln -sf /usr/local/bin/toybox /tb/$t; done &&
      printf "#!/bin/sh\n[ \"\$1\" = ro.product.model ] && echo Pretend Tablet || echo\n" > /tb/getprop && chmod +x /tb/getprop &&
      ln -s /storage/emulated/0 /sdcard && mkdir -p /sdcard/Download /sdcard/DCIM /sdcard/Documents' || exit 1
    echo "started $name: $(docker exec $name /usr/local/bin/toybox --version)" ;;
  stop) docker stop -t 1 $name > /dev/null && echo stopped ;;
  resume) docker start $name > /dev/null && echo resumed ;;
  rm) docker rm -f $name > /dev/null && echo removed ;;
  sh) shift; docker exec -i -e PATH=/tb:/usr/bin:/bin $name mksh -c "$*" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
