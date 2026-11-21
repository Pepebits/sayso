import SaySoCore
import SwiftUI

// Piezas del lenguaje «Modular Studio»: tarjetas sueltas con relleno propio, rótulos con un dato
// a la derecha y rejillas de módulos de la misma altura.

// MARK: - Panel

/// Tarjeta modular: superficie con borde y relleno propio. `fill` la estira para igualar la
/// altura de sus vecinas en una fila.
struct Panel<Content: View>: View {
    var padding: CGFloat
    var fill: Bool
    var content: Content

    init(padding: CGFloat = Theme.Space.l, fill: Bool = false, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

// MARK: - Rótulos

/// Rótulo de sección con un dato en monoespaciada a la derecha (recuentos, ámbito).
struct SectionBar: View {
    var title: String
    /// Ya traducido: suele llevar cifras.
    var note: String?

    init(_ title: String, note: String? = nil) {
        self.title = title
        self.note = note
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            SectionLabel(title)
            Spacer(minLength: Theme.Space.s)
            if let note {
                Text(verbatim: note)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Rótulo pequeño dentro de un panel («ATAJO», «TU BOT»).
struct PanelLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(tr(text).uppercased())
            .font(Theme.mono(11, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(Theme.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Opción

/// Una opción de un grupo excluyente, como tarjeta: marca cuadrada, título y descripción.
/// La elegida se distingue por el borde de tinta y la marca rellena, no solo por el color.
struct OptionCard: View {
    var title: String
    var detail: String
    var selected: Bool
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.s + 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.innerRadius)
                        .strokeBorder(selected ? Theme.ink : Theme.controlBorder, lineWidth: 1.5)
                    if selected { Rectangle().fill(Theme.ink).frame(width: 8, height: 8) }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    Text(tr(detail))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.m)
            .background(Theme.paper)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(selected ? Theme.ink : Theme.border, lineWidth: selected ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(tr(title)). \(tr(detail))"))
        .accessibilityValue(selected ? tr("Elegida") : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Medidor

/// Módulo con un dato y su barra (CPU, memoria, disco) o solo el dato.
struct StatTile: View {
    var title: String
    /// Ya traducido.
    var value: String
    var detail: String?
    var progress: Double?
    /// Cuadro de color que enlaza la cifra con su serie en un gráfico.
    var swatch: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let swatch {
                    Rectangle().fill(swatch).frame(width: 8, height: 8).accessibilityHidden(true)
                }
                PanelLabel(title)
                Spacer(minLength: 4)
                Text(verbatim: value)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let progress { BlockProgress(value: progress, label: title) }
            if let detail {
                Text(verbatim: detail)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr(title))
        .accessibilityValue(Text(verbatim: [value, detail].compactMap { $0 }.joined(separator: ", ")))
    }
}

// MARK: - Rejilla

/// Rejilla de módulos en filas de la misma altura. A diferencia de `LazyVGrid`, cada fila iguala
/// el alto de sus tarjetas, y el orden de lectura y de tabulación es por filas.
struct TileGrid<Item: Identifiable, Cell: View>: View {
    var items: [Item]
    /// Columnas como máximo.
    var columns: Int
    /// Ancho por debajo del cual una tarjeta no cabe: si la ventana se estrecha, se usan menos
    /// columnas en vez de recortar el contenido.
    var minTileWidth: CGFloat?
    var spacing: CGFloat
    var cell: (Item) -> Cell
    @State private var width: CGFloat = Theme.contentMaxWidth

    init(_ items: [Item], columns: Int, minTileWidth: CGFloat? = nil, spacing: CGFloat = Theme.Space.m,
         @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.items = items
        self.columns = max(columns, 1)
        self.minTileWidth = minTileWidth
        self.spacing = spacing
        self.cell = cell
    }

    private var fitting: Int {
        TileGridLayout.columns(wanted: columns, width: width, minTileWidth: minTileWidth, spacing: spacing)
    }

    private func rows(_ count: Int) -> [[Item]] {
        stride(from: 0, to: items.count, by: count).map { Array(items[$0..<min($0 + count, items.count)]) }
    }

    var body: some View {
        let count = fitting
        VStack(spacing: spacing) {
            ForEach(Array(rows(count).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row) { item in
                        // `minWidth: 0`: una tarjeta más ancha que su hueco no ensancha la rejilla. Si no,
                        // el ancho medido incluía el desborde, nunca bajaban las columnas y la vista
                        // empujaba la barra lateral fuera de la ventana.
                        cell(item).frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    // Huecos para que la última fila no estire sus tarjetas.
                    ForEach(0..<(count - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1).accessibilityHidden(true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

enum TileGridLayout {
    /// Cuántas columnas caben sin bajar de `minTileWidth`; siempre al menos una.
    static func columns(wanted: Int, width: CGFloat, minTileWidth: CGFloat?, spacing: CGFloat) -> Int {
        guard let minTileWidth, minTileWidth > 0 else { return max(wanted, 1) }
        return min(max(wanted, 1), max(1, Int((width + spacing) / (minTileWidth + spacing))))
    }
}

// MARK: - Varios

/// Número de paso en un cuadro de tinta.
struct StepBadge: View {
    var number: Int

    var body: some View {
        Text(verbatim: "\(number)")
            .font(Theme.mono(11, weight: .bold))
            .foregroundStyle(Theme.paper)
            .frame(width: 18, height: 18)
            .background(Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius))
            .accessibilityHidden(true)
    }
}

/// Interruptor con su rótulo a la vista, en una caja: para el ajuste principal de una pantalla.
struct LabeledToggleBox: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s + 2) {
            Text(tr(title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink).lineLimit(1)
            BlockToggle(isOn: $isOn, label: title)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .fixedSize()
    }
}

/// Estado con cuadro y texto, sin caja: «■ Concedido». El texto siempre acompaña al color.
struct StateLine: View {
    var text: String
    var on: Bool

    var body: some View {
        HStack(spacing: 6) {
            Bit(size: 8, active: on, tone: .running)
            Text(tr(text)).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cifra grande

/// Módulo con una cifra grande, su rótulo y una línea de contexto. El cuadro de color de la esquina
/// acompaña al rótulo; nunca es lo único que dice qué es.
struct BigStatTile: View {
    var title: String
    /// Ya traducido.
    var value: String
    /// Ya traducido.
    var detail: String?
    var swatch: Color?
    /// Tinta por defecto; rojo de error cuando la cifra es un recuento de fallos.
    var valueColor: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center) {
                PanelLabel(title)
                Spacer(minLength: 4)
                if let swatch { Rectangle().fill(swatch).frame(width: 8, height: 8).accessibilityHidden(true) }
            }
            Text(verbatim: value)
                .font(Theme.display(28))
                .tracking(-0.6)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(verbatim: detail)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr(title))
        .accessibilityValue(Text(verbatim: [value, detail].compactMap { $0 }.joined(separator: ", ")))
    }
}

// MARK: - Exportar

/// Botón «Exportar» que despliega los formatos disponibles.
struct ExportButton: View {
    var formats: [ExportFormat]
    /// Qué se va a exportar, ya traducido.
    var note: String
    var action: (ExportFormat) -> Void
    @State private var open = false

    private static func title(_ format: ExportFormat) -> String {
        switch format {
        case .text: return "Texto (.log)"
        case .csv: return "CSV"
        case .json: return "JSON"
        }
    }

    private static func icon(_ format: ExportFormat) -> String {
        switch format {
        case .text: return "doc.plaintext"
        case .csv: return "tablecells"
        case .json: return "curlybraces"
        }
    }

    var body: some View {
        BlockButton("Exportar", systemImage: "square.and.arrow.up", kind: .primary) { open = true }
            .accessibilityHint(tr("Abre la lista de formatos"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(verbatim: note)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(formats, id: \.self) { format in
                        Button {
                            open = false
                            action(format)
                        } label: {
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: Self.icon(format))
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                Text(tr(Self.title(format))).font(Theme.bodyStrong)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, Theme.Space.s + 2)
                            .frame(minHeight: 30)
                            .background(Theme.surface)
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("Exportar como %@", tr(Self.title(format))))
                    }
                }
                .padding(Theme.Space.m)
                .frame(width: 230)
                .background(Theme.paper)
            }
    }
}
