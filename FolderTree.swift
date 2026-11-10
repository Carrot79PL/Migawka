import SwiftUI
import AppKit

/// One folder (or archive) in the sidebar tree, built from the photos' group paths.
struct FolderNode: Identifiable, Hashable {
    /// Full group path, e.g. "Wakacje/zdjecia.zip/Plaża"
    let id: String
    let name: String
    let isArchive: Bool
    /// For archives: waiting, being unpacked, done or failed
    let state: Scanner.ArchiveState?
    /// Photos and videos in this folder and everything below it
    let count: Int
    /// nil for a leaf, so the outline shows no disclosure arrow
    let children: [FolderNode]?

    static func tree(from photos: [Photo], archives: [String: Scanner.ArchiveState] = [:]) -> [FolderNode] {
        var direct: [String: Int] = [:]
        for photo in photos { direct[photo.group, default: 0] += 1 }

        // Every path prefix becomes a node, even folders that hold only subfolders,
        // and archives show up before anything is unpacked from them
        var childNames: [String: Set<String>] = [:]
        for group in Set(direct.keys).union(archives.keys) {
            let parts = group.split(separator: "/").map(String.init)
            for i in parts.indices {
                let parent = parts[..<i].joined(separator: "/")
                childNames[parent, default: []].insert(parts[i])
            }
        }

        func build(_ path: String) -> [FolderNode] {
            (childNames[path] ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { name in
                    let id = path.isEmpty ? name : path + "/" + name
                    let kids = build(id)
                    let count = (direct[id] ?? 0) + kids.reduce(0) { $0 + $1.count }
                    return FolderNode(id: id, name: name, isArchive: Scanner.isArchive(URL(fileURLWithPath: name)),
                                      state: archives[id], count: count, children: kids.isEmpty ? nil : kids)
                }
        }
        return build("")
    }
}

struct FolderSidebar: View {
    @ObservedObject var gallery: Gallery
    @ObservedObject var security: SecuritySettings
    @ObservedObject private var library = PhotoLibraryModel.shared
    @AppStorage("librarySectionExpanded") private var libraryExpanded = true
    @Namespace private var kindSpace

    var body: some View {
        // Stacked rather than overlaid, so a long tree scrolls above the card instead of underneath it
        VStack(spacing: 0) {
            kindChips
            folderList
            SessionCard(security: security) { gallery.wipe() }
                .padding(10)
        }
        .searchable(text: $gallery.searchText, placement: .sidebar, prompt: "Szukaj w nazwach")
    }

    private var folderList: some View {
        List(selection: $gallery.folderFilter) {
            Label {
                HStack {
                    Text("Wszystkie")
                    Spacer()
                    Text("\(gallery.photos.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            } icon: {
                Image(systemName: "photo.on.rectangle")
            }
            .tag("")

            Section("Biblioteka Zdjęć", isExpanded: $libraryExpanded) {
                if library.albums.isEmpty {
                    Button { gallery.openLibrary() } label: {
                        Label(library.denied ? "Brak dostępu – pokaż jak włączyć" : "Połącz z biblioteką Zdjęć",
                              systemImage: "photo.stack")
                    }
                    .buttonStyle(.plain)
                    .help("Zdjęcia i filmy z aplikacji Zdjęcia, także z iCloud")
                } else {
                    ForEach(library.albums) { album in
                        Button { gallery.openLibrary(album) } label: {
                            Label {
                                HStack {
                                    Text(album.title).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("\(album.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                            } icon: {
                                Image(systemName: album.symbol)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Otwórz w Migawce (zastępuje bieżące źródło)")
                    }
                }
            }

            Section("Foldery") {
                OutlineGroup(gallery.tree, children: \.children) { node in
                    Label {
                        HStack {
                            Text(node.name).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(node.state == .waiting ? .secondary : .primary)
                            Spacer()
                            switch node.state {
                            case .waiting:
                                Text("czeka").foregroundStyle(.secondary)
                                    .help("Czeka na rozpakowanie – kliknij, aby rozpakować je jako następne")
                            case .unpacking:
                                ProgressView().controlSize(.mini)
                                Text("\(node.count)").foregroundStyle(.secondary).monospacedDigit()
                            case .failed where node.count == 0:
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                    .help(String(localized: "Nie udało się rozpakować: ") + (gallery.archiveProblems[node.id] ?? String(localized: "szczegóły pod przyciskiem Problemy")))
                            default:
                                Text("\(node.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    } icon: {
                        Image(systemName: node.state == .waiting ? "clock" : node.isArchive ? "archivebox" : "folder")
                    }
                    .help(node.id)
                    .tag(node.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Quick filters: everything, photos, films, favourites – a capsule like the viewer's, with the
    /// highlight sliding to the chosen one
    private var kindChips: some View {
        HStack(spacing: 2) {
            ForEach(Gallery.KindFilter.allCases) { kind in
                let selected = gallery.kindFilter == kind
                Button { gallery.kindFilter = kind } label: {
                    Image(systemName: selected ? kind.symbol + ".fill" : kind.symbol)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .background {
                            if selected {
                                Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "kind", in: kindSpace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(kind.name)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: gallery.kindFilter)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// "Protected session" card: how full the RAM disk is, when the data will be wiped, and wiping it now
struct SessionCard: View {
    @ObservedObject var security: SecuritySettings
    let wipe: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let usage = SecureTemp.shared.usage()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.green)
                    Text("Sesja chroniona").fontWeight(.medium)
                    Spacer()
                    Button("Wyczyść", action: wipe)
                        .buttonStyle(.borderless)
                        .help("Zamknij i wyczyść dane teraz (⇧⌘W)")
                }
                if let usage, usage.total > 0 {
                    let fraction = Double(usage.used) / Double(usage.total)
                    ProgressView(value: fraction)
                        .tint(fraction > 0.9 ? .red : fraction > 0.7 ? .orange : .accentColor)
                    Text("Dysk RAM: \(Self.format(usage.used)) z \(Self.format(usage.total)), wolne \(Self.format(usage.total - usage.used))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if usage.total - usage.used < SecureTemp.nearlyFull {
                        Text("Dysk RAM jest pełny – zwiększ pojemność w menu Bezpieczeństwo")
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("Dysk RAM: przygotowuję…").foregroundStyle(.secondary)
                }
                Text(wipeText).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .help(String(localized: "Rozpakowane archiwa i przygotowane filmy są wyłącznie w pamięci RAM i znikają przy czyszczeniu, otwarciu nowego źródła i zamknięciu aplikacji."))
        }
    }

    private var wipeText: String {
        guard security.idleMinutes > 0 else {
            return security.wipeOnLock ? String(localized: "Czyści przy blokadzie ekranu") : String(localized: "Automatyczne czyszczenie wyłączone")
        }
        let limit = Double(security.idleMinutes * 60)
        let anyInput = unsafeBitCast(UInt32.max, to: CGEventType.self)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        // A countdown only once the Mac has been left alone for a while
        guard idle >= 30 else { return String(localized: "Czyści po \(security.idleMinutes) min bezczynności") }
        let left = max(Int(limit - idle), 0)
        return String(format: String(localized: "Wyczyszczę za %d:%02d bez ruchu"), left / 60, left % 60)
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
