import SaySoCore
import SwiftUI

/// Tecla dibujada como bloque (⌥).
struct KeyCap: View {
    var symbol: String
    var size: CGFloat = 26
    var foreground: Color = Theme.ink
    var border: Color = Theme.ink

    var body: some View {
        // Un símbolo va en un cuadrado; un nombre («Espacio», «F5», «fn») ensancha la tecla.
        let wide = symbol.count > 1
        Text(symbol)
            .font(.system(size: size * (wide ? 0.4 : 0.55), weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, wide ? size * 0.25 : 0)
            .frame(minWidth: size, minHeight: size, maxHeight: size)
            .overlay(
                RoundedRectangle(cornerRadius: 3).strokeBorder(border, lineWidth: 1.5)
            )
            .accessibilityLabel(symbol == "⌥" ? tr("Tecla Opción") : symbol)
    }
}

/// Pantalla Dictado.
struct DictationScreen: View {
    let model: AppModel
    @State private var showingPermissionGuide = false

    private var settings: DictationSettings { model.dictation }

    private func update(_ change: (inout DictationSettings) -> Void) {
        var s = model.dictation
        change(&s)
        model.actions?.updateDictation(s)
    }

    /// Permisos que hacen falta con el motor elegido.
    private var relevantPermissions: [SystemPermissionKind] {
        SystemPermissionKind.needed(engine: settings.engine)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { settings.enabled }, set: { v in update { $0.enabled = v } })
    }

    /// Motor en uso y, si lo hay, su estado («Whisper · Listo»).
    private var engineTag: String {
        [tr(settings.engine.title), model.transcriberStatus.map { tr($0) }].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "mic", title: "Dictado",
                         subtitle: tr("Mantén %@ y háblale al agente desde cualquier app.", settings.shortcut.symbol),
                         tag: settings.enabled ? engineTag : tr("Desactivado")) {
                LabeledToggleBox(title: "Dictado por voz", isOn: enabledBinding)
            }

            HStack(alignment: .top, spacing: Theme.Space.m) {
                shortcutPanel
                voicePanel
            }
            .fixedSize(horizontal: false, vertical: true)
            .disabled(!settings.enabled)

            manualPanel

