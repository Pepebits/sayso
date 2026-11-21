import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import IOKit.hid
import SaySoCore
import Speech

/// Permisos del sistema que necesita el dictado.
public enum SystemPermissions {
    /// Indica si el permiso está concedido. No muestra nada al usuario.
    public static func status(_ kind: SystemPermissionKind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            // En el sandbox no se usa ni se puede pedir: preguntarlo ya lo apunta como infracción.
            return BuildFlavor.isAppStore ? false : AXIsProcessTrusted()
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        case .speechRecognition:
            return SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    /// Pide el permiso. Si ya se denegó, abre el panel de Ajustes del Sistema.
    public static func request(_ kind: SystemPermissionKind) async -> Bool {
        if status(kind) { return true }
        switch kind {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                return await AVCaptureDevice.requestAccess(for: .audio)
            }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            if CGRequestListenEventAccess() { return true }
            // Si macOS no enseña su aviso (ya lo enseñó una vez, o quedó una entrada antigua), la
            // app puede no figurar en la lista de Ajustes del Sistema. Estas dos llamadas la
            // registran ahí para que el usuario pueda activarla a mano.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            registerForInputMonitoring()
        case .speechRecognition:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                return await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
                }
            }
        }
        await MainActor.run { openSettings(for: kind) }
        return false
    }

    /// Lo que macOS tiene apuntado para esta app, para el registro: distingue «nunca preguntado»
    /// de «denegado», que desde fuera se ven igual.
    public static func diagnosis() -> String {
        func hid(_ type: IOHIDRequestType) -> String {
            switch IOHIDCheckAccess(type) {
            case kIOHIDAccessTypeGranted: return "concedido"
            case kIOHIDAccessTypeDenied: return "denegado"
            default: return "sin preguntar"
            }
        }
        let mic = ["sin preguntar", "restringido", "denegado", "concedido"][Int(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)]
        let accessibility = BuildFlavor.isAppStore ? "no-aplica" : (AXIsProcessTrusted() ? "concedido" : "no")
        return "accesibilidad=\(accessibility) "
            + "escuchar-teclado=\(hid(kIOHIDRequestTypeListenEvent)) (preflight=\(CGPreflightListenEventAccess())) "
            + "enviar-teclado=\(hid(kIOHIDRequestTypePostEvent)) micrófono=\(mic) "
            + "ruta=\(Bundle.main.bundlePath)"
    }

    /// Intenta crear una captura de teclado y la suelta: sin permiso no recibe nada, pero el intento
    /// hace que macOS apunte la app en la lista de Supervisión de entrada.
    private static func registerForInputMonitoring() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                          userInfo: nil) else { return }
        CFMachPortInvalidate(tap)
    }

    /// URL del panel de Privacidad correspondiente.
    public static func settingsURL(for kind: SystemPermissionKind) -> URL {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Abre Ajustes del Sistema en el panel del permiso.
    @MainActor
    public static func openSettings(for kind: SystemPermissionKind) {
        NSWorkspace.shared.open(settingsURL(for: kind))
    }
}
