import SaySoCore
import SwiftUI

/// Pantalla Tareas: lo que el agente hace solo, a su hora.
struct TasksScreen: View {
    let model: AppModel
    @State private var draft = TaskDraft()
    @State private var editing: ScheduledTask?

    /// «Próxima: en 2 horas», con la tarea activa que antes toca.
    private var nextTag: String? {
        model.tasks.filter(\.enabled).compactMap(\.nextRun).min().map { tr("Próxima %@", RelativeDate.string($0)) }
    }

    private var countsNote: String? {
        guard !model.tasks.isEmpty else { return nil }
        let active = model.tasks.filter(\.enabled).count
        let paused = model.tasks.count - active
        return paused == 0 ? tr("%@ activas", "\(active)") : tr("%@ activas / %@ en pausa", "\(active)", "\(paused)")
    }

    private func watchDetail(_ watch: MessageWatch) -> String {
        var parts: [String] = []
        if let keyword = watch.keyword { parts.append(tr("solo si contiene «%@»", keyword)) }
        parts.append(watch.instruction.map { tr("el agente: %@", $0) } ?? tr("te avisa por el bot"))
        if let last = watch.lastFired { parts.append(tr("último %@", RelativeDate.string(last))) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "clock", title: "Tareas",
                         subtitle: "Encargos que el agente hace solo y te envía por Telegram, a ti o a quien elijas.",
                         tag: nextTag)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Nueva tarea")
                Panel {
                    TaskFormFields(model: model, draft: $draft, onSubmit: add)
                    CardDivider()
                    HStack(spacing: Theme.Space.s) {
                        MonoTag(text: draft.schedule.summary(), marked: true)
                        Text(draft.recipients.isEmpty ? tr("Te llega por Telegram")
                             : tr("Se envía a %@ desde tu cuenta", draft.recipients.names))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.s)
                        BlockButton("Programar", systemImage: "plus", kind: .primary, action: add)
                            .disabled(draft.problem != nil)
                    }
                }
                Text(tr("También puedes pedírselo al agente en el chat: «envíame mi calendario cada mañana a las 9»."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            let ideas = TaskTemplate.unused(given: model.tasks)
            if !ideas.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionBar("Ideas para empezar")
                    SettingsCard {
                        ForEach(Array(ideas.enumerated()), id: \.element.id) { index, idea in
                            if index > 0 { CardDivider() }
                            SettingRow(icon: idea.icon, title: idea.title,
                                       detail: idea.schedule.summary() + " · " + tr(idea.instruction)) {
                                BlockButton("Usar", compact: true) { draft = TaskDraft(idea.task) }
                                    .accessibilityLabel(tr("Usar la idea: %@", tr(idea.title)))
                            }
                        }
                    }
                    InlineNote("«Usar» rellena el formulario de arriba; la revisas y la programas tú.", systemImage: "info.circle")
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Programadas", note: countsNote)
                if model.tasks.isEmpty {
                    SettingsCard {
                        EmptyState(systemImage: "clock", title: "No hay tareas programadas",
                                   detail: "Crea una arriba o pídesela al agente por Telegram.")
                    }
                } else {
                    VStack(spacing: Theme.Space.s + 2) {
                        ForEach(model.tasks) { taskCard($0) }
                    }
                }
            }

            if !model.watches.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionBar("Avisos por mensajes", note: tr("%@ activos", "\(model.watches.count)"))
                    SettingsCard {
                        ForEach(Array(model.watches.enumerated()), id: \.element.id) { index, watch in
                            if index > 0 { CardDivider() }
                            SettingRow(icon: "bell", title: tr("Cuando escriban en «%@»", watch.chatTitle),
                                       detail: watchDetail(watch)) {
                                BlockButton("Quitar", kind: .destructive, compact: true) {
                                    model.actions?.deleteWatch(id: watch.id)
                                }
                                .accessibilityLabel(tr("Quitar el aviso de «%@»", watch.chatTitle))
                            }
                        }
                    }
                    InlineNote("Se crean pidiéndoselo al agente: «avísame cuando me escriba…».", systemImage: "info.circle")
                }
            }

            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionBar("Permisos")
                    SettingsCard {
                        ForEach(Array(TaskAction.descriptors.enumerated()), id: \.element.id) { index, descriptor in
                            if index > 0 { CardDivider() }
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tr(descriptor.title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                                    if !descriptor.detail.isEmpty {
                                        Text(tr(descriptor.detail))
                                            .font(Theme.caption)
                                            .foregroundStyle(Theme.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                RuleSegmented(descriptor.title, rule: Binding(
                                    get: { model.rule(for: descriptor) },
                                    set: { model.actions?.setRule($0, for: descriptor.id) }))
                            }
                            .padding(Theme.Space.m)
                            .accessibilityElement(children: .contain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionBar("Cómo funciona")
                    Panel(padding: Theme.Space.m) {
                        howItWorks("power", "Solo se ejecutan con el Mac despierto y el agente en marcha.")
                        howItWorks("arrow.uturn.forward", "Si una hora se pasa, la tarea se hace una vez al volver, no una por cada vez perdida.")
                        if model.telegramStatus == .disconnected {
                            howItWorks("paperplane", "Telegram no está conectado: el resultado de cada tarea solo se verá en esta pantalla.")
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { EditTaskSheet(model: model, task: $0) }
    }

    private func add() {
        guard draft.problem == nil else { return }
        model.actions?.addTask(instruction: draft.trimmed, schedule: draft.schedule, recipients: draft.recipients,
                               sendWithoutAsking: draft.sendWithoutAsking)
        draft = TaskDraft()
    }

    private func howItWorks(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(tr(text))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Tarjeta de tarea

    /// La hora en grande y debajo cada cuánto: «09:00 / CADA DÍA», «3 h / INTERVALO».
    private func clock(_ schedule: TaskSchedule) -> (big: String, small: String) {
        switch schedule {
        case let .daily(hour, minute, weekdays):
            let days = Set(weekdays)
            let small = days.isEmpty || days.count == 7 ? tr("Cada día")
                : days == [1, 2, 3, 4, 5] ? tr("Lun–vie") : tr("Días sueltos")
            return (String(format: "%02d:%02d", hour, minute), small)
        case let .every(minutes):
            return (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) min", tr("Intervalo"))
        case let .once(when):
            let f = DateFormatter()
            f.locale = L10n.locale
            f.dateFormat = "HH:mm"
            return (f.string(from: when), tr("Una vez"))
        }
    }

    private func taskCard(_ task: ScheduledTask) -> some View {
        let time = clock(task.schedule)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: time.big)
                    .font(Theme.mono(20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: time.small.uppercased())
                    .font(Theme.mono(11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                if !task.enabled { StatusTag("En pausa", kind: .neutral) }
            }
            .frame(width: 96, alignment: .leading)
            .padding(Theme.Space.m)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: task.schedule.summary()))

            Rectangle().fill(Theme.border).frame(width: 1)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: task.instruction)
                            .font(Theme.bodyStrong)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if !task.recipients.isEmpty {
                            Label(tr("Para %@", task.recipients.map(\.displayName).joined(separator: ", "))
                                  + (task.sendWithoutAsking ? " · " + tr("sin preguntar") : ""),
                                  systemImage: "arrow.turn.down.right")
                                .font(Theme.text(12, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(verbatim: statusLine(task))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let id = task.id {
                        BlockToggle(isOn: Binding(get: { task.enabled },
                                                  set: { model.actions?.setTaskEnabled($0, id: id) }),
                                    label: tr("Tarea activa: %@", task.instruction))
                    }
                }
                if let result = task.lastResult, !result.isEmpty {
                    Text(verbatim: result)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.s)
                        .background(Theme.paper)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
                        .accessibilityLabel(tr("Último resultado: %@", result))
                }
                if let id = task.id {
                    HStack(spacing: Theme.Space.s) {
                        BlockButton("Ejecutar ahora", systemImage: "play.fill", compact: true) {
                            model.actions?.runTaskNow(id: id)
                        }
                        .disabled(!model.agentRunning)
                        .accessibilityLabel(tr("Ejecutar ahora: %@", task.instruction))
                        BlockButton("Editar", systemImage: "pencil", compact: true) { editing = task }
                            .accessibilityLabel(tr("Editar tarea: %@", task.instruction))
                        Spacer(minLength: 0)
                        BlockButton("Eliminar", kind: .destructive, compact: true) {
                            model.actions?.deleteTask(id: id)
                        }
                        .accessibilityLabel(tr("Eliminar tarea: %@", task.instruction))
                    }
                }
            }
            .padding(Theme.Space.m)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
    }

    private func statusLine(_ task: ScheduledTask) -> String {
        var parts: [String] = []
        if task.enabled, let next = task.nextRun { parts.append(tr("próxima %@", RelativeDate.string(next))) }
        if let last = task.lastRun { parts.append(tr("última %@", RelativeDate.string(last))) }
        if parts.isEmpty { parts.append(tr(task.enabled ? "todavía sin ejecutar" : "detenida")) }
        return parts.joined(separator: " · ")
    }
}

