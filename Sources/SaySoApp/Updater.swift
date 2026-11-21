import Foundation
import SaySoUI
import Sparkle

/// Actualizaciones con Sparkle: un appcast firmado con EdDSA en la última release de GitHub.
///
/// Solo se activa en la app publicada. Las compilaciones de `scripts/make-app.sh` llevan
/// `SaySoDevBuild` en el Info.plist y no se actualizan solas: si no, Sparkle sustituiría la
/// compilación de desarrollo por la última versión publicada.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let devBuild = info["SaySoDevBuild"] as? Bool ?? false
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        if devBuild || key.isEmpty || ProcessInfo.processInfo.environment["SAYSO_NO_UPDATES"] != nil {
            controller = nil
        } else {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var state: UpdateState {
        guard let updater = controller?.updater else { return .unavailable }
        return .ready(automatic: updater.automaticallyChecksForUpdates, lastCheck: updater.lastUpdateCheckDate)
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func check() { controller?.checkForUpdates(nil) }

    func setAutomatic(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
}
