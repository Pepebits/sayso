import SaySoCore
import SwiftUI

/// Pantalla Estadísticas: cuánto se usa el dictado, la IA y las acciones del agente.
/// Solo enseña lo que la app cuenta de verdad en la base de datos de este Mac.
struct StatsScreen: View {
    enum Metric: Hashable { case requests, dictations, words }

    let model: AppModel
    @State private var range = 30
    @State private var metric: Metric = .requests

    private var stats: UsageStats { model.stats }
    private var days: [DayUsage] { stats.lastDays(range) }
    private var totals: UsageTotals { stats.totals(lastDays: range) }
    private var buckets: [ActionBucket] { stats.actions(lastDays: range) }

    private var hasData: Bool {
        stats.allTime != UsageTotals() || !stats.actions.isEmpty
    }

    private var sinceTag: String? {
        stats.firstDay.map { tr("Desde el %@", $0.formatted(.dateTime.day().month(.abbreviated).year())) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "chart.bar", title: "Estadísticas",
                         subtitle: "Cuánto usas SaySo. Se cuenta en este Mac y no se envía a ningún sitio.",
                         tag: sinceTag) {
                ExportButton(formats: [.csv, .json],
                             note: tr("El uso por día de los últimos %@ días. El JSON lleva también las acciones.", "\(range)")) {
                    save($0)
                }
                .disabled(!hasData)
            }

            if hasData {
                BlockSegmented("Periodo de las estadísticas", selection: $range,
                               options: [(7, "7 días"), (30, "30 días"), (90, "90 días")], compact: true)

                TileGrid(tiles, columns: 4, minTileWidth: 140) { tile in
                    StatTile(title: tile.title, value: tile.value, detail: tile.detail, swatch: tile.color)
                }

                chartPanel

                actionsSection

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if stats.allTime.dictations == 0 {
                        InlineNote("Los dictados se cuentan desde esta versión; los anteriores no quedaron registrados.",
                                   systemImage: "clock")
                    }
                    InlineNote("Las acciones salen del registro de actividad de cada pantalla. Si lo vacías, dejan de contar aquí.")
                }
                .padding(.horizontal, 2)
            } else {
                EmptyState(systemImage: "chart.bar", title: "Aún no hay datos",
                           detail: "Dicta algo o habla con el agente y aquí verás cuánto lo usas.")
            }

