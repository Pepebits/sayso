import SaySoCore
import SwiftUI

/// Pantalla Ordenador: la máquina Linux del agente.
struct ComputerScreen: View {
    let model: AppModel
    @State private var command = ""
    @State private var confirmingDelete = false
    @State private var tab: Tab = .summary
    @FocusState private var promptFocused: Bool
    /// El usuario está usando la consola: el foco vuelve al campo al terminar cada comando.
    @State private var keepPromptFocus = false

    enum Tab: Hashable { case summary, desktop, activity }

    private var state: ComputerState { model.computerState }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "terminal", title: "Ordenador",
                         subtitle: "La máquina Linux donde trabaja el agente, aislada de tu Mac.",
                         tag: tr("Linux · aislado")) {
                HStack(spacing: Theme.Space.s) {
                    StatusTag(statusTitle, kind: statusKind)
                    if state == .running {
                        BlockButton("Apagar", systemImage: "stop.fill") { model.actions?.stopComputer() }
                            .accessibilityLabel(tr("Apagar la máquina Linux"))
                    }
                }
            }

            if state != .running { machineCard }

            if state != .notInstalled {
                BlockSegmented("Sección del ordenador", selection: $tab,
                               options: [(Tab.summary, "Resumen"), (.desktop, "Escritorio"), (.activity, "Actividad")])
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, alignment: .center)

                switch tab {
                case .summary:
                    if state == .running { resources }
                    console
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Panel(padding: Theme.Space.m, fill: true) {
                            HStack(alignment: .top, spacing: Theme.Space.s + 2) {
                                Image(systemName: "moon")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tr("Se apaga sola")).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                                    Text(tr("Tras 10 minutos sin uso. Vuelve a arrancar cuando hace falta."))
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Panel(padding: Theme.Space.m, fill: true) {
                            HStack(alignment: .center, spacing: Theme.Space.m) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tr("Borrar la máquina")).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                                    Text(tr("Elimina el disco y todo lo que haya en ~/sayso. No se puede deshacer."))
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                BlockButton("Borrar", kind: .destructive) { confirmingDelete = true }
                                    .disabled(state.isBusy)
                                    .accessibilityLabel(tr("Borrar la máquina"))
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    sizing
                case .desktop:
                    desktop
                case .activity:
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack {
                            SectionLabel("Actividad del agente")
                            Spacer()
                            BlockButton("Vaciar", kind: .destructive, compact: true) {
                                model.actions?.clearActivity(scope: "vm")
                            }
                            .disabled(model.computerActivity.isEmpty)
                            .accessibilityLabel("Vaciar la actividad del ordenador")
                        }
                        ActivityList(model: model, scope: "vm", entries: model.computerActivity,
                                     emptyDetail: "Aquí verás cada comando y archivo que el agente toque en su Linux.")
                    }
                }
            }
        }
        .confirmationDialog("¿Borrar la máquina Linux?", isPresented: $confirmingDelete) {
            Button("Borrar la máquina", role: .destructive) { model.actions?.deleteComputer() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(tr("Se perderá todo lo que haya dentro. Tendrás que volver a descargar la imagen."))
        }
    }

    // MARK: - Estado

    private var statusTitle: String {
        switch state {
        case .notInstalled: return "Sin instalar"
        case .preparing: return "Instalando"
        case .starting: return "Arrancando"
        case .running: return "En marcha"
        case .paused: return "En pausa"
        case .stopped: return "Apagada"
        case .failed: return "Error"
        }
    }

    private var statusKind: StatusTag.Kind {
        switch state {
        case .running: return .active
        case .preparing, .starting: return .connecting
        case .paused: return .pending
        case .failed: return .error
        case .notInstalled, .stopped: return .neutral
        }
    }

    @ViewBuilder
    private var machineCard: some View {
        SettingsCard {
            switch state {
            case .notInstalled:
                SettingRow(icon: "shippingbox", title: "Debian 13 para el agente",
                           detail: "Descarga de unos 300 MB desde debian.org, verificada por hash. Usa 2 núcleos, 4 GB de memoria y hasta 16 GB de disco.") {
                    BlockButton(model.computerPartialDownload ? "Seguir descargando" : "Instalar", systemImage: "arrow.down", kind: .primary) { model.actions?.startComputer() }
                }
            case let .preparing(text, progress):
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        Text(tr(text)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                        Spacer()
                        if let progress {
                            Text(verbatim: "\(Int(progress * 100)) %").font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                        }
                        if progress != nil {
                            BlockButton("Cancelar", compact: true) { model.actions?.cancelComputerInstall() }
                                .help(tr("Lo descargado se guarda: al volver a instalar, sigue donde se quedó."))
                        }
                    }
                    if let progress {
                        BlockProgress(value: progress, label: text)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(Theme.Space.l)
            case .starting:
                SettingRow(icon: "power", title: "Arrancando Linux",
                           detail: "El primer arranque configura la máquina y puede tardar uno o dos minutos.") {
                    ProgressView().controlSize(.small)
                }
            case .running:
                EmptyView()
            case .paused:
                SettingRow(icon: "pause", title: "En pausa",
                           detail: "Se pausó al detener el agente. No consume CPU.") {
                    BlockButton("Reanudar", systemImage: "play.fill", kind: .primary) { model.actions?.startComputer() }
                }
            case .stopped:
                SettingRow(icon: "shippingbox", title: "Debian 13 · arm64",
                           detail: "Apagada. Arranca sola cuando el agente la necesita.") {
                    BlockButton("Arrancar", systemImage: "play.fill", kind: .primary) { model.actions?.startComputer() }
                }
            case let .failed(message):
                SettingRow(icon: "exclamationmark.triangle", title: "No se pudo arrancar", detail: message) {
                    BlockButton("Reintentar", systemImage: "arrow.clockwise", kind: .primary) {
                        model.actions?.startComputer()
                    }
                }
            }
        }
    }

    // MARK: - Escritorio

    private var desktop: some View {
        SettingsSection("Escritorio",
                        footer: "La ventana muestra la pantalla de la máquina y acepta tu teclado y tu ratón. El agente todavía no ve la pantalla: trabaja por terminal.") {
            SettingsCard {
                switch model.desktopState {
                case .notInstalled:
                    SettingRow(icon: "display", title: "Escritorio gráfico y navegador",
                               detail: "Instala Xfce y Firefox dentro de la máquina. Descarga unos 400 MB y tarda unos minutos.") {
                        HStack(spacing: Theme.Space.s) {
                            BlockButton("Ver consola", compact: true) { model.actions?.openDesktop() }
                            BlockButton("Instalar", systemImage: "arrow.down", kind: .primary, compact: true) {
                                model.actions?.installDesktop()
                            }
                            .accessibilityLabel("Instalar el escritorio")
                        }
                    }
                case .installing:
                    SettingRow(icon: "display", title: "Instalando el escritorio",
                               detail: "Descargando e instalando paquetes en la máquina Linux. Puedes seguir usando la app.") {
                        ProgressView().controlSize(.small)
                    }
                case .installed:
                    SettingRow(icon: "display", title: "Xfce y Firefox",
                               detail: "Arranca al abrir la ventana y se para al cerrarla, para no gastar memoria de fondo.") {
                        BlockButton("Abrir escritorio", systemImage: "macwindow", kind: .primary) {
                            model.actions?.openDesktop()
                        }
                    }
                case let .failed(message):
                    SettingRow(icon: "exclamationmark.triangle", title: "No se pudo instalar el escritorio", detail: message) {
                        BlockButton("Reintentar", systemImage: "arrow.clockwise", kind: .primary) {
                            model.actions?.installDesktop()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tamaño de la máquina

    /// Núcleos, memoria y disco para el siguiente arranque.
    private var sizing: some View {
        let current = model.computerResources
        func set(_ change: (inout ComputerResources) -> Void) {
            var next = current
            change(&next)
            model.actions?.setComputerResources(next)
        }
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel("Tamaño de la máquina")
            Panel {
                SettingRow(icon: "cpu", title: "Núcleos", detail: "Para el agente; el Mac se queda siempre con dos.") {
                    BlockSegmented("Núcleos de la máquina Linux",
                                   selection: Binding(get: { current.cpuCount }, set: { v in set { $0.cpuCount = v } }),
                                   options: ComputerResources.cpuOptions().map { ($0, "\($0)") }, compact: true)
                }
                CardDivider()
                SettingRow(icon: "memorychip", title: "Memoria",
                           detail: "Como mucho la mitad de la del Mac. Solo la usa mientras está en marcha.") {
                    BlockSegmented("Memoria de la máquina Linux",
                                   selection: Binding(get: { current.memoryGB }, set: { v in set { $0.memoryGB = v } }),
                                   options: ComputerResources.memoryOptions().map { ($0, "\($0) GB") }, compact: true)
                }
                CardDivider()
                SettingRow(icon: "internaldrive", title: "Disco",
                           detail: "Solo ocupa en el Mac lo que se usa de verdad. Se puede ampliar, pero no reducir.") {
                    BlockSegmented("Disco de la máquina Linux",
                                   selection: Binding(get: { current.diskGB }, set: { v in set { $0.diskGB = v } }),
                                   options: ComputerResources.diskOptions(current: model.computerDiskGB).map { ($0, "\($0) GB") },
                                   compact: true)
                }
            }
            InlineNote("Los cambios se aplican la próxima vez que arranque la máquina.", systemImage: "arrow.clockwise")
        }
    }

    // MARK: - Recursos

    /// Cuatro módulos en fila: la máquina y sus tres medidores.
    private var resources: some View {
        HStack(alignment: .top, spacing: Theme.Space.s + 2) {
            StatTile(title: "Máquina", value: "Debian 13", detail: "arm64 · " + tr("aislada"))
            if let stats = model.computerStats {
                StatTile(title: "CPU", value: "\(Int(stats.cpuPercent.rounded())) %",
                         detail: tr("%@ núcleos", "\(stats.cpuCount)"), progress: stats.cpuPercent / 100)
                StatTile(title: "Memoria", value: percent(stats.memoryUsed, stats.memoryTotal),
                         detail: tr("%@ de %@", bytes(stats.memoryUsed), bytes(stats.memoryTotal)),
                         progress: ratio(stats.memoryUsed, stats.memoryTotal))
                StatTile(title: "Disco", value: percent(stats.diskUsed, stats.diskTotal),
                         detail: tr("%@ de %@", bytes(stats.diskUsed), bytes(stats.diskTotal)),
                         progress: ratio(stats.diskUsed, stats.diskTotal))
            } else {
                StatTile(title: "Recursos", value: tr("Midiendo…"))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func percent(_ used: UInt64, _ total: UInt64) -> String {
        "\(Int((ratio(used, total) * 100).rounded())) %"
    }

    private func ratio(_ used: UInt64, _ total: UInt64) -> Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    // MARK: - Terminal

    // MARK: - Consola

    /// «Tomar el control»: la consola del agente. Se ven sus comandos y se pueden lanzar otros en
    /// la misma carpeta de trabajo, con una sesión que recuerda dónde estás.
    private var console: some View {
        SettingsSection("Tomar el control",
                        footer: "Una sesión de bash en ~/sayso con el usuario del agente: «cd» y las variables se conservan entre comandos. Aquí aparecen también los comandos que lanza el agente. No admite programas de pantalla completa como vim o top.") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    IconTile("terminal", size: 22, inverted: true)
                    Text(tr("El terminal del agente"))
                        .font(Theme.text(12.5, weight: .semibold))
                        .foregroundStyle(Theme.fixedBone)
                    Spacer()
                    consoleButton("Vaciar") { model.actions?.clearConsole() }
                        .disabled(model.terminal.isEmpty)
                    consoleButton("Reiniciar sesión") { model.actions?.resetConsole() }
                        .accessibilityHint(tr("Cierra la sesión, detiene lo que esté en marcha y vuelve a ~/sayso"))
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.consoleBar)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if model.terminal.isEmpty {
                            Text(tr("Escribe un comando abajo. Lo que haga el agente aparecerá aquí."))
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.fixedBone.opacity(0.7))
                        }
                        ForEach(model.terminal) { entry in TerminalEntryView(entry: entry).equatable() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                }
                .frame(minHeight: 120, maxHeight: 300)
                .defaultScrollAnchor(.bottom)

                Rectangle().fill(Color(hex: 0x383635)).frame(height: 1)
                HStack(spacing: 6) {
                    Text(verbatim: "\(model.consoleDirectory) $")
                        .font(Theme.mono(12.5, weight: .bold))
                        .foregroundStyle(Theme.fixedBone)
                        .accessibilityHidden(true)
                    ZStack(alignment: .leading) {
                        if command.isEmpty {
                            Text(tr(model.consoleBusy ? "Esperando a que termine…" : "comando"))
                                .font(Theme.mono(12.5))
                                .foregroundStyle(Theme.fixedBone.opacity(0.6))
                                .accessibilityHidden(true)
                        }
                        TextField("", text: $command)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12.5))
                            .foregroundStyle(Theme.fixedBone)
                            .focused($promptFocused)
                            .onSubmit(submit)
                            // No se desactiva mientras corre un comando: desactivarlo le quita el
                            // foco y había que volver a pulsar en el campo tras cada Intro. Se puede
                            // ir escribiendo el siguiente; el envío espera a que termine el actual.
                            .disabled(state == .paused || state.isBusy)
                            .onChange(of: model.consoleBusy) { _, busy in
                                if !busy, keepPromptFocus { promptFocused = true }
                            }
                            .accessibilityLabel(tr("Comando para la consola, en %@", model.consoleDirectory))
                    }
                    if model.consoleBusy { ProgressView().controlSize(.small).tint(Theme.fixedBone) }
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: 36)
                .overlay(alignment: .bottom) {
                    if promptFocused { Rectangle().fill(Theme.fixedBone).frame(height: 2) }
                }
            }
            .background(Theme.console)
            // En oscuro el contorno es lo que separa la consola del fondo de la ventana.
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.controlBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
    }

    private func consoleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(tr(title))
                .font(Theme.text(11.5, weight: .semibold))
                .foregroundStyle(Theme.fixedBone)
                .padding(.horizontal, 8)
                .frame(minHeight: 24)
                .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius).strokeBorder(Theme.fixedBone.opacity(0.55), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // En macOS, Intro da por terminada la edición: se devuelve el foco al campo.
        keepPromptFocus = true
        DispatchQueue.main.async { promptFocused = true }
        guard !text.isEmpty, !model.consoleBusy else { return }
        model.actions?.runComputerCommand(text)
        command = ""
    }
}

/// Una entrada de la consola, con vista propia: mientras llega salida solo se redibuja la que
/// cambia, no las ochenta anteriores.
private struct TerminalEntryView: View, Equatable {
    let entry: TerminalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(entry.directory) $ \(entry.command)")
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.fixedBone)
                if entry.author == .agent {
                    Text(tr("agente").uppercased())
                        .font(Theme.mono(11, weight: .bold))
                        .foregroundStyle(Theme.fixedInk)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.fixedBone)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius))
                }
            }
            if !entry.output.isEmpty {
                Text(verbatim: entry.output).font(Theme.mono(12)).foregroundStyle(Theme.fixedBone.opacity(0.85))
            }
            if let error = entry.error {
                Text(verbatim: error).font(Theme.mono(12)).foregroundStyle(Color(hex: Palette.destructive.dark))
            } else if let code = entry.exitCode, code != 0 {
                Text(code == 124 ? tr("tiempo agotado") : tr("salida %@", "\(code)"))
                    .font(Theme.mono(11))
                    .foregroundStyle(Color(hex: Palette.destructive.dark))
            } else if entry.isRunning, entry.output.isEmpty {
                Text(verbatim: "…").font(Theme.mono(12)).foregroundStyle(Theme.fixedBone.opacity(0.7))
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
