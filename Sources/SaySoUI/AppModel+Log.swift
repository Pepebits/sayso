import Foundation
import SaySoCore

// Qué apunta el registro. Se engancha a los cambios de estado del modelo, así que cualquier parte
// de la app que cambie un estado deja rastro sin tener que acordarse de escribirlo.
// No se apuntan nombres de cuentas, lo que se dicta ni el contenido de los mensajes.

extension AppModel {
    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        let entry = LogEntry(level: level, category: category, message: message)
        logEntries.append(entry)
        if logEntries.count > Self.logLimit { logEntries.removeFirst(logEntries.count - Self.logLimit) }
        logSink?(entry)
    }

    func logTelegramBot(from old: ConnectionStatus) {
        guard telegramStatus != old else { return }
        switch telegramStatus {
        case .connected: log(.info, LogCategory.telegram, tr("Bot conectado"))
        case let .failed(reason): log(.error, LogCategory.telegram, tr("Bot de Telegram: %@", reason))
        case .disconnected:
            if case .connected = old { log(.info, LogCategory.telegram, tr("Bot desconectado")) }
        case .connecting: break
        }
    }

    func logTelegramUser(from old: TelegramUserState) {
        guard telegramUser != old else { return }
        switch telegramUser {
        case .ready:
            if !old.isReady { log(.info, LogCategory.telegram, tr("Cuenta de Telegram conectada")) }
        case let .failed(reason): log(.error, LogCategory.telegram, tr("Cuenta de Telegram: %@", reason))
        case .off:
            if old.isReady { log(.info, LogCategory.telegram, tr("Cuenta de Telegram desconectada")) }
        case .connecting, .waitingPhone, .waitingCode, .waitingPassword: break
        }
    }

    func logComputer(from old: ComputerState) {
        guard computerState != old else { return }
        switch computerState {
        case .running: log(.info, LogCategory.computer, tr("Máquina Linux en marcha"))
        case .paused: log(.info, LogCategory.computer, tr("Máquina Linux en pausa"))
        case .stopped:
            switch old {
            case .running, .paused, .starting: log(.info, LogCategory.computer, tr("Máquina Linux apagada"))
            default: break
            }
        case let .failed(reason): log(.error, LogCategory.computer, tr("Máquina Linux: %@", reason))
        case .notInstalled, .preparing, .starting: break
        }
    }

    func logDesktop(from old: DesktopState) {
        guard desktopState != old, case let .failed(reason) = desktopState else { return }
        log(.error, LogCategory.computer, tr("Escritorio de la máquina: %@", reason))
    }

    func logDictation(from old: DictationPhase) {
        guard dictationPhase != old else { return }
        switch dictationPhase {
        case let .failed(reason):
            log(.error, LogCategory.dictation, reason)
        case .listening, .agentListening:
            // Una vez por arranque: confirma que la tecla llega a la app.
            guard !loggedFirstListen else { return }
            loggedFirstListen = true
            log(.info, LogCategory.dictation, tr("Atajo %@ detectado: el dictado responde", dictation.shortcut.symbol))
        default:
            break
        }
    }

    func logPlugins(from old: [PluginRow]) {
        let before = Dictionary(old.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        for row in plugins {
            guard case let .failed(reason) = row.state, before[row.id] != row.state else { continue }
            log(.error, LogCategory.plugins, "\(row.config.name): \(reason)")
        }
    }
}
