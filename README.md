# AndroidFiles

A menu bar app that shows an Android tablet in Finder as a disk, like a USB drive, over a USB cable or Wi-Fi.
macOS has no driver for Android storage; this app fills that gap through `adb`. Built for a OnePlus Pad Go 2; it should
work with any Android device that adb sees, but that tablet is the only one it was tested on. It has no window of its own: you use the tablet's files in Finder and in
every app's Open and Save dialogs.

## Requirements

- A Mac with macOS 26 or later (Apple silicon or Intel).
- Swift 6.2 or later. Xcode is not needed: the Command Line Tools are enough (`xcode-select --install`).
- `adb`: `brew install android-platform-tools`.
- An Android device with USB debugging turned on (below).

There is no download to install: you build it on your own Mac, which takes about a minute.

## Install

```sh
xcode-select --install                    # once, if `swift --version` says "command not found"
brew install android-platform-tools       # adb
git clone https://github.com/jm-avila/android-files.git
cd android-files
./build.sh --open                         # builds, installs ~/Applications/AndroidFiles.app, opens it
```

`./build.sh` signs the app with your Apple Development certificate if you have one, and ad hoc otherwise (fine for
your own Mac). Nothing is installed outside `~/Applications/AndroidFiles.app`; build products go to
`~/Library/Developer/AndroidFiles`. To update: `git pull && ./build.sh --open`. To remove it: quit the app and delete
`~/Applications/AndroidFiles.app` and `~/Library/Application Support/AndroidFiles`.

To open it at login, add it under System Settings › General › Login Items.

## Set up the tablet (once)

1. On the tablet: Settings › About device › Version, tap **Build number** 7 times. Then Settings ›
   Additional settings › Developer options › turn on **USB debugging**. (The menu names vary a little by brand.)
2. Plug in the cable, unlock the tablet, tap **Allow** on "Allow USB debugging?" (tick "Always allow").
3. Optional, Wi-Fi: menu bar icon › Settings… › Wi-Fi › **Switch to Wi-Fi** while the tablet is plugged in, then unplug
   it. The app reconnects to that address by itself. After the tablet restarts, plug it in and switch again, or pair
   with the code under Developer options › Wireless debugging (Android 11+). **Use the Cable Again** turns Wi-Fi off.

## Use

A tablet icon appears in the menu bar. While the tablet is connected, it is in Finder's sidebar under Locations.

| Menu item | Notes |
|---|---|
| First line | The tablet and its state: in Finder, no tablet connected, "Tap Allow on the tablet", adb missing. The icon gets a mark when something needs you |
| Open in Finder | Opens the tablet's window in Finder, and brings the disk back after an eject. Opening the app again (Spotlight) does the same |
| Eject | Removes the disk until the tablet is connected again or Open in Finder. Ejecting in Finder does the same |
| Settings… | Show in Finder (on by default), Wi-Fi, accent colour |
| Quit AndroidFiles | The disk goes with the app |

## Tests

```sh
tools/test.sh                                           # 64 unit tests (adb parsing, quoting, Wi-Fi, processes, the adb server's protocol, the WebDAV share, the HTTP server)
ANDROIDFILES_DEVICE=1 tools/test.sh --filter Device     # on the real tablet, in a throwaway /sdcard folder: listing, streaming both ways, the share
ANDROIDFILES_DEVICE=1 ANDROIDFILES_WIFI=1 tools/test.sh --filter wifi   # Wi-Fi and back to USB on the real tablet
ANDROIDFILES_DEVICE=1 ANDROIDFILES_STRESS=1 STRESS_MB=200 tools/test.sh --filter Device   # adds the load test: 500 small files, a big file both ways, with speeds
ANDROIDFILES_ADB=cli ...                                # the same through the adb program instead of the direct connection
tools/fake-tablet.sh start && tools/volume-stress.sh 1024  # 42 checks: the volume under load on a pretend tablet in Docker (no keys sent; best on a spare Mac)
tools/findertest.sh                                     # 12 checks: a pretend tablet as a disk in Finder, driven with real keys (takes the keyboard for a minute)
tools/try.sh                                            # a test copy on a pretend tablet with sample files, to try things by hand
```

Results on 2026-11-14: 64 unit tests pass (the share driven directly, and over HTTP with curl). On a second Mac,
against a pretend tablet in Docker (toybox + mksh behind `tools/fake-adb`): the device tests pass, and
`tools/volume-stress.sh 1024` passes 42/42: a 1 GB file up (6 s) and down byte for byte, reads at 8 offsets, 401 small
files (53 s through the adb program, which is all the pretend tablet speaks), accents, spaces and quotes in names, rename, move, replace, delete, an
upload cut halfway, unplug and replug, quit with the disk mounted. `tools/findertest.sh` (real Finder, real keys)
passed 12/12 three times on the laptop; one later run failed one check and was not looked into.
The pretend tablet found a hang and accented names stored wrong; an independent review found 8 more, 7 fixed with
tests (a tablet that stops answering read as "file absent", names that differ only in case, a stale listing kept
after a change, and smaller ones). 
On the real tablet (OnePlus Pad Go 2, USB, in a throwaway folder): the device tests pass, among
them the share Finder mounts driven on the tablet's own rules (Finder's PUT, LOCK, PUT order, accents, case, a
refused name). It found two bugs the pretend tablet could not: `adb exec-in` returns before the tablet has written
the last bytes (12 MB behind for 2 s on a 100 MB file), so the size check refused good uploads; and a rename that
changes only the case is ignored by Android's storage. Both fixed.

