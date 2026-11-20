import SaySoCore
import SwiftUI

/// Lo que se está escribiendo de una tarea, nueva o editada.
struct TaskDraft: Equatable {
    enum Kind: Hashable { case daily, interval, once }
    enum Days: Hashable { case all, weekdays, custom }

    var instruction = ""
    var kind: Kind = .daily
    var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    var days: Days = .all
    var customDays: Set<Int> = [1, 2, 3, 4, 5]
    var minutes = 60
    var onceDate = Date().addingTimeInterval(3600)
    var recipients: [TaskRecipient] = []
    var sendWithoutAsking = false

    init() {}

    init(_ task: ScheduledTask) {
        instruction = task.instruction
        recipients = task.recipients
        sendWithoutAsking = task.sendWithoutAsking
        switch task.schedule {
        case let .daily(hour, minute, weekdays):
            kind = .daily
            time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? time
            let set = Set(weekdays)
            if set.isEmpty || set.count == 7 {
                days = .all
            } else if set == [1, 2, 3, 4, 5] {
                days = .weekdays
            } else {
                days = .custom
                customDays = set
            }
        case let .every(value):
            kind = .interval
            minutes = value
        case let .once(when):
            kind = .once
            onceDate = when
        }
    }

    var trimmed: String { instruction.trimmingCharacters(in: .whitespacesAndNewlines) }

    var schedule: TaskSchedule {
        switch kind {
        case .daily:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            let weekdays: [Int]
            switch days {
            case .all: weekdays = []
            case .weekdays: weekdays = [1, 2, 3, 4, 5]
            case .custom: weekdays = customDays.sorted()
            }
            return .daily(hour: c.hour ?? 9, minute: c.minute ?? 0, weekdays: weekdays)
        case .interval:
            return .every(minutes: minutes)
        case .once:
            return .once(onceDate)
        }
    }

    /// Cambia algo de lo que se guarda (los campos ocultos de otro tipo de horario no cuentan).
    func changes(_ task: ScheduledTask) -> Bool {
        trimmed != task.instruction || schedule != task.schedule || recipients != task.recipients
            || (sendWithoutAsking && !recipients.isEmpty) != task.sendWithoutAsking
    }

    /// Por qué no se puede guardar todavía, o `nil`.
    var problem: String? {
        if trimmed.isEmpty { return "Escribe qué debe hacer." }
        if kind == .daily, days == .custom, customDays.isEmpty { return "Elige al menos un día." }
        if kind == .once, onceDate <= Date() { return "Esa fecha ya ha pasado." }
        return nil
    }
}

/// Campos de una tarea: qué hace, cuándo y para quién. Sirve para crearla y para editarla.
struct TaskFormFields: View {
    let model: AppModel
    @Binding var draft: TaskDraft
    var onSubmit: () -> Void = {}

