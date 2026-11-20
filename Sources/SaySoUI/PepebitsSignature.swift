import AppKit
import SaySoCore
import SwiftUI

/// Firma de pie de la marca: «© año Producto» a la izquierda y «un producto de PEPEBITS» a la
/// derecha, como en el resto de productos de Pepebits. El logotipo es el SVG oficial.
struct PepebitsSignature: View {
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private static let site = URL(string: "https://pepebits.com")!

    /// El SVG oficial viaja en la app. Su tinta fija se cambia por hueso en oscuro; el bit rojo no se toca.
    private static func wordmark(dark: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "pepebits-wordmark", withExtension: "svg"),
              var svg = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if dark { svg = svg.replacingOccurrences(of: "#1c1b1b", with: "#fcf9f8") }
        return NSImage(data: Data(svg.utf8))
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Text(verbatim: "© \(Calendar.current.component(.year, from: Date())) SaySo")
                .font(Theme.text(11))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: Theme.Space.m)
            Link(destination: Self.site) {
                HStack(alignment: .center, spacing: 6) {
                    Text(tr("un producto de"))
                        .font(Theme.text(11))
                        .foregroundStyle(hovering ? Theme.ink : Theme.secondary)
                    if let image = Self.wordmark(dark: scheme == .dark) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 68, height: 17)
                            .accessibilityHidden(true)
                    } else {
                        // Sin el recurso (ejecución fuera de la app empaquetada): el nombre en texto.
                        Text(verbatim: "PEPEBITS")
                            .font(Theme.display(12))
                            .foregroundStyle(Theme.ink)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(tr("un producto de PEPEBITS (ir a pepebits.com)"))
        }
    }
}
