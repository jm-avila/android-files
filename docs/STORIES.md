# User stories

Ids are named by unit tests (`Tests/AndroidFilesKitTests`) and self-test checks (`SelfTest.swift`).

| Id | Story |
|---|---|
| S-001 | I see whether the tablet is ready, and if not, why (adb missing, no tablet, "Allow USB debugging?" not accepted, offline). |
| S-002 | I browse the Mac and the tablet in Finder-like windows: open folders, go up, go home, refresh, show hidden files. |
| S-003 | I copy files and folders between the Mac and the tablet (Copy + Paste, or drag and drop). |
| S-004 | I move files and folders between them (Cut + Paste, or drag with ⌘); the source goes away only after the copy worked. |
| S-005 | I copy or move within one side. Copying into the same folder keeps both. |
| S-006 | When a name is taken, I choose Replace or Keep Both ("name 2.ext"). |
| S-007 | I delete. Tablet deletes ask first (no Trash there); Mac deletes go to the Trash. |
| S-008 | I rename a file or folder. |
| S-009 | I create a new folder. |
| S-010 | I see progress and can cancel; a cancelled copy leaves no half file. |
| S-011 | I drag files and folders between windows, onto folders, sidebar places and the path bar, and to and from Finder. Same side moves (⌥ copies); the other side copies (⌘ moves). |
| S-012 | I find my way like in Finder: a sidebar (Favorites, the tablet and its folders), Back/Forward, the folder name as the title, a path bar, search in the folder, more windows (⌘N) and tabs (⌘T). |
| S-013 | Copy and paste work with Finder: Mac files I copy here paste in Finder, and files I copy in Finder paste here. |
| S-014 | Files whose names Android refuses (`\ : * ? " < > \|`, tabs, line breaks) still reach the tablet, with `_` in those places, and I'm told which. |
| S-015 | I use the tablet over Wi-Fi: switch the plugged-in tablet over, connect to an address, or pair with a code, and go back to the cable. |
| S-016 | The tablet shows in Finder as a disk, like a USB drive: I open, copy in and out, rename, delete and make folders there, and other apps open its files. It goes away when I unplug it, eject it or quit the app. |

## 2026-11-14: Finder only

The user uses the tablet through Finder only, so the app became a menu bar item with no window. S-002 to S-014 (the
app's own windows, clipboard, drag and drop, conflicts, progress) are retired: Finder does those now. S-001, S-015 and
S-016 remain, and one story is new:

- **S-017**: From the menu bar I see the tablet's state, open it in Finder, eject it, reach Settings and quit.