    /// Intervalos de siempre más el de la tarea, si el agente puso otro.
    private var intervalOptions: [(Int, String)] {
        var values = [15, 60, 180, 720]
        if !values.contains(draft.minutes) { values.append(draft.minutes); values.sort() }
        return values.map { ($0, $0 % 60 == 0 ? "\($0 / 60) h" : "\($0) min") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            BlockField("Resume mi calendario de hoy", text: $draft.instruction, label: "Qué debe hacer")
                .onSubmit(onSubmit)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.m) { kindPicker; detailPicker; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: Theme.Space.s) { kindPicker; detailPicker }
            }
            if draft.kind == .daily, draft.days == .custom {
                dayToggles
            }
            CardDivider()
            RecipientPicker(model: model, recipients: $draft.recipients)
            if !draft.recipients.isEmpty {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Enviar sin pedir confirmación")).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                        Text(draft.sendWithoutAsking
                             ? tr("Lo que mande esta tarea a estos destinatarios sale sin preguntarte en el Mac, aunque la regla de envío sea Preguntar. A cualquier otra persona, se pregunta como siempre.")
                             : tr("Cada envío a estos destinatarios sigue tu regla de envío y, si es Preguntar, te lo pregunta en el Mac."))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    BlockToggle(isOn: $draft.sendWithoutAsking, label: "Enviar sin pedir confirmación")
                }
            }
        }
    }

    private var kindPicker: some View {
        BlockSegmented("Repetición", selection: $draft.kind,
                       options: [(.daily, "A una hora"), (.interval, "Cada cierto tiempo"), (.once, "Una vez")],
                       compact: true)
    }

    @ViewBuilder
    private var detailPicker: some View {
        switch draft.kind {
        case .daily:
            HStack(spacing: Theme.Space.m) {
                DatePicker("Hora", selection: $draft.time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .accessibilityLabel(tr("Hora"))
                    .fixedSize()
                BlockSegmented("Días", selection: $draft.days,
                               options: [(.all, "Todos los días"), (.weekdays, "Lun–vie"), (.custom, "Elegir")],
                               compact: true)
            }
        case .interval:
            BlockSegmented("Intervalo", selection: $draft.minutes, options: intervalOptions, compact: true)
        case .once:
            DatePicker("Fecha y hora", selection: $draft.onceDate, in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .accessibilityLabel(tr("Fecha y hora"))
                .fixedSize()
        }
    }

    private var dayToggles: some View {
        let names = ["L", "M", "X", "J", "V", "S", "D"]
        let full = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
        return HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                let on = draft.customDays.contains(day)
                Button {
                    if on { draft.customDays.remove(day) } else { draft.customDays.insert(day) }
                } label: {
                    Text(tr(names[day - 1]))
                        .font(Theme.mono(12, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .foregroundStyle(on ? Theme.paper : Theme.ink)
                        .background(on ? Theme.ink : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.controlBorder, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(full[day - 1]))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Hoja para cambiar una tarea ya programada.
struct EditTaskSheet: View {
    let model: AppModel
    let task: ScheduledTask
    @State private var draft: TaskDraft
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, task: ScheduledTask) {
        self.model = model
        self.task = task
        _draft = State(initialValue: TaskDraft(task))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("Editar tarea"))
                    .font(Theme.display(20))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Space.m)
                MonoTag(text: draft.schedule.summary(), marked: true)
            }
            TaskFormFields(model: model, draft: $draft, onSubmit: save)
            HStack(spacing: Theme.Space.s) {
                if let problem = draft.problem {
                    Text(tr(problem)).font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
                BlockButton("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                BlockButton("Guardar", kind: .primary, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.problem != nil || !draft.changes(task))
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 600)
        .background(Theme.paper)
    }

    private func save() {
        guard draft.problem == nil, let id = task.id else { return }
        model.actions?.updateTask(id: id, instruction: draft.trimmed, schedule: draft.schedule,
                                  recipients: draft.recipients, sendWithoutAsking: draft.sendWithoutAsking)
        dismiss()
    }
}

// MARK: - Destinatarios

/// Busca personas y grupos de la cuenta de Telegram y los añade como fichas.
struct RecipientPicker: View {
    let model: AppModel
    @Binding var recipients: [TaskRecipient]

    @State private var query = ""
    @State private var results: [TaskRecipient] = []
    @State private var searching = false

    /// Como mucho, los mismos que acepta el agente.
    static let maxRecipients = 10

    /// Lo encontrado, sin los que ya están elegidos.
    private var pending: [TaskRecipient] {
        results.filter { option in !recipients.contains { $0.id == option.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(tr("Enviar a")).font(Theme.text(12, weight: .semibold)).foregroundStyle(Theme.ink)
                if recipients.isEmpty {
                    MonoTag(text: tr("a ti, por el bot"))
                } else {
                    Text(tr("%@ de %@", "\(recipients.count)", "\(Self.maxRecipients)"))
                        .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            if !recipients.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(recipients) { chip($0) }
                }
            }
            if model.telegramUser.isReady {
                if recipients.count < Self.maxRecipients {
                    BlockField(recipients.isEmpty ? "O busca personas o grupos de tu Telegram…" : "Añadir otro destinatario…",
                               text: $query, label: "Buscar destinatario")
                        .task(id: query) { await search(query) }
                        .onSubmit { if let first = pending.first { choose(first) } }
                }
                if !pending.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(pending.enumerated()), id: \.element.id) { index, option in
                            if index > 0 { CardDivider() }
                            row(option)
                        }
                    }
                    .background(Theme.paper)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
                } else if !searching, results.isEmpty, query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    Text(tr("No hay ningún chat que coincida."))
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            } else {
                Text(tr("Para enviárselo a otras personas, inicia sesión con tu cuenta en SaySo → Telegram."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ option: TaskRecipient) -> some View {
        Button { choose(option) } label: {
            HStack(spacing: Theme.Space.s) {
                ChatAvatar(model: model, recipient: option, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: option.title).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
                    if let alias = option.username {
                        Text(verbatim: "@" + alias).font(Theme.mono(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(tr(option.kind)).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Añadir a %@", option.displayName))
    }

    private func chip(_ recipient: TaskRecipient) -> some View {
        HStack(spacing: 6) {
            ChatAvatar(model: model, recipient: recipient, size: 20, onInk: true)
            Text(verbatim: recipient.title).font(Theme.bodyStrong).lineLimit(1)
            if let alias = recipient.username {
                Text(verbatim: "@" + alias).font(Theme.mono(11)).lineLimit(1).opacity(0.8)
            }
            Button {
                recipients.removeAll { $0.id == recipient.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Quitar a %@", recipient.title))
        }
        .foregroundStyle(Theme.paper)
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityElement(children: .contain)
    }

    private func choose(_ option: TaskRecipient) {
        guard recipients.count < Self.maxRecipients, !recipients.contains(where: { $0.id == option.id }) else { return }
        recipients.append(option)
        query = ""
        results = []
    }

    /// Busca al escribir, con una pausa corta para no preguntar a Telegram en cada letra.
    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { results = []; return }
        searching = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        let found = await model.actions?.searchRecipients(trimmed) ?? []
        guard !Task.isCancelled else { return }
        results = found
        searching = false
    }
}

/// Foto de perfil de un chat; mientras llega, o si no tiene, sus iniciales.
struct ChatAvatar: View {
    let model: AppModel
    let recipient: TaskRecipient
    var size: CGFloat = 26
    /// Sobre fondo de tinta (en las fichas): las iniciales van en claro.
    var onInk = false
    @State private var url: URL?

    private var initials: String {
        let words = recipient.title.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Text(verbatim: initials)
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(onInk ? Theme.ink : Theme.paper)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(onInk ? Theme.paper : Theme.ink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius + 1))
        .accessibilityHidden(true)
        .task(id: recipient.id) { url = await model.actions?.chatPhoto(recipient.id) }
    }
}

/// Coloca sus vistas en fila y salta de línea cuando no caben.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
