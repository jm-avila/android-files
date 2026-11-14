# AndroidFiles

A native macOS SwiftUI menu bar app: an Android tablet on USB or Wi-Fi shows in Finder as a disk, through `adb` and a
WebDAV share on 127.0.0.1. No window of its own.
No database. User docs: `README.md`. Stories: `docs/STORIES.md`.

## Layout

- `Sources/AndroidFilesKit/` everything with no UI: `ADB.swift` (adb client, output parsing, `ADBFileSystem`),
  `ADBServer.swift` (the adb server's socket spoken directly: shell, raw output, the file channel; the default way,
  `ANDROIDFILES_ADB=cli` forces the `adb` program, which is also what `tools/fake-adb` exercises),
  `LocalFileSystem.swift` (the pretend tablet in tests), `FileContent.swift` (streamed reads and writes),
  `WebDAV.swift` (`WebDAVShare`: the methods macOS uses, Finder's `._`/`.DS_Store` files kept in memory),
  `HTTPServer.swift` (127.0.0.1 only), `CommandRunner.swift` (processes, exact Unicode arguments).
  Tests in `Tests/AndroidFilesKitTests/`.
- `Sources/AndroidFiles/` the app: `App.swift` (`MenuBarExtra` menu, Settings scene, quit and reopen),
  `AppModel.swift` (the tablet's state, `syncFinder` keeps the mount in step with the tablet and the setting, Wi-Fi),
  `FinderVolume.swift` (`mount_webdav`, unmount), `Backend.swift` (finding the tablet; `FolderBackend` is the pretend
  tablet for test runs), `SettingsView.swift`.
- The share answers 503, never 404, when the tablet gives no answer: "can't tell" must not read as "absent".
  The app never reads a mounted volume's own files (a dead mount blocks for ever). Never delete a mount folder
  recursively: use `FinderVolume.removeMountFolder` (rmdir, unmounted only).
- Every tablet path goes through `shellQuote` when it enters `adb shell`.
- A new file Finder made empty waits in `WebDAVShare.pending` for its content. Anything that writes a name must hold
  it in `writing` from before its first `await`, and `materialize` must never run for a name in `writing`: an empty
  file landing on content is silent data loss.
- The mount's host is `<name>.localhost`. Never a `.local` or a bare name: a host that stops resolving blocks the unmount.
- The real tablet differs from any fake: `adb exec-in` returns before the last bytes are written, its storage
  ignores case, and it refuses some names. Run the device tests on it before calling a change tested.

## Build and check

- Build and install: `./build.sh` (`--open` restarts the app). Fix every warning.
- Unit tests: `tools/test.sh`. Against the plugged-in tablet (works only in `/sdcard/AndroidFiles-e2e-*`, deleted after):
  `ANDROIDFILES_DEVICE=1 tools/test.sh --filter Device`. Wi-Fi round trip: add `ANDROIDFILES_WIFI=1`. Load and speeds:
  add `ANDROIDFILES_STRESS=1 STRESS_MB=200`. Run it both ways (with and without `ANDROIDFILES_ADB=cli`).
- The volume under load, on the mini so nobody's keyboard is taken: `tools/fake-tablet.sh start` (Docker: toybox +
  mksh, with `tools/fake-adb` as `ADB_PATH`), then `tools/volume-stress.sh [MB]`.
- `tools/findertest.sh` sends real keys to Finder for a minute: only when the user is not typing; ask first.
  By hand: `tools/try.sh`.
- Test runs need `APP_STORE` in /tmp; the app exits if it points anywhere else. Never test on the user's tablet files
  outside a sandbox folder.

## Design rules

- Apple controls and system styles. Spacing from `Space` (`UI/Grid.swift`, 4 pt grid). `ContentUnavailableView` for empty states.
- Everything the app does is in its menu (`TabletMenu` in `App.swift`) or in Settings.

## Git

- Commit after each working change, with a message that says what the user can now do.
