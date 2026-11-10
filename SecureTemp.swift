import Foundation

/// Scratch space for unpacked archives that lives only in RAM.
///
/// Archives are extracted onto a RAM disk (never onto the SSD), so nothing can be recovered
/// from the drive later. Ejecting the RAM disk releases the memory; if the app crashes,
/// the RAM disk is ejected on the next launch and is gone after a restart anyway.
/// If the RAM disk cannot be created, archives are not unpacked at all (no fallback to disk).
final class SecureTemp {
    static let shared = SecureTemp()
    static let volumeName = "PrzegladarkaZdjecRAM"

    private let lock = NSLock()
    private var device: String?
    private var mountPoint: URL?

    /// Folder on the RAM disk; creates the RAM disk on first use.
    func root() -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let mountPoint { return mountPoint }
        return create()
    }

    /// Creates the RAM disk in the background (it takes about half a second), so the first archive opens at once
    func prepare() {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.root() }
    }

    func destroy() {
        lock.lock(); defer { lock.unlock() }
        destroyLocked()
    }

    /// Share of the Mac's memory the RAM disk may use, set in the Security menu (applies to the next disk)
    static var capacityPercent: Int {
        let stored = UserDefaults.standard.integer(forKey: "ramDiskPercent")
        return stored == 0 ? 50 : min(max(stored, 1), 75)
    }

    static var capacity: UInt64 {
        min(ProcessInfo.processInfo.physicalMemory / 100 * UInt64(capacityPercent), 48 << 30)
    }

    /// Less than this much room left counts as full
    static let nearlyFull: Int64 = 32 << 20

    /// Space on the RAM disk (nil while there is none, or while it is being made). Its memory is taken
    /// from the Mac's RAM only as files are written, so "used" is also what it costs in memory.
    func usage() -> (used: Int64, total: Int64)? {
        guard lock.try() else { return nil }
        let mountPoint = self.mountPoint
        lock.unlock()
        guard let mountPoint else { return nil }
        var info = statfs()
        guard statfs(mountPoint.path, &info) == 0 else { return nil }
        let total = Int64(info.f_blocks) * Int64(info.f_bsize)
        let free = Int64(info.f_bavail) * Int64(info.f_bsize)
        return (max(total - free, 0), total)
    }

    func contains(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let mountPoint else { return false }
        return url.resolvingSymlinksInPath().path.hasPrefix(mountPoint.resolvingSymlinksInPath().path + "/")
    }

    /// Ejects RAM disks left over after a crash and removes data written by older versions.
    static func cleanupLeftovers() {
        let fm = FileManager.default
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: []) ?? [] {
            if (try? volume.resourceValues(forKeys: [.volumeNameKey]))?.volumeName == volumeName {
                _ = run("/usr/sbin/diskutil", ["eject", "force", volume.path])
                try? fm.removeItem(at: volume)
            }
        }
        // Version 1.0 unpacked archives into the normal temp folder
        try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("PrzegladarkaZdjec"))
        if let id = Bundle.main.bundleIdentifier {
            if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
                try? fm.removeItem(at: lib.appendingPathComponent("Saved Application State/\(id).savedState"))
            }
            try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("\(id).savedState"))
        }
        forgetRecentFolders()
    }

    /// The open panel remembers the last folder (whose name may identify a person) in the app's preferences
    static func forgetRecentFolders() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSOSP") || key.hasPrefix("NSNav") {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }

    private func create() -> URL? {
        // Pages are allocated only as data is written, so a generous size costs nothing up front
        let bytes = Self.capacity
        let sectors = bytes / 512
        guard let out = Self.run("/usr/sbin/diskutil", ["image", "attach", "--noMount", "ram://\(sectors)"])
                ?? Self.run("/usr/bin/hdiutil", ["attach", "-nomount", "ram://\(sectors)"]),
              let dev = out.split(whereSeparator: \.isWhitespace).first.map(String.init),
              dev.hasPrefix("/dev/disk") else { return nil }
        device = dev

        let fm = FileManager.default
        let mp = fm.temporaryDirectory.appendingPathComponent("\(Self.volumeName)-\(UUID().uuidString)", isDirectory: true)
        guard Self.run("/sbin/newfs_hfs", ["-v", Self.volumeName, dev]) != nil,
              (try? fm.createDirectory(at: mp, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])) != nil else {
            mountPoint = mp
            destroyLocked()
            return nil
        }
        mountPoint = mp
        _ = Self.run("/usr/sbin/diskutil", ["mount", "-mountOptions", "nobrowse", "-mountPoint", mp.path, dev])

        // Never write anything unless the folder really is the RAM disk (and not a plain folder on the SSD)
        guard Self.mountedDevice(at: mp) == dev else {
            destroyLocked()
            return nil
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mp.path)
        fm.createFile(atPath: mp.appendingPathComponent(".metadata_never_index").path, contents: nil)
        return mp
    }

    private func destroyLocked() {
        if let device { _ = Self.run("/usr/sbin/diskutil", ["eject", "force", device]) }
        if let mountPoint { try? FileManager.default.removeItem(at: mountPoint) }  // empty mount-point folder
        device = nil
        mountPoint = nil
    }

    private static func mountedDevice(at url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return withUnsafePointer(to: &info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Runs a tool and returns its stdout, or nil if it failed.
    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
