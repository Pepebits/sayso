import SaySoCore
import SwiftUI

/// Diálogo «Preguntar» del motor de permisos.
public struct ConfirmationView: View {
    let request: ActionRequest
    let descriptor: ActionDescriptor?
    let onResult: (ConfirmationResult) -> Void

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

    private var sortedParameters: [(key: String, value: String)] {
        request.parameters.sorted { $0.key < $1.key }
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
                                    Text(tr(item.value.isEmpty ? "(vacío)" : item.value))
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
                Button("Permitir siempre") { onResult(.allowAlways) }
                    .buttonStyle(BlockButtonStyle(.secondary))
                    .help("Cambia la regla de esta acción a Permitir")
                Button("Permitir una vez") { onResult(.allowOnce) }
                    .buttonStyle(BlockButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .background(Theme.paper)
    }
}
