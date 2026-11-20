import SaySoCore
import SwiftUI

/// Pantalla Secretos: claves solicitadas por el agente y guardadas en el Llavero.
struct SecretsScreen: View {
    let model: AppModel

    /// Hoja abierta: secreto solicitado a completar, o uno nuevo a mano.
    enum SheetTarget: Identifiable {
        case requested(SecretMeta)
        case manual
        var id: String {
            switch self {
            case let .requested(meta): return "req." + meta.name
            case .manual: return "manual"
            }
        }
    }

    @State private var sheet: SheetTarget?

    private var requested: [SecretMeta] { model.secrets.filter { $0.status == .requested } }
    private var stored: [SecretMeta] { model.secrets.filter { $0.status == .stored } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "key", title: "Secretos",
                         subtitle: "Claves que el agente usa por su nombre, sin llegar a ver el valor.",
                         tag: tr("Llavero de macOS")) {
                BlockButton("Añadir secreto", systemImage: "plus", kind: .primary) { sheet = .manual }
                    .accessibilityLabel("Añadir un secreto a mano")
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("El agente te pide",
                           note: requested.isEmpty ? tr("Nada pendiente")
                               : (requested.count == 1 ? tr("1 pendiente") : tr("%@ pendientes", "\(requested.count)")))
                if requested.isEmpty {
                    InlineNote("Cuando el agente necesite una clave, la pedirá aquí por su nombre y con el motivo.",
                               systemImage: "tray")
                        .padding(.horizontal, 2)
                } else {
                    VStack(spacing: Theme.Space.s) {
                        ForEach(requested) { requestBand($0) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Guardados",
                           note: stored.isEmpty ? nil
                               : (stored.count == 1 ? tr("1 secreto") : tr("%@ secretos", "\(stored.count)")))
                if stored.isEmpty {
                    SettingsCard {
                        EmptyState(systemImage: "key",
                                   title: "Sin secretos guardados",
                                   detail: "Añade uno a mano o responde a una solicitud del agente.")
                    }
                } else {
                    TileGrid(stored, columns: 3, minTileWidth: 200) { storedCard($0) }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Cómo se protegen")
                Panel {
                    protectionSteps
                }
            }
        }
        .sheet(item: $sheet) { target in
            switch target {
            case let .requested(meta):
                SecretSheet(fixedName: meta.name, initialReason: meta.reason) { name, value, reason in
                    model.actions?.storeSecret(name: name, value: value, reason: reason)
                }
            case .manual:
                SecretSheet(fixedName: nil, initialReason: "") { name, value, reason in
                    model.actions?.storeSecret(name: name, value: value, reason: reason)
                }
            }
        }
    }

    @ViewBuilder
    private var protectionSteps: some View {
        protectionStep(1, "El agente pide un secreto por su nombre, nunca el valor.")
        protectionStep(2, "Tú lo escribes aquí, no en el chat.")
        protectionStep(3, "Si un valor aparece en un texto, se sustituye por [NOMBRE] antes de enviarlo al modelo.")
    }

    private func protectionStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            StepBadge(number: number)
            Text(tr(text))
                .font(Theme.caption)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Paso %@: %@", "\(number)", tr(text)))
    }

    /// Petición pendiente: banda con una barra amarilla a la izquierda y la etiqueta «Pendiente».
    private func requestBand(_ meta: SecretMeta) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            StatusTag("Pendiente", kind: .pending)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: meta.name)
                    .font(Theme.mono(13, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !meta.reason.isEmpty {
                    Text(verbatim: meta.reason)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BlockButton("Añadir valor", systemImage: "arrow.right.to.line", kind: .primary) { sheet = .requested(meta) }
                .accessibilityLabel(tr("Añadir valor de %@", meta.name))
        }
        .padding(.leading, Theme.Space.m + 4)
        .padding(.trailing, Theme.Space.m)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.yellow).frame(width: 4).accessibilityHidden(true) }
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
    }

    private func storedCard(_ meta: SecretMeta) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
                HStack(alignment: .top) {
                    IconTile("key", size: 26)
                    Spacer(minLength: 4)
                    MonoTag(text: meta.lastUsed.map { RelativeDate.string($0) } ?? tr("Nunca usado"))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: meta.name)
                        .font(Theme.mono(12.5, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !meta.reason.isEmpty {
                        Text(verbatim: meta.reason)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: Theme.Space.s) {
                    Text(verbatim: "■ ■ ■ ■ ■ ■ ■ ■")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "lock").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: 28)
                .background(Theme.paper)
                .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius).strokeBorder(Theme.border, lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Valor oculto")
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            CardDivider()
            HStack(spacing: Theme.Space.s) {
                BlockButton("Cambiar", compact: true) { sheet = .requested(meta) }
                    .accessibilityLabel(tr("Cambiar el valor de %@", meta.name))
                Spacer(minLength: 0)
                BlockButton("Olvidar", kind: .destructive, compact: true) {
                    model.actions?.forgetSecret(name: meta.name)
                }
                .accessibilityLabel(tr("Olvidar %@", meta.name))
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
    }
}

/// Hoja para guardar el valor de un secreto.
struct SecretSheet: View {
    let fixedName: String?
    let onSave: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var reason: String
    @State private var value = ""

    init(fixedName: String?, initialReason: String, onSave: @escaping (String, String, String) -> Void) {
        self.fixedName = fixedName
        self.onSave = onSave
        _reason = State(initialValue: initialReason)
    }

    /// Nombre en mayúsculas, dígitos y guion bajo.
    private var normalizedName: String {
        // El nombre solicitado por el agente se respeta tal cual.
        if let fixedName { return fixedName }
        return name
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    private var nameIsValid: Bool {
        if fixedName != nil { return true }
        return normalizedName.range(of: #"^[A-Z][A-Z0-9_]*$"#, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(verbatim: fixedName == nil ? tr("Añadir secreto") : tr("Guardar %@", fixedName!))
                .font(Theme.display(20))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)

            if fixedName == nil {
                LabeledField("Nombre", placeholder: "GITHUB_TOKEN", text: $name, mono: true,
                             hint: name.isEmpty || nameIsValid ? "El agente lo pedirá por este nombre." :
                                 "Usa letras, números y guiones bajos, empezando por una letra.")
                LabeledField("Motivo", placeholder: "Para qué se usa", text: $reason)
            } else if !reason.isEmpty {
                InlineNote(reason, systemImage: "text.bubble")
            }
            LabeledField("Valor", placeholder: "Pega el valor", text: $value, secure: true, mono: true,
                         hint: "Se guarda en el Llavero de este Mac. El modelo nunca lo ve.")

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(BlockButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    onSave(normalizedName, value, reason.trimmingCharacters(in: .whitespaces))
                    value = ""
                    dismiss()
                }
                .buttonStyle(BlockButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid || value.isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 440)
        .background(Theme.paper)
    }
}
