import Foundation
import UniformTypeIdentifiers

// MARK: - Model

struct Photo: Identifiable, Hashable {
    let url: URL
    /// Where the photo came from, e.g. "Wakacje/2024" or "Wakacje/zdjecia.zip › Plaża"
    let group: String
    /// Unpacked from an archive onto the RAM disk; must not be handed to other apps (they keep caches on disk)
    var isTemporary = false
    /// Worked out once: asking the system for the file type on every use made folders of thousands slow
    let isVideo: Bool
    var id: URL { url }

    init(url: URL, group: String, isTemporary: Bool = false) {
        self.url = url
        self.group = group
        self.isTemporary = isTemporary
        isVideo = Scanner.isVideo(url)
    }
}

struct ScanResult {
    var errors: [String] = []
    /// Picked a single photo/video: open it straight away
    var openURL: URL?
}

// MARK: - Scanner

/// Walks folders recursively, unpacks archives onto the RAM disk and reports photos and videos
/// as soon as each one is found (archive entries the moment they are unpacked), in small batches.
final class Scanner {
    enum Event {
        case found([Photo])
        /// Shown earlier from an unpacking attempt that was then thrown away (e.g. a password was needed)
        case retracted(Set<URL>)
        /// An archive (by its group path) was found, started or finished
        case archive(String, ArchiveState)
        /// Why an archive could not be unpacked, for the tree's warning sign
        case archiveFailed(String, reason: String)
    }

    /// In order: a state never goes back, which lets out-of-order events be ignored
    enum ArchiveState: Int, Comparable {
        case waiting, unpacking, done, failed
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz",
        "cbz", "cbr", "cb7", "cbt", "lzh", "lha", "cab", "iso", "xar",
    ]
    private static let maxArchiveDepth = 3

    private let fm = FileManager.default
    private let progress: (String) -> Void
    private let extractionRoot: () -> URL?
    private let askPassword: (_ archive: String, _ wasWrong: Bool) -> PasswordAnswer
    private let emit: (Event) -> Void
    private let shouldStop: () -> Bool
    /// Folder the user is looking at: an archive in it is unpacked before the others
    private let preferredGroup: () -> String?
    /// Archives are listed during the folder walk and unpacked only afterwards, so all their names
    /// are in the tree right away
    private var archiveQueue: [(url: URL, group: String, depth: Int)] = []
    private var skipAllPasswords = false
    private var result = ScanResult()
    private var pending: [Photo] = []
    private var lastFlush = Date()
    /// Resolved paths already reported, so the final folder walk doesn't repeat streamed entries
    private var reported: Set<String> = []

    enum PasswordAnswer {
        case password(String)
        case skip
        case skipAll
    }

    /// extractionRoot gives the (RAM) folder archives are unpacked into; nil means unpacking is not allowed.
    /// askPassword is called on this (background) thread and may block until the user answers.
    init(extractionRoot: @escaping () -> URL?,
         askPassword: @escaping (_ archive: String, _ wasWrong: Bool) -> PasswordAnswer,
         progress: @escaping (String) -> Void,
         emit: @escaping (Event) -> Void,
         shouldStop: @escaping () -> Bool = { false },
         preferredGroup: @escaping () -> String? = { nil }) {
        self.shouldStop = shouldStop
        self.preferredGroup = preferredGroup
        self.extractionRoot = extractionRoot
        self.askPassword = askPassword
        self.progress = progress
        self.emit = emit
    }

    private func found(_ photo: Photo) {
        guard reported.insert(photo.url.resolvingSymlinksInPath().path).inserted else { return }
        pending.append(photo)
        // Small batches keep the grid filling up smoothly without redrawing it for every file
        if pending.count >= 200 || Date().timeIntervalSince(lastFlush) > 0.1 { flush() }
    }

    private func flush() {
        lastFlush = Date()
        guard !pending.isEmpty else { return }
        emit(.found(pending))
        pending.removeAll()
    }

