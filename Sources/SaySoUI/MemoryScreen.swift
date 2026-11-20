import SaySoCore
import SwiftUI

/// Pantalla Memoria: notas que el agente recuerda.
struct MemoryScreen: View {
    enum Filter: Hashable { case all, instructions, facts }

    let model: AppModel
    @State private var draft = ""
    /// `nil`: lo decide la app según cómo empiece el texto, hasta que el usuario elige.
    @State private var draftKind: MemoryNote.Kind?
    /// Nota que se está editando y lo escrito mientras tanto.
    @State private var editingID: Int64?
    @State private var editText = ""
    @State private var editKind: MemoryNote.Kind = .fact
    @State private var filter: Filter = .all
    @State private var query = ""

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var instructions: [MemoryNote] { model.notes.filter { $0.kind == .instruction } }
    private var facts: [MemoryNote] { model.notes.filter { $0.kind == .fact } }

    /// El tipo con el que se guardará la nota que se está escribiendo.
    private var effectiveKind: MemoryNote.Kind {
        draftKind ?? (MemoryNote.looksLikeInstruction(draft) ? .instruction : .fact)
    }

    private var shown: [NoteItem] {
        let base: [MemoryNote]
        switch filter {
        case .all: base = model.notes
        case .instructions: base = instructions
        case .facts: base = facts
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        let found = q.isEmpty ? base
            : base.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return found.enumerated().map { NoteItem(id: $0.element.id.map { "n\($0)" } ?? "i\($0.offset)", note: $0.element) }
    }

    private struct NoteItem: Identifiable {
        var id: String
        var note: MemoryNote
    }

    private var countTag: String {
        switch model.notes.count {
        case 0: return tr("Sin notas")
        case 1: return tr("1 nota")
        default: return tr("%@ notas", "\(model.notes.count)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "book.closed", title: "Memoria",
                         subtitle: "Lo que el agente sabe de ti y lo que le has pedido que haga siempre.", tag: countTag) {
                LabeledToggleBox(title: "Recordar cosas nuevas",
                                 isOn: Binding(get: { model.rememberNew }, set: { model.actions?.setRememberNew($0) }))
            }

            if !model.contexts.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionBar("Contexto en uso", note: tr("lo que acompaña a cada petición"))
                    TileGrid(model.contexts, columns: 2, minTileWidth: 260) { contextCard($0) }
                    Text(tr("Cada petición lleva las instrucciones, tus notas, las herramientas y los últimos %@ turnos de esa conversación. Tras %@ horas sin hablar, la conversación empieza de cero sola.",
                            "\(AgentLoopLimits.turns)", "\(AgentLoopLimits.idleHours)"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Añadir una nota")
                HStack(spacing: Theme.Space.s) {
                    BlockField("Por ejemplo: respóndeme con frases cortas", text: $draft, label: "Nueva nota")
                        .onSubmit(add)
                    BlockSegmented("Tipo de nota",
                                   selection: Binding(get: { effectiveKind }, set: { draftKind = $0 }),
                                   options: [(MemoryNote.Kind.instruction, "Instrucción"), (.fact, "Dato")], compact: true)
                        .fixedSize()
                    BlockButton("Añadir", systemImage: "plus", kind: .primary, action: add)
                        .disabled(trimmed.isEmpty)
                        .accessibilityLabel(tr("Añadir la nota"))
                }
                Text(tr(effectiveKind == .instruction
                        ? "Instrucción: el agente la sigue siempre, también en las tareas programadas."
                        : "Dato: el agente lo tiene en cuenta como información, no como una orden."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 2)
            }

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionBar("Notas guardadas",
                           note: shown.count == model.notes.count ? nil
                               : tr("%@ de %@", "\(shown.count)", "\(model.notes.count)"))
                if model.notes.isEmpty {
                    SettingsCard {
                        EmptyState(systemImage: "book.closed",
                                   title: "Todavía no hay notas",
                                   detail: "Escribe una arriba o pídele al agente que recuerde algo.")
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Space.m) { filterPicker; Spacer(minLength: 0); searchField.frame(width: 210) }
                        VStack(alignment: .leading, spacing: Theme.Space.s) { filterPicker; searchField }
                    }
                    if shown.isEmpty {
                        SettingsCard {
                            EmptyState(systemImage: "magnifyingglass", title: "Ninguna nota coincide",
                                       detail: "Prueba con otra palabra o cambia el filtro.")
                        }
                    } else {
                        TileGrid(shown, columns: 2, minTileWidth: 260) { noteCard($0.note) }
                    }
                }
            }

            Panel(padding: Theme.Space.m) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    Image(systemName: "lock")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityHidden(true)
                    Text("Las notas se guardan solo en este Mac y acompañan a cada petición al modelo. No guardes contraseñas: para eso está Secretos.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MonoTag(text: tr("%@ caracteres", "\(model.notes.reduce(0) { $0 + $1.text.count })"))
                }
            }
        }
    }

    private var filterPicker: some View {
        BlockSegmented("Qué notas se muestran", selection: $filter,
                       options: [(Filter.all, tr("Todas (%@)", "\(model.notes.count)")),
                                 (.instructions, tr("Instrucciones (%@)", "\(instructions.count)")),
                                 (.facts, tr("Datos (%@)", "\(facts.count)"))],
                       compact: true)
    }

