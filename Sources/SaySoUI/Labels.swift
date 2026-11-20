import Foundation
import SaySoCore
import SwiftUI

// Textos de la interfaz para los tipos de SaySoCore.

extension PermissionRule {
    var title: String {
        switch self {
        case .allow: return "Permitir"
        case .ask: return "Preguntar"
        case .never: return "Nunca"
        }
    }
}

extension ActivityOutcome {
    var title: String {
        switch self {
        case .allowed: return "Permitida"
        case .denied: return "Denegada"
        case .failed: return "Fallida"
        }
    }
}

extension OptionKeySide {
    var title: String {
        switch self {
        case .left: return "Izquierda"
        case .any: return "Cualquiera"
        case .right: return "Derecha"
        }
    }
}

extension TranscriberEngine {
    var title: String {
        switch self {
        case .whisper: return "Whisper"
        case .apple: return "Apple"
        }
    }

    var detail: String {
        switch self {
        case .whisper: return "WhisperKit en este Mac. Más preciso; descarga el modelo la primera vez."
        case .apple: return "Reconocimiento de voz de Apple en el dispositivo. Sin descargas."
        }
    }
}

extension SystemPermissionKind {
    var title: String {
        switch self {
        case .microphone: return "Micrófono"
        case .accessibility: return "Accesibilidad"
        case .inputMonitoring: return "Supervisión de entrada"
        case .speechRecognition: return "Reconocimiento de voz"
        }
    }

    var detail: String {
        switch self {
        case .microphone: return "Para oírte mientras mantienes la tecla."
        case .accessibility: return "Ya no hace falta."
        case .inputMonitoring: return "Para detectar el atajo del dictado en cualquier app."
        case .speechRecognition: return "Lo necesita el motor de Apple."
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .speechRecognition: return "waveform"
        }
    }
}

extension ProviderKind {
    var title: String {
        switch self {
        case .anthropic: return "API de Anthropic"
        case .openAICompatible: return "Compatible con OpenAI"
        }
    }
}

extension ConnectionStatus {
    /// Texto corto para filas de estado.
    var shortTitle: String {
        switch self {
        case .disconnected: return "Sin conectar"
        case .connecting: return "Conectando…"
        case .connected: return "Conectado"
        case .failed: return "Error"
        }
    }

    var isLinked: Bool {
        switch self {
        case .connecting, .connected: return true
        case .disconnected, .failed: return false
        }
    }
}

extension MacScript {
    var icon: String {
        switch self {
        case .notification: return "bell"
        case .volume: return "speaker.wave.2"
        case .reminder: return "checklist"
        case .readReminders: return "list.bullet.rectangle"
        case .changeReminder: return "checkmark.circle"
        case .note: return "note.text"
        case .calendarToday: return "calendar"
        case .changeCalendar: return "calendar.badge.plus"
        case .openURL: return "link"
        }
    }
}

extension AppModel {
    /// Estado de Telegram en una frase: el bot es el canal y la cuenta es aparte, así que con solo
    /// una de las dos cosas se dice cuál falta en vez de «sin conectar».
    var telegramSummary: String {
        let account = telegramUser.isReady
        switch telegramStatus {
        case let .connected(name): return account ? tr("%@ y tu cuenta", name) : name
        case .connecting: return "Conectando…"
        case .failed: return account ? "Cuenta conectada · error del bot" : "Error del bot"
        case .disconnected: return account ? "Cuenta conectada · falta el bot" : "Sin conectar"
        }
    }
}


public extension View {
    /// Aplica el idioma elegido en Ajustes a los textos que SwiftUI traduce por su cuenta
    /// (`Text("…")`, `Button("…")`, etiquetas de accesibilidad). Los que pasan por `tr()` ya lo
    /// siguen. Sin idioma elegido no toca nada y manda el del sistema.
    @ViewBuilder
    func appLanguage() -> some View {
        if L10n.forcedLanguage != nil {
            environment(\.locale, L10n.locale)
        } else {
            self
        }
    }
}
