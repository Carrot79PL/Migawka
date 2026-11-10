import SwiftUI
import AppKit
import CoreGraphics

/// Security options; stored in the app's preferences (only these switches, never any file names).
@MainActor
final class SecuritySettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Wipe everything when the screen locks, the Mac sleeps or the user switches account
    @Published var wipeOnLock: Bool { didSet { defaults.set(wipeOnLock, forKey: "wipeOnLock") } }
    /// Minutes without keyboard/mouse activity (anywhere on the Mac) before wiping; 0 = never
    @Published var idleMinutes: Int { didSet { defaults.set(idleMinutes, forKey: "idleMinutes") } }
    /// Hide the window from screenshots, screen recording and screen sharing
    @Published var blockScreenCapture: Bool {
        didSet { defaults.set(blockScreenCapture, forKey: "blockScreenCapture"); applyToWindows() }
    }
    /// Minutes without activity before the window is covered and needs Touch ID or the Mac password; 0 = never
    @Published var lockMinutes: Int { didSet { defaults.set(lockMinutes, forKey: "lockMinutes") } }
    /// Also lock whenever another app comes to the front
    @Published var lockOnLeave: Bool { didSet { defaults.set(lockOnLeave, forKey: "lockOnLeave") } }
    /// How much of the Mac's memory the RAM disk may take (its memory is used only as files are unpacked)
    @Published var ramDiskPercent: Int { didSet { defaults.set(ramDiskPercent, forKey: "ramDiskPercent") } }

    static func gigabytes(_ percent: Int) -> String {
        let bytes = Int64(ProcessInfo.processInfo.physicalMemory / 100 * UInt64(percent))
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    init() {
        defaults.register(defaults: ["wipeOnLock": true, "idleMinutes": 10, "blockScreenCapture": true,
                                     "lockMinutes": 3, "lockOnLeave": false])
        lockMinutes = defaults.integer(forKey: "lockMinutes")
        lockOnLeave = defaults.bool(forKey: "lockOnLeave")
        wipeOnLock = defaults.bool(forKey: "wipeOnLock")
        idleMinutes = defaults.integer(forKey: "idleMinutes")
        blockScreenCapture = defaults.bool(forKey: "blockScreenCapture")
        ramDiskPercent = SecureTemp.capacityPercent
    }

    func applyToWindows() {
        for window in NSApp.windows {
            window.sharingType = blockScreenCapture ? .none : .readOnly
        }
    }
}

/// Locks the window, and later wipes the loaded data, when the user walks away from the Mac.
@MainActor
final class SecurityMonitor {
    private let settings: SecuritySettings
    private let wipe: () -> Void
    private let lock: () -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?

    init(settings: SecuritySettings, wipe: @escaping () -> Void, lock: @escaping () -> Void) {
        self.settings = settings
        self.wipe = wipe
        self.lock = lock

        let lockEvents: [(NotificationCenter, Notification.Name)] = [
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screensaver.didstart")),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
        ]
        for (center, name) in lockEvents {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.settings.wipeOnLock else { return }
                    self.wipe()
                }
            }
            observers.append((center, token))
        }

        // Another app in front: lock, if chosen
        let leave = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.lockOnLeave else { return }
                self.lock()
            }
        }
        observers.append((NotificationCenter.default, leave))

        // New windows (password prompt, open panel…) get the screen-capture setting too
        let token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                           queue: .main) { [weak settings] _ in
            MainActor.assumeIsolated { settings?.applyToWindows() }
        }
        observers.append((NotificationCenter.default, token))

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    private func checkIdle() {
        // Time since the last keyboard or mouse event in the whole login session
        let anyInput = unsafeBitCast(UInt32.max, to: CGEventType.self)  // kCGAnyInputEventType
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if settings.idleMinutes > 0, idle >= Double(settings.idleMinutes * 60) {
            wipe()
        } else if settings.lockMinutes > 0, idle >= Double(settings.lockMinutes * 60) {
            lock()
        }
    }
}

struct SecurityCommands: Commands {
    @ObservedObject var settings: SecuritySettings
    let wipeNow: () -> Void
    let lockNow: () -> Void

    var body: some Commands {
        CommandMenu("Bezpieczeństwo") {
            Button("Zamknij i wyczyść dane teraz", action: wipeNow)
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Zablokuj teraz", action: lockNow)
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Picker("Blokuj po bezczynności (Touch ID lub hasło Maca)", selection: $settings.lockMinutes) {
                Text("1 minucie").tag(1)
                Text("3 minutach").tag(3)
                Text("5 minutach").tag(5)
                Text("10 minutach").tag(10)
                Text("Nigdy").tag(0)
            }
            Toggle("Blokuj po przejściu do innej aplikacji", isOn: $settings.lockOnLeave)
            Divider()
            Toggle("Czyść po zablokowaniu ekranu lub uśpieniu", isOn: $settings.wipeOnLock)
            Picker("Czyść po bezczynności", selection: $settings.idleMinutes) {
                Text("2 minutach").tag(2)
                Text("5 minutach").tag(5)
                Text("10 minutach").tag(10)
                Text("30 minutach").tag(30)
                Text("Nigdy").tag(0)
            }
            Divider()
            Toggle("Blokuj zrzuty i udostępnianie ekranu", isOn: $settings.blockScreenCapture)
            Divider()
            Picker("Pojemność dysku RAM (od następnego otwarcia)", selection: $settings.ramDiskPercent) {
                ForEach([25, 50, 75], id: \.self) { percent in
                    Text(String(localized: "\(percent)% pamięci – \(SecuritySettings.gigabytes(percent))")).tag(percent)
                }
            }
        }
    }
}