    private func retract(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        flush()
        for url in urls { reported.remove(url.resolvingSymlinksInPath().path) }
        emit(.retracted(Set(urls)))
    }

    /// Listed explicitly because macOS has no system type for some of them (mkv, webm…)
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "3gp", "3g2", "avi", "mkv", "webm", "wmv", "asf", "flv",
        "mpg", "mpeg", "m2v", "mts", "m2ts", "ts", "vob", "ogv", "dv", "hevc",
    ]

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .movie) ?? false
    }

    static func isMedia(_ url: URL) -> Bool { isImage(url) || isVideo(url) }

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased()) || isSplitVolume(url)
    }

    /// "zdjecia.7z.001", "zdjecia.zip.002"…: an archive cut into pieces (7-Zip joins them from the first)
    private static func isSplitVolume(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().range(of: #"\.(7z|zip|rar|tar)\.\d{3,}$"#, options: .regularExpression) != nil
    }

    /// "film.part2.rar": a set is unpacked from its first part, so later parts are not archives of their own
    static func isLaterVolume(_ url: URL) -> Bool {
        volumeNumber(url).map { $0.number > 1 } ?? false
    }

    /// The volume number in "film.part3.rar" or "zdjecia.7z.003", and where it sits in the name
    private static func volumeNumber(_ url: URL) -> (number: Int, range: Range<String.Index>)? {
        let name = url.lastPathComponent
        let pattern = isSplitVolume(url) ? #"\d+$"# : #"(?<=\.part)\d+(?=\.rar$)"#
        guard let range = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(name[range]).map { ($0, range) }
    }

    /// "film.part3.rar" → "film.part1.rar", "zdjecia.7z.003" → "zdjecia.7z.001" (same zero padding), if it is there
    private static func firstVolume(of url: URL) -> URL? {
        guard let volume = volumeNumber(url) else { return nil }
        var name = url.lastPathComponent
        let width = name.distance(from: volume.range.lowerBound, to: volume.range.upperBound)
        name.replaceSubrange(volume.range, with: String(repeating: "0", count: width - 1) + "1")
        let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    func scan(_ sources: [URL]) -> ScanResult {
        // A single picked photo or video: show its whole folder and open that file
        if sources.count == 1, let file = sources.first, Self.isMedia(file) {
            let folder = file.deletingLastPathComponent()
            let siblings = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? [])
                .filter(Self.isMedia)
            result.openURL = file
            found(Photo(url: file, group: folder.lastPathComponent))
            flush()
            for sibling in siblings { found(Photo(url: sibling, group: folder.lastPathComponent)) }
            flush()
            return result
        }

        for source in sources where !shouldStop() {
            add(source, group: "", depth: 0)
        }
        flush()
        unpackQueuedArchives()
        flush()
        return result
    }

    private func enqueue(_ archive: URL, group: String, depth: Int) {
        guard depth < Self.maxArchiveDepth, !Self.isLaterVolume(archive) else { return }
        archiveQueue.append((archive, group, depth))
        flush()
        emit(.archive(group, .waiting))
    }

    /// Archives found inside unpacked archives join the queue and are handled by the same loop
    private func unpackQueuedArchives() {
        while !archiveQueue.isEmpty, !shouldStop() {
            var next = 0
            if let preferred = preferredGroup(), !preferred.isEmpty,
               let index = archiveQueue.firstIndex(where: {
                   $0.group == preferred || $0.group.hasPrefix(preferred + "/") || preferred.hasPrefix($0.group + "/")
               }) {
                next = index
            }
            let item = archiveQueue.remove(at: next)
            scanArchive(item.url, group: item.group, depth: item.depth)
        }
    }

    /// Display order: by folder, then by name (natural order: 2 before 10)
    static func inOrder(_ a: Photo, _ b: Photo) -> Bool {
        if a.group != b.group {
            return a.group.localizedStandardCompare(b.group) == .orderedAscending
        }
        return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
    }

    private func join(_ group: String, _ name: String, separator: String = "/") -> String {
        if name.isEmpty { return group }
        return group.isEmpty ? name : group + separator + name
    }

    private func add(_ url: URL, group: String, depth: Int) {
        if Self.isDirectory(url) {
            scanFolder(url, group: join(group, url.lastPathComponent), depth: depth)
        } else if Self.isMedia(url) {
            found(Photo(url: url, group: group.isEmpty ? url.deletingLastPathComponent().lastPathComponent : group))
        } else if Self.isArchive(url) {
            if Self.isLaterVolume(url) {
                // Picked "part2" of a set: unpack the set from its first part
                if let first = Self.firstVolume(of: url) {
                    enqueue(first, group: join(group, first.lastPathComponent), depth: depth)
                } else {
                    result.errors.append(String(localized: "\(url.lastPathComponent): to dalsza część archiwum wieloczęściowego – brakuje części 1"))
                }
            } else {
                enqueue(url, group: join(group, url.lastPathComponent), depth: depth)
            }
        } else {
            result.errors.append(String(localized: "\(url.lastPathComponent): to nie jest zdjęcie, film ani obsługiwane archiwum"))
        }
    }

    private func scanFolder(_ folder: URL, group: String, depth: Int, temporary: Bool = false) {
        // Resolve /var → /private/var etc. so relative paths below line up with what the enumerator returns
        let folder = folder.resolvingSymlinksInPath()
        let rootComponents = folder.pathComponents.count
        progress(String(localized: "Przeszukuję \(group)…"))
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in walker {
            if shouldStop() { return }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if url.lastPathComponent == "__MACOSX" { walker.skipDescendants() }
                continue
            }
            let relativeDir = url.deletingLastPathComponent().resolvingSymlinksInPath()
                .pathComponents.dropFirst(rootComponents).joined(separator: "/")
            let photoGroup = join(group, relativeDir)
            if Self.isMedia(url) {
                found(Photo(url: url, group: photoGroup, isTemporary: temporary))
            } else if Self.isArchive(url) {
                enqueue(url, group: join(photoGroup, url.lastPathComponent), depth: depth)
            }
        }
    }

    private func scanArchive(_ archive: URL, group: String, depth: Int) {
        guard depth < Self.maxArchiveDepth, !shouldStop() else { return }
        let name = archive.lastPathComponent
        flush()
        emit(.archive(group, .unpacking))
        var unpacked = false
        let errorsBefore = result.errors.count
        defer {
            flush()
            if !unpacked {
                let reason = result.errors.dropFirst(errorsBefore).last
                    .map { $0.hasPrefix(name + ": ") ? String($0.dropFirst(name.count + 2)) : $0 }
                emit(.archiveFailed(group, reason: reason ?? String(localized: "nie udało się rozpakować")))
            }
            emit(.archive(group, unpacked ? .done : .failed))
        }
        progress(String(localized: "Rozpakowuję \(name)…"))
        guard let root = extractionRoot() else {
            result.errors.append(String(localized: "\(name): pominięto – nie udało się utworzyć bezpiecznego dysku w pamięci RAM"))
            return
        }
        let base = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        switch extract(archive, into: base, group: group) {
        case .done(let dir):
            unpacked = true
            scanFolder(dir, group: group, depth: depth + 1, temporary: true)
        case .needsPassword(let tool):
            if let dir = extractWithPassword(archive, tool: tool, into: base, group: group) {
                unpacked = true
                scanFolder(dir, group: group, depth: depth + 1, temporary: true)
            }
        case .unsupportedEncryption:
            result.errors.append(String(localized: "\(name): archiwum jest zaszyfrowane metodą, której nie obsługuje wbudowane narzędzie macOS. Zainstaluj 7-Zip (w Terminalu: brew install sevenzip) i otwórz je ponownie."))
        case .failed(let partial):
            if Self.ramDiskFull() {
                if partial != nil { unpacked = true }
                result.errors.append(partial != nil
                    ? String(localized: "\(name): zabrakło miejsca na dysku RAM – rozpakowano tylko część. Zwiększ pojemność w menu Bezpieczeństwo › Pojemność dysku RAM i otwórz folder ponownie.")
                    : String(localized: "\(name): zabrakło miejsca na dysku RAM. Zwiększ pojemność w menu Bezpieczeństwo › Pojemność dysku RAM i otwórz folder ponownie."))
                if let partial { scanFolder(partial, group: group, depth: depth + 1, temporary: true) }
            } else if let partial {
                unpacked = true
                result.errors.append(String(localized: "\(name): rozpakowano tylko część (archiwum może być uszkodzone)"))
                scanFolder(partial, group: group, depth: depth + 1, temporary: true)
            } else {
                result.errors.append(String(localized: "\(name): nie udało się rozpakować (uszkodzone lub nieobsługiwane archiwum)"))
            }
        }
    }

    /// The RAM disk has (almost) no room left: an unpacking that failed did so for lack of space
    private static func ramDiskFull() -> Bool {
        guard let usage = SecureTemp.shared.usage() else { return false }
        return usage.total - usage.used < SecureTemp.nearlyFull
    }

    // MARK: Extraction

    private struct Tool {
        let exe: String
        /// Arguments for unpacking into `dir`; `withPassword` means the password arrives on stdin
        let args: (_ dir: URL, _ withPassword: Bool) -> [String]
        /// Whether the tool reads a password from stdin (unar only takes it on the command line)
        let stdinPassword: Bool
        /// bsdtar -v names each entry on stderr once it is fully written, so it can be shown right away
        var streams = false
    }

    private enum Outcome {
        case done(URL)
        case needsPassword(Tool)
        case unsupportedEncryption
        case failed(partial: URL?)
    }

    /// bsdtar (built into macOS: zip, rar, 7z, tar…) first, then 7-Zip / unar / unrar if installed.
    /// Passwords are never put on the command line, where other processes could read them.
    private func tools(for archive: URL) -> [Tool] {
        let a = archive.path
        let candidates: [(String, Bool, (URL, Bool) -> [String])] = [
            ("/usr/bin/bsdtar", true, { dir, _ in ["-xvf", a, "-C", dir.path] }),
            // -p- without a password: 7-Zip then reports the need for one instead of prompting on stdout
            ("7zz", true, { dir, pw in ["x", "-y", "-bso0", "-bsp0"] + (pw ? [] : ["-p-"]) + ["-o" + dir.path, a] }),
            ("7z", true, { dir, pw in ["x", "-y", "-bso0", "-bsp0"] + (pw ? [] : ["-p-"]) + ["-o" + dir.path, a] }),
            ("unar", false, { dir, _ in ["-q", "-f", "-o", dir.path, a] }),
            ("unrar", true, { dir, pw in ["x", "-o+"] + (pw ? [] : ["-p-"]) + [a, dir.path + "/"] }),
        ]
        return candidates.compactMap { tool, stdin, args in
            locate(tool).map { Tool(exe: $0, args: args, stdinPassword: stdin, streams: tool == "/usr/bin/bsdtar") }
        }
    }

    private func extract(_ archive: URL, into base: URL, group: String) -> Outcome {
        var partial: URL?
        var partialShown: [URL] = []
        var encrypted = false
        for (i, tool) in tools(for: archive).enumerated() {
            let dir = base.appendingPathComponent("\(i)", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let (ok, message, shown) = run(tool, dir: dir, password: nil, group: group)
            if ok { return .done(dir) }
            defer { if partial != dir { retract(shown) } }
            if Self.asksForPassword(message) {
                if tool.stdinPassword {
                    try? fm.removeItem(at: dir)
                    // An earlier tool's leftovers from the encrypted entries are broken files, not photos
                    if let partial {
                        retract(partialShown)
                        try? fm.removeItem(at: partial)
                    }
                    return .needsPassword(tool)
                }
                encrypted = true
            } else if Self.isEncrypted(message) {
                encrypted = true
            }
            if partial == nil, let items = try? fm.contentsOfDirectory(atPath: dir.path), !items.isEmpty {
                partial = dir
                partialShown = shown
            } else if partial != dir {
                try? fm.removeItem(at: dir)
            }
        }
        if encrypted, partial == nil { return .unsupportedEncryption }
        return .failed(partial: partial)
    }

    private func extractWithPassword(_ archive: URL, tool: Tool, into base: URL, group: String) -> URL? {
        let name = archive.lastPathComponent
        func attempt(_ password: String) -> URL? {
            let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let (ok, _, shown) = run(tool, dir: dir, password: password, group: group)
            if ok { return dir }
            retract(shown)
            try? fm.removeItem(at: dir)
            return nil
        }
        // Several archives often share one password, so try the ones already entered first
        for password in PasswordMemory.shared.all {
            if let dir = attempt(password) { return dir }
        }
        if skipAllPasswords {
            result.errors.append(String(localized: "\(name): pominięto archiwum chronione hasłem"))
            return nil
        }
        var wrong = false
        while true {
            progress(String(localized: "Czekam na hasło do \(name)…"))
            switch askPassword(name, wrong) {
            case .password(let password):
                progress(String(localized: "Rozpakowuję \(name)…"))
                if let dir = attempt(password) {
                    PasswordMemory.shared.add(password)
                    return dir
                }
                wrong = true
            case .skip:
                result.errors.append(String(localized: "\(name): pominięto archiwum chronione hasłem"))
                return nil
            case .skipAll:
                skipAllPasswords = true
                result.errors.append(String(localized: "\(name): pominięto archiwum chronione hasłem"))
                return nil
            }
        }
    }

    private static func asksForPassword(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("passphrase") || m.contains("password")
    }

    private static func isEncrypted(_ message: String) -> Bool {
        message.lowercased().contains("encrypt")
    }

    private func locate(_ tool: String) -> String? { Subprocess.locate(tool) }

    /// Runs one unpacking attempt; with a streaming tool every finished photo is reported immediately.
    /// Returns success, the tool's messages and the photos reported during this attempt.
    private func run(_ tool: Tool, dir: URL, password: String?, group: String) -> (Bool, String, [URL]) {
        var shown: [URL] = []
        let root = dir.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents.count
        let onLine: ((String) -> Void)? = tool.streams ? { line in
            guard line.hasPrefix("x ") else { return }
            let url = root.appendingPathComponent(String(line.dropFirst(2))).resolvingSymlinksInPath()
            // Only real files that stay inside the unpacking folder (no links pointing elsewhere)
            guard Self.isMedia(url), url.path.hasPrefix(root.path + "/"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return }
            let relativeDir = url.deletingLastPathComponent().pathComponents.dropFirst(rootComponents).joined(separator: "/")
            let before = self.reported.count
            self.found(Photo(url: url, group: self.join(group, relativeDir), isTemporary: true))
            if self.reported.count > before { shown.append(url) }
        } : nil
        // UTF-8 so bsdtar prints names with Polish letters as they are instead of escaping them
        let result = Subprocess.runBlocking(tool.exe, tool.args(dir, password != nil), input: password,
                                            environment: ["LC_ALL": "en_US.UTF-8"], onStderrLine: onLine)
        return (result.ok, result.stderr, shown)
    }
}

/// Passwords typed in this session, kept only in memory so a set of archives with
/// the same password asks just once. Gone when the app quits.
final class PasswordMemory {
    static let shared = PasswordMemory()
    private let lock = NSLock()
    private var passwords: [String] = []

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return passwords
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        passwords.removeAll()
    }

    func add(_ password: String) {
        lock.lock(); defer { lock.unlock() }
        if !passwords.contains(password) { passwords.append(password) }
    }
}