    private var searchField: some View {
        BlockField("Buscar en las notas…", text: $query, label: "Buscar en las notas")
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        model.actions?.addNote(trimmed, kind: effectiveKind)
        draft = ""
        draftKind = nil
    }

    private func noteCard(_ note: MemoryNote) -> some View {
        let byAgent = note.source == "agente"
        let editing = note.id != nil && note.id == editingID
        return VStack(alignment: .leading, spacing: 0) {
            if editing {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    BlockField("Texto de la nota", text: $editText, label: "Texto de la nota")
                        .onSubmit(saveEdit)
                    BlockSegmented("Tipo de nota", selection: $editKind,
                                   options: [(MemoryNote.Kind.instruction, "Instrucción"), (.fact, "Dato")], compact: true)
                        .fixedSize()
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(note.text)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            CardDivider()
            HStack(spacing: Theme.Space.s) {
                if editing {
                    Spacer(minLength: 0)
                    BlockButton("Cancelar", compact: true) { editingID = nil }
                        .keyboardShortcut(.cancelAction)
                    BlockButton("Guardar", kind: .primary, compact: true, action: saveEdit)
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (editText.trimmingCharacters(in: .whitespacesAndNewlines) == note.text && editKind == note.kind))
                } else {
                    // Quién la guardó se dice con un glifo y con texto, no con un color.
                    Image(systemName: byAgent ? "cpu" : "person")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: "\(byAgent ? tr("agente") : tr("tú")) · \(RelativeDate.string(note.createdAt))")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(Text(verbatim: "\(byAgent ? tr("La guardó el agente") : tr("La añadiste tú")), \(RelativeDate.string(note.createdAt))"))
                    Spacer(minLength: 0)
                    if let id = note.id {
                        kindToggle(note, id: id)
                        // Solo el lápiz: con el texto, la fecha de la nota no cabía en dos columnas.
                        Button { beginEdit(note) } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 28, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.controlBorder, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tr("Editar"))
                        .accessibilityLabel(tr("Editar nota: %@", note.text))
                        BlockButton("Olvidar", kind: .destructive, compact: true) { model.actions?.forgetNote(id: id) }
                            .accessibilityLabel(tr("Olvidar nota: %@", note.text))
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(editing ? Theme.controlBorder : Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
    }

    private func beginEdit(_ note: MemoryNote) {
        editText = note.text
        editKind = note.kind
        editingID = note.id
    }

    private func saveEdit() {
        guard let id = editingID else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.actions?.updateNote(id: id, text: text, kind: editKind)
        editingID = nil
    }

    /// Etiqueta del tipo que, al pulsarla, cambia la nota al otro.
    private func kindToggle(_ note: MemoryNote, id: Int64) -> some View {
        let isOrder = note.kind == .instruction
        return Button {
            model.actions?.setNoteKind(isOrder ? .fact : .instruction, id: id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOrder ? "arrow.turn.down.right" : "info.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text(tr(isOrder ? "Instrucción" : "Dato"))
                    .font(Theme.mono(11, weight: .semibold))
            }
            .foregroundStyle(isOrder ? Theme.paper : Theme.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(isOrder ? Theme.ink : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.controlBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Antes se recorta la fecha que el tipo: el tipo es lo que importa.
        .fixedSize()
        .help(tr(isOrder ? "Pulsa para tratarla como dato" : "Pulsa para tratarla como instrucción"))
        .accessibilityLabel(tr(isOrder ? "Instrucción. Pulsa para tratarla como dato" : "Dato. Pulsa para tratarla como instrucción"))
    }

    // MARK: Contexto

    private func contextTitle(_ context: ConversationContext) -> String {
        context.chatID == "voz" ? "Conversación por voz" : "Conversación por el bot"
    }

    private func tokens(_ usage: ContextUsage) -> String {
        let number = usage.inputTokens.formatted(.number.locale(L10n.locale))
        return usage.measured ? tr("%@ tokens", number) : tr("≈ %@ tokens", number)
    }

    private func contextCard(_ context: ConversationContext) -> some View {
        Panel(padding: Theme.Space.m, fill: true) {
            HStack(alignment: .firstTextBaseline) {
                PanelLabel(contextTitle(context))
                Spacer()
                if let usage = context.usage { MonoTag(text: usage.model) }
            }
            if let usage = context.usage {
                Text(tokens(usage))
                    .font(Theme.display(24))
                    .foregroundStyle(Theme.ink)
                Text(tr("en la última petición, %@", RelativeDate.string(usage.date)))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
            } else {
                Text(tr("Vacía"))
                    .font(Theme.display(24))
                    .foregroundStyle(Theme.ink)
                Text(tr("La próxima petición empieza sin historial."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                BlockProgress(value: Double(context.turnsInWindow) / Double(max(1, context.windowLimit)),
                              label: "Historial en uso")
                Text(tr("%@ de %@ turnos de historial", "\(context.turnsInWindow)", "\(context.windowLimit)"))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.secondary)
                if let usage = context.usage {
                    Text(tr("%@ notas · %@ herramientas", "\(usage.notes)", "\(usage.tools)"))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
            BlockButton("Nueva conversación", systemImage: "arrow.counterclockwise", compact: true) {
                model.actions?.newConversation(chatID: context.chatID)
            }
            .disabled(context.turnsInWindow == 0 && context.lastActivity == nil)
        }
    }
}

/// Límites del historial, para explicarlos en pantalla sin depender del módulo del agente.
enum AgentLoopLimits {
    static let turns = 30
    static let idleHours = 2
}
