import SwiftUI
import LocalAuthentication

/// Unlocking the window with Touch ID or the Mac's own password. Nothing is stored: macOS checks the
/// fingerprint or password itself, so the app has no password of its own to keep or forget.
@MainActor enum AppUnlock {
    static func unlock(_ done: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Anuluj")
        var error: NSError?
        // Touch ID when there is one, otherwise (or after failed attempts) the Mac password
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            done(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: String(localized: "odblokować przeglądane dane")) { success, _ in
            DispatchQueue.main.async { done(success) }
        }
    }
}

/// Covers the whole window while locked: nothing of the photos, names or folders shows through
struct LockScreen: View {
    let unlock: () -> Void
    let wipe: () -> Void

    var body: some View {
        ZStack {
            Color(white: 0.07)
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 54, weight: .regular))
                    .foregroundStyle(.white)
                Text("Migawka jest zablokowana")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Przeglądane dane są ukryte. Odblokuj Touch ID albo hasłem Maca.")
                    .foregroundStyle(Color(white: 0.7))
                    .multilineTextAlignment(.center)
                Button(action: unlock) {
                    Label("Odblokuj", systemImage: "touchid")
                        .padding(.horizontal, 18).padding(.vertical, 4)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
                Button("Wyczyść dane i zamknij", action: wipe)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(white: 0.6))
                    .font(.callout)
            }
            .padding(40)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .contentShape(Rectangle())
    }
}
