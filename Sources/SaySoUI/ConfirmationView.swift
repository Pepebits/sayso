import SaySoCore
import SwiftUI

/// Diálogo «Preguntar» del motor de permisos.
public struct ConfirmationView: View {
    let request: ActionRequest
    let descriptor: ActionDescriptor?
    let onResult: (ConfirmationResult) -> Void
    /// Los botones de permitir se activan con un poco de retraso: un Return o un clic que iban a
    /// otra app no aprueban nada.
    @State private var armed = false
    static let armDelay: UInt64 = 800_000_000

    public init(request: ActionRequest, descriptor: ActionDescriptor?,
                onResult: @escaping (ConfirmationResult) -> Void) {
        self.request = request
        self.descriptor = descriptor
        self.onResult = onResult
    }

    private var title: String { descriptor?.title ?? request.action.rawValue }

    private var icon: String {
        switch request.action.scope {
        case "telegram": return "paperplane"
        case "mac": return "laptopcomputer"
        case "secret": return "key"
        case "plugin": return "puzzlepiece.extension"
        default: return "questionmark"
        }
    }

    /// Lo que dijo el revisor, si la pregunta la fuerza la protección.
    private var guardReason: String? { request.parameters[GuardPolicy.reasonKey] }

    private var sortedParameters: [(key: String, value: String)] {
        request.parameters.filter { $0.key != GuardPolicy.reasonKey }.sorted { $0.key < $1.key }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                IconTile(icon, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("SaySo pide permiso"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                    Text(tr(title))
                        .font(Theme.display(19))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                Bit(size: 9)
            }

            if let guardReason {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.destructive)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Revisa esto con calma")).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                        Text(guardReason).font(Theme.caption).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.destructive, lineWidth: 1.5))
                .accessibilityElement(children: .combine)
            }

            Text(request.summary)
                .font(Theme.text(14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !sortedParameters.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionLabel("Parámetros")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(sortedParameters.enumerated()), id: \.offset) { index, item in
                                if index > 0 { CardDivider() }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tr(item.key))
                                        .font(Theme.mono(11))
                                        .foregroundStyle(Theme.secondary)
                                    Text(item.value.isEmpty ? tr("(vacío)") : item.value)
                                        .font(Theme.mono(12.5))
                                        .foregroundStyle(item.value.isEmpty ? Theme.tertiary : Theme.ink)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, Theme.Space.m)
                                .padding(.vertical, Theme.Space.s)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                if let origin = request.origin, !origin.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(tr("Origen")).foregroundStyle(Theme.secondary)
                        Text(origin).foregroundStyle(Theme.ink).textSelection(.enabled)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(tr("Acción")).foregroundStyle(Theme.secondary)
                    Text(request.action.rawValue).font(Theme.mono(11)).foregroundStyle(Theme.ink)
                }
            }
            .font(Theme.caption)

            HStack(spacing: Theme.Space.s) {
                Button("Denegar") { onResult(.deny) }
                    .buttonStyle(BlockButtonStyle(.destructive))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: Theme.Space.s)
                // Con la protección de por medio, «siempre» no cambiaría nada: solo se ofrece una vez.
                // Ni con la protección de por medio ni con secretos: «siempre» valdría para cualquier
                // comando con cualquier clave. Esa regla solo se cambia a propósito, en Secretos.
                if guardReason == nil, request.action != ComputerAction.useSecrets {
                    Button("Permitir siempre") { onResult(.allowAlways) }
                        .buttonStyle(BlockButtonStyle(.secondary))
                        .help("Cambia la regla de esta acción a Permitir")
                        .disabled(!armed)
                }
                // Sin atajo de teclado: un Return pensado para otra ventana no debe aprobar nada.
                Button("Permitir una vez") { onResult(.allowOnce) }
                    .buttonStyle(BlockButtonStyle(.primary))
                    .disabled(!armed)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .background(Theme.paper)
        .task {
            try? await Task.sleep(nanoseconds: Self.armDelay)
            armed = true
        }
    }
}
