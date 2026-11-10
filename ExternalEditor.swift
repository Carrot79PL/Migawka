import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Opening a photo in another program (Photoshop, Pixelmator, Preview…) for editing.
/// Only for the user's own files: unpacked archive contents live on the RAM disk and must not reach
/// programs that keep their own copies, caches, autosaves and recent-file lists on disk.
@MainActor enum ExternalEditor {
    /// Programs that can open the file, the default one first; this app itself is left out
    static func apps(for url: URL) -> [URL] {
        let me = Bundle.main.bundleURL.standardizedFileURL
        var result: [URL] = []
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: url) { result.append(preferred) }
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) where !result.contains(app) { result.append(app) }
        return result.filter {
            $0.standardizedFileURL != me && Bundle(url: $0)?.bundleIdentifier?.hasPrefix("local.przegladarka") != true
        }
    }

    /// Editors (programs that declare they edit this kind of file, e.g. Photoshop) and the rest
    static func groupedApps(for url: URL) -> (editors: [URL], others: [URL]) {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        var editors: [URL] = [], others: [URL] = []
        for app in apps(for: url) {
            if let type, edits(app, type: type, ext: url.pathExtension.lowercased()) { editors.append(app) } else { others.append(app) }
        }
        return (editors, others)
    }

    /// Reads the program's own list of file types it handles and the role it claims for them
    private static func edits(_ app: URL, type: UTType, ext: String) -> Bool {
        guard let types = Bundle(url: app)?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        for entry in types where (entry["CFBundleTypeRole"] as? String) == "Editor" {
            let utis = (entry["LSItemContentTypes"] as? [String] ?? []).compactMap(UTType.init)
            if utis.contains(where: { type.conforms(to: $0) && $0 != .data && $0 != .item && $0 != .content }) { return true }
            if (entry["CFBundleTypeExtensions"] as? [String] ?? []).map({ $0.lowercased() }).contains(ext) { return true }
        }
        return false
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(of app: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    static func open(_ photo: Photo, with app: URL, gallery: Gallery) {
        guard !photo.isTemporary else { return }
        gallery.watchForEdits(photo.url)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([photo.url], withApplicationAt: app, configuration: configuration)
    }

    /// Any program, picked by the user
    static func chooseApp(for photo: Photo, gallery: Gallery) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Wybierz program do edycji")
        panel.prompt = String(localized: "Edytuj")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        let chosen = panel.runModal() == .OK ? panel.url : nil
        SecureTemp.forgetRecentFolders()  // the panel remembers its last folder in the app's settings
        if let chosen { open(photo, with: chosen, gallery: gallery) }
    }
}

/// "Edytuj w…": the programs as a menu (top bar, Image menu)
struct EditInMenuItems: View {
    let photo: Photo?
    @ObservedObject var gallery: Gallery

    var body: some View {
        if let photo, !photo.isVideo {
            if photo.isTemporary {
                Text("Niedostępne dla plików z archiwów i biblioteki Zdjęć (chronione dane zostają w pamięci RAM)")
            } else {
                let apps = ExternalEditor.groupedApps(for: photo.url)
                ForEach(apps.editors, id: \.self) { appButton($0, photo: photo) }
                if !apps.others.isEmpty {
                    Menu("Pozostałe programy") {
                        ForEach(apps.others, id: \.self) { appButton($0, photo: photo) }
                    }
                }
                Divider()
                Button("Inny program…") { ExternalEditor.chooseApp(for: photo, gallery: gallery) }
            }
        } else {
            Text("Otwórz zdjęcie, aby je edytować")
        }
    }

    private func appButton(_ app: URL, photo: Photo) -> some View {
        Button { ExternalEditor.open(photo, with: app, gallery: gallery) } label: {
            Label { Text(ExternalEditor.name(of: app)) } icon: { Image(nsImage: ExternalEditor.icon(of: app)) }
        }
    }
}

extension ExternalEditor {
    /// The same choices as an AppKit submenu, for the grid's right-click menu
    static func submenu(for photo: Photo, gallery: Gallery) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Edytuj w"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        if photo.isTemporary {
            let note = NSMenuItem(title: String(localized: "Niedostępne dla plików z archiwów i biblioteki Zdjęć (chronione dane zostają w pamięci RAM)"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        } else {
            func entry(_ app: URL) -> NSMenuItem {
                let item = ClosureMenuItem(name(of: app)) { MainActor.assumeIsolated { open(photo, with: app, gallery: gallery) } }
                item.image = icon(of: app)
                return item
            }
            let apps = groupedApps(for: photo.url)
            apps.editors.forEach { menu.addItem(entry($0)) }
            if !apps.others.isEmpty {
                let more = NSMenuItem(title: "Pozostałe programy", action: nil, keyEquivalent: "")
                let moreMenu = NSMenu()
                apps.others.forEach { moreMenu.addItem(entry($0)) }
                more.submenu = moreMenu
                menu.addItem(more)
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Inny program…") { MainActor.assumeIsolated { chooseApp(for: photo, gallery: gallery) } })
        }
        menu.autoenablesItems = false
        item.submenu = menu
        return item
    }
}