            transcriptionPanel
                .disabled(!settings.enabled)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .center) {
                    SectionBar("Permisos de macOS", note: permissionsNote)
                    if !model.missingDictationPermissions.isEmpty {
                        BlockButton("Guía paso a paso", kind: .primary, compact: true) { showingPermissionGuide = true }
                    }
                }
                TileGrid(relevantPermissions.map(PermissionItem.init), columns: relevantPermissions.count > 3 ? 2 : 3, minTileWidth: 180) { item in
                    permissionTile(item.kind)
                }
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    Text(tr("macOS aplica Supervisión de entrada al arrancar la app. Si ya la has activado en Ajustes del Sistema y sigue como pendiente, reinicia SaySo."))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BlockButton("Reiniciar SaySo", systemImage: "arrow.clockwise", compact: true) {
                        model.actions?.relaunch()
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .sheet(isPresented: $showingPermissionGuide) { PermissionGuideSheet(model: model) }
    }

    // MARK: Atajo

    private var shortcutPanel: some View {
        Panel(fill: true) {
            HStack {
                PanelLabel("Atajo")
                Spacer()
                Text(tr("En todo el Mac")).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
            }
            ShortcutRecorder(model: model, shortcut: settings.shortcut) { new in
                update {
                    $0.shortcut = new

                }
            }
            Spacer(minLength: Theme.Space.s)
            if settings.shortcut.kind == .option {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Lado de la tecla").font(Theme.text(12, weight: .semibold)).foregroundStyle(Theme.ink)
                    BlockSegmented("Lado de la tecla Opción",
                                   selection: Binding(get: { settings.side }, set: { v in update { $0.side = v } }),
                                   options: [OptionKeySide.left, .any, .right].map { ($0, $0.title) })
                    Text(tr(sideDetail))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(tr(customDetail))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var customDetail: String {
        switch settings.shortcut.kind {
        case .combo:
            return "Si la app en la que estés también usa esta combinación, le llegará igual: mejor una que no use nadie, como una tecla F."
        default:
            return "Mantenla sola: si la pulsas junto con otra tecla, se usa para lo de siempre."
        }
    }

    private var sideDetail: String {
        "Usa un solo lado si escribes caracteres con ⌥ (como ⌥+ñ) con el otro."
    }

    // MARK: Qué hace lo que dices

    private var voicePanel: some View {
        Panel(fill: true) {
            PanelLabel("Qué hace lo que dices")
            HStack(alignment: .top, spacing: Theme.Space.m) {
                IconTile("bubble.left.and.bubble.right", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Se lo dices al agente").font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    Text(model.activeAccount == nil
                         ? tr("Necesita una cuenta de IA: añádela en Modelo para poder hablarle.")
                         : tr("Actúa según tus reglas y te responde. Para tener el texto, usa «Dictar texto» abajo."))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.s)
            CardDivider()
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Responder en voz alta").font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    Text("Con la voz de macOS. Siempre se muestra también en pantalla.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                BlockToggle(isOn: Binding(get: { settings.speakReplies }, set: { v in update { $0.speakReplies = v } }),
                            label: "Responder en voz alta")
            }
        }
    }

    // MARK: Dictado manual

    private var manualBusy: Bool {
        switch model.dictationPhase {
        case .transcribing, .correcting, .agentThinking: return !model.manualDictation
        default: return false
        }
    }

    private var manualStatus: String {
        if model.conversing {
            switch model.dictationPhase {
            case .agentListening, .listening: return "Te escucho. Cuando te calles, lo envío."
            case .transcribing, .correcting, .agentThinking: return "Pensando…"
            case .agentReply: return "Respondiendo… después vuelvo a escucharte."
            default: return "Conversación en marcha."
            }
        }
        if model.manualDictation { return "Escuchando… pulsa Detener cuando acabes." }
        if manualBusy { return "Transcribiendo…" }
        if !model.manualTranscript.isEmpty { return "Copiado al portapapeles." }
        return "Sin tecla. «Dictar texto» copia lo que digas al portapapeles. «Conversar con el agente» te escucha, responde y vuelve a escucharte hasta que la termines."
    }

    private var manualPanel: some View {
        Panel {
            HStack(spacing: Theme.Space.m) {
                PanelLabel("Dictado manual")
                Spacer()
                if model.manualDictation || model.conversing {
                    StatusTag(tr("En marcha"), kind: .active)
                }
            }
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text(tr(manualStatus))
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.conversing {
                    BlockButton("Terminar conversación", systemImage: "stop.fill", kind: .primary, compact: true) {
                        model.actions?.toggleConversation()
                    }
                } else if model.manualDictation {
                    BlockButton("Cancelar", compact: true) { model.actions?.cancelManualDictation() }
                    BlockButton("Detener", systemImage: "stop.fill", kind: .primary, compact: true) {
                        model.actions?.toggleManualDictation(forAgent: false)
                    }
                } else {
                    BlockButton("Dictar texto", systemImage: "mic", kind: .primary, compact: true) {
                        model.actions?.toggleManualDictation(forAgent: false)
                    }
                    .disabled(manualBusy)
                    BlockButton("Conversar con el agente", systemImage: "bubble.left.and.bubble.right", compact: true) {
                        model.actions?.toggleConversation()
                    }
                    .disabled(manualBusy || model.activeAccount == nil)
                }
            }
            if !model.conversationLines.isEmpty {
                CardDivider()
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(model.conversationLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            MonoTag(text: tr(line.fromUser ? "Tú" : "SaySo"))
                            Text(line.text)
                                .font(Theme.body)
                                .foregroundStyle(line.fromUser ? Theme.secondary : Theme.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else if !model.manualTranscript.isEmpty {
                CardDivider()
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Text(model.manualTranscript)
                        .font(Theme.body)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !model.manualDictation {
                        BlockButton("Copiar", systemImage: "doc.on.doc", compact: true) {
                            model.actions?.copyToClipboard(model.manualTranscript)
                        }
                    }
                }
            }
        }
    }

    // MARK: Transcripción

    private var transcriptionPanel: some View {
        Panel {
            HStack(spacing: Theme.Space.m) {
                PanelLabel("Transcripción")
                Spacer()
                Text(tr("en este Mac")).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                BlockSegmented("Motor de transcripción",
                               selection: Binding(get: { settings.engine }, set: { v in update { $0.engine = v } }),
                               options: TranscriberEngine.allCases.map { ($0, $0.title) }, compact: true)
            }
            Text(tr(settings.engine.detail))
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let status = model.transcriberStatus {
                let progress = Self.percent(in: status)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Bit(size: 8, active: progress == nil || progress == 1, tone: .running)
                        Text(tr(status)).font(Theme.mono(11.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    if let progress, progress < 1 {
                        BlockProgress(value: progress, label: "Descarga del modelo")
                    }
                }
            }
            CardDivider()
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Corregir con IA").font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                    Text(tr(correctionDetail))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                BlockToggle(isOn: Binding(get: { settings.aiCorrection && model.activeAccount != nil },
                                          set: { v in update { $0.aiCorrection = v } }),
                            label: "Corregir con IA")
                    .disabled(model.activeAccount == nil)
            }
        }
    }

    // MARK: Permisos

    private struct PermissionItem: Identifiable {
        var kind: SystemPermissionKind
        var id: String { kind.rawValue }
    }

    private var permissionsNote: String {
        let missing = relevantPermissions.filter { !(model.systemPermissions[$0] ?? false) }.count
        return missing == 0 ? tr("Todos concedidos") : (missing == 1 ? tr("1 pendiente") : tr("%@ pendientes", "\(missing)"))
    }

    private func permissionTile(_ kind: SystemPermissionKind) -> some View {
        let granted = model.systemPermissions[kind] ?? false
        return Panel(padding: Theme.Space.m, fill: true) {
            HStack(alignment: .top) {
                IconTile(kind.icon, size: 26)
                Spacer(minLength: 4)
                if !granted { StatusTag("Pendiente", kind: .pending) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(kind.title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                Text(tr(kind.detail))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if granted {
                StateLine(text: "Concedido", on: true)
            } else {
                BlockButton("Conceder", kind: .primary, compact: true) { model.actions?.requestSystemPermission(kind) }
                    .accessibilityLabel(tr("Conceder %@", tr(kind.title)))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var correctionDetail: String {
        if model.activeAccount == nil {
            return "Necesita una cuenta de IA. Añádela en Modelo para corregir gramática y puntuación."
        }
        return "Para «Dictar texto»: arregla gramática y puntuación conservando tu estilo. Usa el modelo rápido."
    }

    /// Lee un porcentaje («Descargando 40 %») del texto de estado.
    static func percent(in text: String?) -> Double? {
        guard let text,
              let range = text.range(of: #"\d{1,3}(?=\s?%)"#, options: .regularExpression),
              let value = Double(text[range]) else { return nil }
        return min(value, 100) / 100
    }
}
