import AppKit
import SaySoCore
import SwiftUI

/// Pantalla Registros: lo que ha ido pasando en la app y lo que ha fallado, con filtros y exportación.
struct LogsScreen: View {
    enum LevelFilter: Hashable { case all, warnings, errors }

    let model: AppModel
    @State private var level: LevelFilter = .all
    @State private var category = ""
    @State private var query = ""

    /// Cuántas entradas se pintan; «Mostrar más» lo amplía.
    @State private var shown = 100

    /// Lo que pasa los filtros, de lo más reciente a lo más antiguo.
    private var filtered: [LogEntry] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return model.logEntries.reversed().filter { entry in
            switch level {
            case .all: break
            case .warnings: if entry.level.rank < LogLevel.warning.rank { return false }
            case .errors: if entry.level != .error { return false }
            }
            if !category.isEmpty, entry.category != category { return false }
            guard !text.isEmpty else { return true }
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return entry.message.range(of: text, options: options) != nil
                || entry.category.range(of: text, options: options) != nil
        }
    }

    private func count(_ level: LogLevel) -> Int { model.logEntries.filter { $0.level == level }.count }

    var body: some View {
        let entries = filtered
        // En el archivo van en orden cronológico, como en cualquier registro.
        let ordered = Array(entries.reversed())
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "list.bullet.rectangle", title: "Registros",
                         subtitle: "Lo que ha ido pasando en la app y lo que ha fallado. Se guarda en este Mac.",
                         tag: tr("%@ entradas", model.logEntries.count.formatted())) {
                HStack(spacing: Theme.Space.s) {
                    BlockButton("Copiar", systemImage: "doc.on.doc") { FileExport.copy(Export.log(ordered, as: .text)) }
                        .accessibilityLabel("Copiar el registro al portapapeles")
                    ExportButton(formats: [.text, .csv, .json],
                                 note: tr("Se exporta lo que ves con los filtros puestos: %@ entradas.", entries.count.formatted())) {
                        save(ordered, $0)
                    }
                }
                .disabled(entries.isEmpty)
            }

            TileGrid(tiles, columns: 3, minTileWidth: 170) { tile in
                BigStatTile(title: tile.title, value: tile.value, detail: tile.detail, swatch: tile.color,
                            valueColor: tile.valueColor)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                filterPanel
                list(entries)
                if entries.count > shown {
                    HStack(spacing: Theme.Space.m) {
                        Text(tr("Se muestran %@ de %@", shown.formatted(), entries.count.formatted()) + ". "
                            + tr("Al exportar van todas."))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                        Spacer(minLength: Theme.Space.s)
                        BlockButton("Mostrar más", compact: true) { shown += 200 }
                            .accessibilityLabel("Mostrar más entradas antiguas")
                    }
                    .padding(.horizontal, 2)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Space.m) { privacyNote; Spacer(minLength: 0); fileButtons }
                VStack(alignment: .leading, spacing: Theme.Space.s) { privacyNote; fileButtons }
            }
        }
    }

    // MARK: Resumen

    private struct Tile: Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var detail: String?
        var color: Color?
        var valueColor: Color = Theme.ink
    }

    private var tiles: [Tile] {
        let dayAgo = Date().addingTimeInterval(-86_400)
        let recent = model.logEntries.filter { $0.date >= dayAgo }
        let errors = recent.filter { $0.level == .error }.count
        let warnings = recent.filter { $0.level == .warning }.count
        let lastError = model.logEntries.last { $0.level == .error }
        return [
            Tile(title: "Errores", value: errors.formatted(),
                 detail: tr("En las últimas 24 horas · %@ en total", count(.error).formatted()),
                 color: Theme.destructive, valueColor: errors > 0 ? Theme.destructive : Theme.ink),
            Tile(title: "Avisos", value: warnings.formatted(),
                 detail: tr("En las últimas 24 horas · %@ en total", count(.warning).formatted()),
                 color: Theme.chartVoice),
            Tile(title: "Último error", value: lastError.map { RelativeDate.string($0.date) } ?? tr("Ninguno"),
                 detail: lastError.map { "\(tr($0.category)): \($0.message)" }),
        ]
    }

    // MARK: Filtros

    private var filterPanel: some View {
        Panel(padding: Theme.Space.m) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.m) { levelPicker; Spacer(minLength: 0); searchField.frame(width: 230) }
                VStack(alignment: .leading, spacing: Theme.Space.s) { levelPicker; searchField }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { areaLabel; areaChips(LogCategory.all) }
                // Con la ventana estrecha se parte en dos filas en vez de recortarse.
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    areaLabel
                    areaChips(Array(LogCategory.all.prefix(3)))
                    areaChips(Array(LogCategory.all.dropFirst(3)), includeAll: false)
                }
            }
        }
    }

    private var levelPicker: some View {
        let warnings = model.logEntries.filter { $0.level.rank >= LogLevel.warning.rank }.count
        return BlockSegmented("Qué entradas se muestran", selection: $level, options: [
            (LevelFilter.all, "\(tr("Todo")) (\(model.logEntries.count.formatted()))"),
            (.warnings, "\(tr("Avisos y errores")) (\(warnings.formatted()))"),
            (.errors, "\(tr("Solo errores")) (\(count(.error).formatted()))"),
        ], compact: true)
    }

    private var areaLabel: some View {
        Text(tr("Área").uppercased() + ":")
            .font(Theme.mono(11, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(Theme.secondary)
            .accessibilityHidden(true)
    }

    /// Áreas como fichas: la elegida lleva caja y peso, no solo otro color.
    private func areaChips(_ categories: [String], includeAll: Bool = true) -> some View {
        HStack(spacing: 2) {
            ForEach((includeAll ? [""] : []) + categories, id: \.self) { value in
                let selected = value == category
                let title = value.isEmpty ? tr("Todas") : tr(value).capitalized
                Button { category = value } label: {
                    Text(verbatim: title)
                        .font(Theme.text(12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.ink : Theme.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(minHeight: 24)
                        .background(selected ? Theme.paper : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius)
                            .strokeBorder(selected ? Theme.controlBorder : Color.clear, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(tr("Área")): \(title)"))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private var searchField: some View {
        BlockField("Buscar en los registros…", text: $query, label: "Buscar en los registros")
    }

    // MARK: Lista

    private struct DayGroup: Identifiable {
        var id: Date
        var entries: [LogEntry]
    }

    private func groups(_ entries: [LogEntry]) -> [DayGroup] {
        var out: [DayGroup] = []
        for entry in entries.prefix(shown) {
            let day = Calendar.current.startOfDay(for: entry.date)
            if out.last?.id == day { out[out.count - 1].entries.append(entry) } else { out.append(DayGroup(id: day, entries: [entry])) }
        }
        return out
    }

    private static func dayTitle(_ day: Date) -> String {
        let date = day.formatted(.dateTime.day().month(.wide))
        if Calendar.current.isDateInToday(day) { return "\(tr("Hoy")) — \(date)" }
        if Calendar.current.isDateInYesterday(day) { return "\(tr("Ayer")) — \(date)" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    @ViewBuilder
    private func list(_ entries: [LogEntry]) -> some View {
        SettingsCard {
            if model.logEntries.isEmpty {
                EmptyState(systemImage: "list.bullet.rectangle", title: "Registro vacío",
                           detail: "Aquí irá apareciendo lo que hace la app y cualquier error.")
            } else if entries.isEmpty {
                EmptyState(systemImage: "magnifyingglass", title: "Nada con esos filtros",
                           detail: "Prueba con otro nivel, otra área u otra búsqueda.")
            } else {
                // Perezosa: solo se crean las filas que caben en pantalla.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groups(entries).enumerated()), id: \.element.id) { index, group in
                        if index > 0 { CardDivider() }
                        dayHeader(group)
                        ForEach(group.entries) { entry in
                            CardDivider()
                            row(entry)
                        }
                    }
                }
            }
        }
    }

    private func dayHeader(_ group: DayGroup) -> some View {
        HStack(spacing: Theme.Space.s) {
            Rectangle().fill(Theme.ink).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(verbatim: Self.dayTitle(group.id).uppercased())
                .font(Theme.mono(11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.s)
            Text(verbatim: tr("%@ entradas", group.entries.count.formatted()))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s + 1)
        .background(Theme.paper)
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(verbatim: entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                .font(Theme.mono(11.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 62, alignment: .leading)
            LevelTag(level: entry.level)
                .frame(width: 64, alignment: .leading)
            Text(verbatim: "[\(tr(entry.category))]")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            Text(verbatim: entry.message)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s + 2)
        .accessibilityElement(children: .combine)
    }

    private func save(_ entries: [LogEntry], _ format: ExportFormat) {
        FileExport.save(Export.log(entries, as: format), name: "sayso-registros", format: format) { error in
            model.lastError = tr("No se pudo guardar el archivo: %@", error.localizedDescription)
        }
    }

    // MARK: Pie

    private var privacyNote: some View {
        InlineNote("No se guarda lo que dictas ni el contenido de tus mensajes: solo sucesos y errores.",
                   systemImage: "lock")
    }

    private var fileButtons: some View {
        HStack(spacing: Theme.Space.s) {
            BlockButton("Mostrar en Finder", systemImage: "folder", compact: true) { model.actions?.revealLog() }
            BlockButton("Vaciar", kind: .destructive, compact: true) { model.actions?.clearLog() }
                .disabled(model.logEntries.isEmpty)
                .accessibilityLabel("Vaciar el registro")
        }
        .fixedSize()
    }
}

/// Nivel de una entrada en una caja: la palabra siempre acompaña al color.
struct LevelTag: View {
    var level: LogLevel

    private var title: String {
        switch level {
        case .info: return "Info"
        case .warning: return "Aviso"
        case .error: return "Error"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if level != .info {
                Rectangle().fill(level == .error ? Theme.destructive : Theme.fixedInk).frame(width: 5, height: 5)
            }
            Text(tr(title).uppercased())
                .font(Theme.mono(10.5, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(level == .warning ? Theme.yellow : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius).strokeBorder(border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr(title))
    }

    private var foreground: Color {
        switch level {
        case .info: return Theme.secondary
        case .warning: return Theme.fixedInk
        case .error: return Theme.destructive
        }
    }

    private var border: Color {
        switch level {
        case .info: return Theme.controlBorder
        case .warning: return .clear
        case .error: return Theme.destructive
        }
    }
}

/// Guardar en un archivo que elige el usuario, o copiar al portapapeles.
@MainActor
enum FileExport {
    static func save(_ text: String, name: String, format: ExportFormat, onError: @escaping (Error) -> Void) {
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "\(name)-\(day).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(text.utf8).write(to: url, options: .atomic) } catch { onError(error) }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