Speeds on the real tablet over USB, through the share (the load test above, both ways of talking to adb pass):

| | Direct connection (the app's way) | Through the adb program |
| --- | --- | --- |
| 200 small files, one by one | 5.1 s (25 ms each) | 37.5 s (187 ms each) |
| 300 small files, six at a time | 3.4 s | 9.9 s |
| 200 MB to the tablet | 6.7 s (30 MB/s) | 11.4 s (17.5 MB/s) |
| 200 MB from the tablet | 6.2 s (32 MB/s) | 24.8 s (8 MB/s) |

A second independent review of the faster transfers found 6 more problems, all fixed with tests (an empty file that
could land on content still on its way, a stuck adb server holding the scan, a name in another case listed twice).
**Not yet done on the real tablet with this build: the mount itself with Finder.**

The file window, its clipboard and drag code, and their tests (self-test, drag test, snapshots) were removed with the
window. The menu itself is checked by eye only.

## How it works

macOS has no driver for Android storage, so the app serves `/sdcard` as a WebDAV share on `127.0.0.1` (a free port, a
random secret in the URL, other hosts refused) and mounts it with macOS's own `mount_webdav`. Nothing to install.
Finder's sidebar shows the server's host, so the share is mounted as `<tablet-name>.localhost` (every Mac resolves
that to itself): "oneplus-pad-go-2.localhost" instead of "127.0.0.1". Finder writes it in lower case.
The volume lives in `~/Library/Application Support/AndroidFiles/Volumes/<tablet name>`.

- It exists only while the app runs. Quit, unplug or eject removes it. After a crash the next launch removes what is left.
- Finder's own files (`._name`, `.DS_Store`) stay in the app's memory and never reach the tablet.
- The app talks to the adb server on this Mac directly (port 5037), not through one `adb` process per command: a
  command costs 25 ms instead of 190, and files go through adb's own file channel. If that connection can't be made
  (or with `ANDROIDFILES_ADB=cli`) it falls back to the `adb` program.
- Files stream both ways, so a big video needs no extra copy on the Mac. A file that replaces another goes to
  `.name.androidfiles-part-…` first and takes its place only when every byte arrived. A new file up to 256 KB is
  written in one step.
- Finder creates every file empty and then sends its content. The empty one waits in the app for 3 s, so a file costs
  the tablet one write. One that gets no content (`touch`) is written empty then, or at eject and quit.
- Names Android refuses (`\ : * ? " < > |`) are refused here: Finder says it can't copy them. Rename the file on the Mac first.
- A change made on the tablet shows in Finder after a couple of seconds, and Finder may need its window reopened.
- Finder does not show free space for it.
- Copying runs at about 30 MB/s both ways over USB (`adb push`/`pull` do 32-35), and about 40 small files a second.
- Names that differ only in case are one item, as on the tablet.
- If the tablet stops answering, Finder gets an error, not an empty folder.
- An upload cut halfway leaves an empty file under the name and a hidden part file; the part goes after a day.
  `cp` in a terminal reports success even then (macOS's WebDAV client does not pass the error on); Finder shows it.
- The secret in the URL shows in `mount` to other users of this Mac, who could then read the tablet's files while
  the app runs. The adb port is open to them in the same way.
- Terminals and other apps need "Network Volumes" under System Settings › Privacy & Security › Files and Folders to read
  it; Finder does not.
- `ANDROIDFILES_HTTP_LOG=1` prints every request Finder makes.

## Known limits

- adb only, no MTP. MTP needs a USB driver the Mac doesn't have, and adb (USB or Wi-Fi) reaches the same shared
  storage with real paths, sizes and dates.
- Wi-Fi by `adb tcpip` lasts until the tablet restarts. Copies run at the network's speed. Switching to Wi-Fi or back
  mounts the disk again, so it breaks a copy that is running in Finder.
- Finder shows its own progress for a copy; the app shows none.
- The disk exists only while the app runs. It is not opened at login unless you add it to Login Items.

## Contributing

Issues and pull requests are welcome. Before a pull request: `tools/test.sh` must pass, and a change to how files
are read or written should also pass the device tests on a real device (they only touch a throwaway
`/sdcard/AndroidFiles-e2e-*` folder). `CLAUDE.md` has the layout and the rules the code keeps.

## License

MIT. See [LICENSE](LICENSE).
