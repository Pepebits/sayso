import AppKit
import SaySoCore
import SwiftUI

/// Avisos de licencia del software de terceros que va dentro de la app. El texto lo genera
/// `scripts/generate-third-party-notices.py` y viaja en el paquete como `ThirdPartyNotices.txt`.
struct ThirdPartyNotices {
    struct Component: Identifiable, Hashable {
        var name: String
        var url: String
        var license: String
        var id: String { name }
    }

    var text: String
    var components: [Component]

    static let rule = String(repeating: "=", count: 78)

    /// Cada componente va entre dos líneas de «=»: nombre, dirección y tipo de licencia.
    init(text: String) {
        self.text = text
        var found: [Component] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index + 4 < lines.count {
            if lines[index] == Self.rule, lines[index + 4] == Self.rule {
                found.append(Component(name: lines[index + 1], url: lines[index + 2], license: lines[index + 3]))
                index += 5
            } else {
                index += 1
            }
        }
        components = found
    }

    /// El archivo del paquete de la app; `nil` si esta compilación no lo lleva (pruebas, `swift run`).
    static func bundled() -> ThirdPartyNotices? {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ThirdPartyNotices(text: text)
    }
}

/// Hoja «Licencias»: la lista de componentes y, debajo, el texto completo de sus licencias.
struct LicensesSheet: View {
    var notices: ThirdPartyNotices?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Licencias"))
                        .font(Theme.display(20))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(tr("SaySo incluye software de terceros. Cada componente se distribuye con su propia licencia."))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.m)
                BlockButton("Cerrar", kind: .primary) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let notices {
                SettingsCard {
                    ForEach(Array(notices.components.enumerated()), id: \.element.id) { index, component in
                        if index > 0 { CardDivider() }
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: component.name).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                                Text(verbatim: component.url)
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            MonoTag(text: component.license)
                        }
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s + 2)
                        .accessibilityElement(children: .combine)
                    }
                }

                HStack {
                    SectionLabel("Texto completo")
                    Spacer()
                    BlockButton("Copiar", systemImage: "doc.on.doc", compact: true) { FileExport.copy(notices.text) }
                        .accessibilityLabel("Copiar el texto de las licencias")
                }
                ScrollView {
                    Text(verbatim: notices.text)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.m)
                }
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .accessibilityLabel("Texto completo de las licencias")
            } else {
                EmptyState(systemImage: "doc.text", title: "Sin avisos de licencia",
                           detail: "Esta compilación no lleva el archivo de licencias. Aparece en la app empaquetada.")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 640, height: 620)
        .background(Theme.paper)
        .appLanguage()
    }
}