            resourcesSection
        }
        .onAppear { model.actions?.refreshResources() }
    }

    // MARK: Recursos

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// La memoria en sus unidades (4 GB y no 4,29 GB).
    private static func memory(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private var resourcesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionBar("Recursos", note: model.resources.map { tr("%@ en disco", Self.bytes($0.totalDisk)) })
            if let usage = model.resources {
                TileGrid(memoryTiles(usage), columns: 3, minTileWidth: 160) { tile in
                    StatTile(title: tile.title, value: tile.value, detail: tile.detail, swatch: tile.color)
                }
                Panel {
                    HStack {
                        PanelLabel("Espacio en disco")
                        Spacer(minLength: Theme.Space.s)
                        Text(tr("Medido %@", RelativeDate.string(usage.measuredAt)))
                            .font(Theme.caption).foregroundStyle(Theme.secondary)
                    }
                    diskRows(usage)
                    HStack(spacing: Theme.Space.s) {
                        BlockButton("Volver a medir", systemImage: "arrow.clockwise", compact: true) {
                            model.actions?.refreshResources()
                        }
                        if usage.disk.contains(where: { $0.id == "telegram" }) {
                            BlockButton("Limpiar archivos de Telegram", systemImage: "trash", compact: true) {
                                model.actions?.cleanTelegramFiles()
                            }
                            .help(tr("Borra lo descargado que no se haya usado en 14 días. Telegram lo vuelve a bajar si hace falta."))
                        }
                        Spacer(minLength: 0)
                        BlockButton("Mostrar en Finder", systemImage: "folder", compact: true) {
                            model.actions?.revealDataFolder()
                        }
                    }
                }
            } else {
                Panel {
                    Text(tr("Midiendo…")).font(Theme.body).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private func memoryTiles(_ usage: ResourceUsage) -> [Tile] {
        var tiles = [Tile(title: tr("Memoria de SaySo"), value: Self.memory(usage.appMemory),
                          detail: tr("la app, ahora mismo"), color: Theme.chartAI)]
        if let vm = usage.vmMemory {
            tiles.append(Tile(title: tr("Memoria de la máquina Linux"), value: Self.memory(vm),
                              detail: usage.vmRunning ? tr("asignada; en marcha") : tr("asignada; apagada, no usa nada"),
                              color: Theme.chartVoice))
        }
        tiles.append(Tile(title: tr("Disco"), value: Self.bytes(usage.totalDisk), detail: tr("todo lo de SaySo"),
                          color: Theme.secondary))
        return tiles
    }

    private func diskRows(_ usage: ResourceUsage) -> some View {
        let top = max(usage.disk.map(\.bytes).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
            ForEach(usage.disk) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(tr(item.title))
                            .font(Theme.text(12.5, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        if let detail = item.detail {
                            Text(verbatim: detail)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Text(verbatim: Self.bytes(item.bytes))
                            .font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    BlockProgress(value: Double(item.bytes) / Double(top), label: tr(item.title), tint: Theme.chartAI)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(tr(item.title)))
                .accessibilityValue(Text(verbatim: Self.bytes(item.bytes)))
            }
        }
    }

    // MARK: Exportar

    private func save(_ format: ExportFormat) {
        FileExport.save(Export.stats(days: days, actions: buckets, as: format),
                        name: "sayso-estadisticas-\(range)d", format: format) { error in
            model.lastError = tr("No se pudo guardar el archivo: %@", error.localizedDescription)
        }
    }

    // MARK: Cifras

    private struct Tile: Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var detail: String
        var color: Color
    }

    private var tiles: [Tile] {
        let all = stats.allTime
        return [
            Tile(title: "Solicitudes a la IA", value: totals.requests.formatted(),
                 detail: tr("%@ en total", all.requests.formatted()), color: Theme.chartAI),
            Tile(title: "Dictados", value: totals.dictations.formatted(),
                 detail: tr("%@ en total", all.dictations.formatted()), color: Theme.chartVoice),
            Tile(title: "Palabras dictadas", value: totals.words.formatted(),
                 detail: tr("%@ en total", all.words.formatted()), color: Theme.chartVoice),
            Tile(title: "Tiempo hablando", value: Self.duration(totals.seconds),
                 detail: tr("%@ en total", Self.duration(all.seconds)), color: Theme.chartVoice),
        ]
    }

    /// «45 s», «12 min», «1 h 5 min».
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return tr("%@ s", "\(total)") }
        let minutes = total / 60
        if minutes < 60 { return tr("%@ min", "\(minutes)") }
        return tr("%@ h %@ min", "\(minutes / 60)", "\(minutes % 60)")
    }

    // MARK: Gráfico por día

    private func value(_ day: DayUsage) -> Int {
        switch metric {
        case .requests: return day.totals.requests
        case .dictations: return day.totals.dictations
        case .words: return day.totals.words
        }
    }

    private var metricTitle: String {
        switch metric {
        case .requests: return "Solicitudes por día"
        case .dictations: return "Dictados por día"
        case .words: return "Palabras por día"
        }
    }

    /// Lo mismo que dibujan las barras, en una frase: sirve de pie y de lectura para VoiceOver.
    private var chartSummary: String {
        let values = days.map(value)
        let total = values.reduce(0, +)
        guard total > 0, let peak = days.max(by: { value($0) < value($1) }) else {
            return tr("Sin datos en este periodo.")
        }
        let active = values.filter { $0 > 0 }.count
        let average = Double(total) / Double(max(days.count, 1))
        return tr("Media de %@ al día. El día con más fue el %@, con %@. Hubo uso %@ de %@ días.",
                  average.formatted(.number.precision(.fractionLength(0...1))),
                  peak.day.formatted(.dateTime.day().month(.wide)), value(peak).formatted(),
                  "\(active)", "\(days.count)")
    }

    private var chartPanel: some View {
        Panel {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                PanelLabel(metricTitle)
                Spacer(minLength: Theme.Space.s)
                BlockSegmented("Qué se dibuja en el gráfico", selection: $metric,
                               options: [(Metric.requests, "Solicitudes"), (.dictations, "Dictados"), (.words, "Palabras")],
                               compact: true)
            }
            DayBars(days: days, color: metric == .requests ? Theme.chartAI : Theme.chartVoice, value: value,
                    title: tr(metricTitle), summary: chartSummary)
            Text(verbatim: chartSummary)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }

    // MARK: Acciones del agente

    private static let scopeOrder = ["telegram", "mac", "vm", "plugin", "secret"]

    private static func scopeTitle(_ scope: String) -> String {
        switch scope {
        case "telegram": return tr("Telegram")
        case "mac": return tr("Mac")
        case "vm": return tr("Ordenador")
        case "plugin": return tr("Plugins")
        case "secret": return tr("Secretos")
        default: return scope
        }
    }

    private struct Count: Identifiable {
        var id: String
        var title: String
        var count: Int
    }

    private var byScope: [Count] {
        var sums: [String: Int] = [:]
        for bucket in buckets { sums[bucket.action.scope, default: 0] += bucket.count }
        let known = Self.scopeOrder.filter { sums[$0] != nil }
        let other = sums.keys.filter { !Self.scopeOrder.contains($0) }.sorted()
        return (known + other).map { Count(id: $0, title: Self.scopeTitle($0), count: sums[$0] ?? 0) }
    }

    private var topActions: [Count] {
        var sums: [ActionID: Int] = [:]
        for bucket in buckets { sums[bucket.action, default: 0] += bucket.count }
        return sums.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
            .prefix(5)
            .map { Count(id: $0.key.rawValue, title: actionTitle($0.key), count: $0.value) }
    }

    private func actionTitle(_ action: ActionID) -> String {
        let known = TelegramAction.descriptors + ComputerAction.descriptors + MacScript.allCases.map(\.descriptor)
        if let descriptor = known.first(where: { $0.id == action }) { return tr(descriptor.title) }
        if let plugin = model.plugins.first(where: { $0.config.action == action }) { return plugin.config.name }
        return action.rawValue
    }

    private func outcomeCount(_ outcome: ActivityOutcome) -> Int {
        buckets.filter { $0.outcome == outcome }.reduce(0) { $0 + $1.count }
    }

    private var actionsSection: some View {
        let total = buckets.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionBar("Acciones del agente", note: tr("%@ en el registro", total.formatted()))
            if total == 0 {
                Panel {
                    Text(tr("El agente no ha hecho ninguna acción en este periodo."))
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondary)
                }
            } else {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Panel(fill: true) {
                        PanelLabel("Por ámbito")
                        countRows(byScope, total: total)
                    }
                    Panel(fill: true) {
                        PanelLabel("Las más usadas")
                        countRows(topActions, total: total)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Panel {
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        outcomeCell("Permitidas", "checkmark", .allowed, Theme.running)
                        outcomeCell("Denegadas", "hand.raised", .denied, Theme.secondary)
                        outcomeCell("Fallidas", "exclamationmark.triangle", .failed, Theme.destructive)
                    }
                }
            }
        }
    }

    /// Filas con nombre, barra proporcional al mayor y cifra.
    private func share(_ count: Int, of total: Int) -> String {
        (Double(count) / Double(max(total, 1))).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
    }

    /// `total` es el de todas las acciones del periodo, no solo el de las filas que se enseñan.
    private func countRows(_ rows: [Count], total: Int) -> some View {
        let top = max(rows.map(\.count).max() ?? 1, 1)
        let sum = total
        return VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(verbatim: row.title)
                            .font(Theme.text(12.5, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Theme.Space.s)
                        Text(verbatim: row.count.formatted())
                            .font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    BlockProgress(value: Double(row.count) / Double(top), label: row.title, tint: Theme.chartAI)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .help(Text(verbatim: "\(row.title): \(row.count.formatted()) · " + tr("%@ del total", share(row.count, of: sum))))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: row.title))
                .accessibilityValue(Text(verbatim: "\(row.count.formatted()), " + tr("%@ del total", share(row.count, of: sum))))
            }
        }
    }

    /// El resultado se distingue por el glifo y el rótulo, no por el color.
    private func outcomeCell(_ title: String, _ systemImage: String, _ outcome: ActivityOutcome,
                             _ tint: Color) -> some View {
        let count = outcomeCount(outcome)
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: count.formatted())
                    .font(Theme.mono(15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text(tr(title))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr(title))
        .accessibilityValue(Text(verbatim: count.formatted()))
    }
}

