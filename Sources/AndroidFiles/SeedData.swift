import Foundation

/// Test runs work in the APP_STORE folder in /tmp: `device/sdcard` is the pretend tablet.
/// APP_SEED=1 fills it with realistic files.
@MainActor
enum SeedData {
    static func prepareIfRequested() {
        guard let store = TestMode.store, TestMode.isSafe else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: "\(store)/device/sdcard", withIntermediateDirectories: true)
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1" else { return }
        let files: [(String, Int, Double)] = [
            ("device/sdcard/DCIM/Camera/IMG_20261102_101500.jpg", 4_402_118, 7),
            ("device/sdcard/DCIM/Camera/VID_20261102_101800.mp4", 154_330_221, 7),
            ("device/sdcard/Download/boarding-pass.pdf", 210_334, 3),
            ("device/sdcard/Download/Reading list.epub", 1_830_002, 12),
            ("device/sdcard/Documents/Sketch.png", 980_221, 20),
            ("device/sdcard/Movies/Lecture 10.mp4", 402_118_220, 33),
            ("device/sdcard/Music/Album/01 Opening.flac", 31_220_118, 300),
            ("device/sdcard/Pictures/Screenshots/Screenshot_20261105.png", 610_221, 4),
            ("device/sdcard/notes.txt", 1_402, 1),
            ("device/sdcard/.thumbnails/cache.db", 102_400, 1),
        ]
        for dir in ["device/sdcard/Alarms", "device/sdcard/Android", "device/sdcard/Podcasts",
                    "device/sdcard/Ringtones", "device/sdcard/Notifications"] {
            try? fm.createDirectory(atPath: "\(store)/\(dir)", withIntermediateDirectories: true)
        }
        for (path, size, daysAgo) in files {
            let url = URL(fileURLWithPath: "\(store)/\(path)")
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Sparse files: the listed size without writing hundreds of megabytes.
            fm.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: UInt64(size))
                try? handle.close()
            }
            try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        }
    }
}