// MARK: - Barras por día

/// Una barra por día, del más antiguo a hoy, en el color de su serie. Al pasar el ratón por un día,
/// o al recorrerlos con las flechas, se resalta su barra y aparece una ficha con sus cifras.
private struct DayBars: View {
    var days: [DayUsage]
    var color: Color
    var value: (DayUsage) -> Int
    /// Qué se dibuja, ya traducido.
    var title: String
    /// El gráfico en una frase, para VoiceOver cuando no hay un día elegido.
    var summary: String
    /// Ayuda de desarrollo: SAYSO_CHART_DAY=<índice> abre con ese día elegido, para las capturas.
    @State private var selected: Int? = ProcessInfo.processInfo.environment["SAYSO_CHART_DAY"].flatMap(Int.init)
    @FocusState private var focused: Bool

    private static let height: CGFloat = 120
    private var spacing: CGFloat { days.count > 40 ? 2 : (days.count > 10 ? 3 : 8) }

    private static func date(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(L10n.locale))
    }

    private func spoken(_ day: DayUsage) -> String {
        "\(Self.date(day.day)): \(tr("Solicitudes")) \(day.totals.requests.formatted()), "
            + "\(tr("Dictados")) \(day.totals.dictations.formatted()), \(tr("Palabras")) \(day.totals.words.formatted())"
    }

    private func move(_ delta: Int) {
        guard !days.isEmpty else { return }
        selected = min(max((selected ?? days.count - 1) + delta, 0), days.count - 1)
    }

    var body: some View {
        let top = max(days.map(value).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: tr("Máximo %@", top.formatted()))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.secondary)
            GeometryReader { geo in
                let step = (geo.size.width + spacing) / CGFloat(max(days.count, 1))
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                            let amount = value(day)
                            Rectangle()
                                // El día elegido pasa a tinta: se distingue por tono y por la ficha.
                                .fill(index == selected ? Theme.ink : (amount > 0 ? color : Theme.controlBorder))
                                .frame(maxWidth: .infinity)
                                .frame(height: amount > 0 ? max(3, Self.height * CGFloat(amount) / CGFloat(top)) : (index == selected ? 3 : 1))
                        }
                    }
                    .frame(height: Self.height, alignment: .bottom)
                    if let selected, days.indices.contains(selected) {
                        DayCallout(date: Self.date(days[selected].day), totals: days[selected].totals)
                            .fixedSize()
                            .alignmentGuide(.leading) { size in
                                // Al lado de su barra, para no taparla: a la derecha si cabe y, si no, a la izquierda.
                                let right = step * CGFloat(selected + 1) + 4
                                let left = step * CGFloat(selected) - spacing - 4 - size.width
                                let x = right + size.width <= geo.size.width ? right : max(left, 0)
                                return -x
                            }
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point): selected = min(max(Int(point.x / step), 0), days.count - 1)
                    case .ended: if !focused { selected = nil }
                    }
                }
            }
            .frame(height: Self.height)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack {
                if let first = days.first {
                    Text(verbatim: first.day.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale)))
                }
                Spacer()
                Text(tr("Hoy"))
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.secondary)
        }
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left: move(-1)
            case .right: move(1)
            default: break
            }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { if selected == nil { move(0) } } else { selected = nil }
        }
        .onChange(of: days.count) { _, _ in selected = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: selected.flatMap { days.indices.contains($0) ? spoken(days[$0]) : nil } ?? summary))
        .accessibilityHint(tr("Recorre los días con las flechas izquierda y derecha."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
    }
}

/// Ficha de un día: la fecha y sus tres cifras, cada una con el cuadro de color de su serie.
private struct DayCallout: View {
    var date: String
    var totals: UsageTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: date.uppercased())
                .font(Theme.mono(11, weight: .bold))
                .foregroundStyle(Theme.ink)
            line("Solicitudes", totals.requests, Theme.chartAI)
            line("Dictados", totals.dictations, Theme.chartVoice)
            line("Palabras", totals.words, Theme.chartVoice)
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.ink, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func line(_ title: String, _ amount: Int, _ swatch: Color) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(swatch).frame(width: 7, height: 7)
            Text(tr(title)).font(Theme.text(12)).foregroundStyle(Theme.secondary)
            Spacer(minLength: Theme.Space.m)
            Text(verbatim: amount.formatted()).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.ink)
        }
    }
}
