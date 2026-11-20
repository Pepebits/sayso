import SaySoCore
import SwiftUI

/// Pantallas de la ventana de ajustes.
public enum SettingsScreen: String, CaseIterable, Identifiable, Hashable {
    case inicio, dictado, modelo, ordenador, plugins, tareas, memoria, telegram, mac, secretos, estadisticas, registros, ajustes

    public var id: String { rawValue }

    enum Group: String { case none = "", agente = "Agente", permisos = "Permisos", sistema = "Sistema" }

    var group: Group {
        switch self {
        case .inicio, .dictado: return .none
        case .modelo, .ordenador, .plugins, .tareas, .memoria: return .agente
        case .telegram, .mac, .secretos: return .permisos
        case .estadisticas, .registros, .ajustes: return .sistema
        }
    }

    var title: String {
        switch self {
        case .inicio: return "Inicio"
        case .dictado: return "Dictado"
        case .estadisticas: return "Estadísticas"
        case .registros: return "Registros"
        case .ajustes: return "Ajustes"
        case .modelo: return "Modelo"
        case .ordenador: return "Ordenador"
        case .plugins: return "Plugins"
        case .tareas: return "Tareas"
        case .memoria: return "Memoria"
        case .telegram: return "Telegram"
        case .mac: return "Mac"
        case .secretos: return "Secretos"
        }
    }

    var icon: String {
        switch self {
        case .inicio: return "house"
        case .dictado: return "mic"
        case .estadisticas: return "chart.bar"
        case .registros: return "list.bullet.rectangle"
        case .ajustes: return "gearshape"
        case .modelo: return "square.stack.3d.up"
        case .ordenador: return "terminal"
        case .plugins: return "puzzlepiece.extension"
        case .tareas: return "clock"
        case .memoria: return "book.closed"
        case .telegram: return "paperplane"
        case .mac: return "laptopcomputer"
        case .secretos: return "key"
        }
    }

    /// Palabras extra para el buscador.
    var keywords: [String] {
        switch self {
        case .inicio: return ["estado", "detener", "reanudar", "iniciar sesión", "activo", "solicitudes"]
        case .dictado: return ["voz", "atajo", "opción", "whisper", "apple", "micrófono", "corregir", "transcripción"]
        case .estadisticas: return ["uso", "cifras", "palabras", "dictados", "gráfico", "actividad", "cuánto"]
        case .registros: return ["logs", "errores", "avisos", "fallos", "diagnóstico", "exportar", "historial"]
        case .ajustes: return ["tema", "apariencia", "oscuro", "claro", "idioma", "inglés", "español", "preferencias", "iniciar sesión", "reposo", "guía", "carpeta"]
        case .modelo: return ["cuenta", "ia", "claude", "openai", "openrouter", "grok", "ollama", "lm studio", "clave", "velocidad"]
        case .ordenador: return ["vm", "linux", "terminal", "escritorio", "máquina virtual"]
        case .plugins: return ["mcp", "servicios", "complementos", "github", "linear", "context7", "claude code", "servidor"]
        case .tareas: return ["programadas", "recordatorio", "cada día", "horario", "automatizar", "repetir"]
        case .memoria: return ["notas", "recordar", "olvidar"]
        case .telegram: return ["bot", "botfather", "token", "chats", "mensajes", "registro", "acceso total"]
        case .mac: return ["scripts", "volumen", "notificación", "recordatorio", "calendario", "enlace", "nota"]
        case .secretos: return ["claves", "llavero", "tokens", "contraseñas"]
        }
    }

    /// Lo que hay dentro de cada pantalla, con el nombre que se ve en ella. El buscador lo enseña
    /// como motivo de la coincidencia: «Ajustes › Idioma».
    var topics: [String] {
        switch self {
        case .inicio: return ["Solicitudes hoy", "Módulos"]
        case .dictado: return ["Atajo", "Qué hace lo que dices", "Responder en voz alta", "Transcripción",
                               "Corregir con IA", "Permisos de macOS"]
        case .modelo: return ["Cuenta activa", "Velocidad automática", "Añadir cuenta"]
        case .ordenador: return ["Tomar el control", "Escritorio", "Actividad del agente", "Se apaga sola", "Borrar la máquina"]
        case .plugins: return ["Servicios", "Complementos", "Añadir servidor", "Actividad"]
        case .tareas: return ["Nueva tarea", "Programadas", "Permisos", "Cómo funciona"]
        case .memoria: return ["Recordar cosas nuevas", "Añadir una nota", "Notas guardadas"]
        case .telegram: return ["Tu bot", "Tu cuenta", "Interruptores generales", "Acciones en tus chats", "Actividad"]
        case .mac: return ["Acciones del Mac", "Actividad"]
        case .secretos: return ["El agente te pide", "Guardados", "Cómo se protegen"]
        case .estadisticas: return ["Solicitudes a la IA", "Dictados", "Palabras dictadas", "Acciones del agente", "Exportar"]
        case .registros: return ["Errores", "Avisos", "Exportar", "Vaciar"]
        case .ajustes: return ["Apariencia", "Idioma", "Abrir al iniciar sesión", "Mantener el Mac activo",
                               "Guía de inicio", "Carpeta de datos", "Conservar la actividad", "Pausar el agente al bloquear el Mac", "Licencias", "Protección", "Revisar acciones tras leer contenido ajeno", "Detector de inyecciones",
                               "Restablecer permisos de macOS", "Borrar SaySo de este Mac"]
        }
    }

    /// Por qué una pantalla sale en una búsqueda.
    struct SearchHit: Identifiable, Equatable {
        var screen: SettingsScreen
        /// Ajuste concreto o palabra que ha coincidido, ya traducido; `nil` si coincide el nombre.
        var reason: String?
        /// Las coincidencias con el nombre van primero.
        var rank: Int
        var id: String { screen.rawValue }
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // Se busca en el idioma de la app y también en español, que es el del código.
        return text.range(of: query, options: options) != nil || tr(text).range(of: query, options: options) != nil
    }

    func hit(for query: String) -> SearchHit? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return SearchHit(screen: self, reason: nil, rank: 0) }
        if Self.contains(title, q) { return SearchHit(screen: self, reason: nil, rank: 0) }
        if let topic = topics.first(where: { Self.contains($0, q) }) {
            return SearchHit(screen: self, reason: tr(topic), rank: 1)
        }
        if let keyword = keywords.first(where: { Self.contains($0, q) }) {
            return SearchHit(screen: self, reason: tr(keyword), rank: 2)
        }
        if Self.contains(group.rawValue, q) { return SearchHit(screen: self, reason: tr(group.rawValue), rank: 3) }
        return nil
    }

    func matches(_ query: String) -> Bool { hit(for: query) != nil }

    /// Resultados de una búsqueda: primero las pantallas cuyo nombre coincide, luego por ajuste.
    static func search(_ query: String) -> [SearchHit] {
        allCases.compactMap { $0.hit(for: query) }
            .enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element)
    }
}

/// Ventana de ajustes: barra lateral fija y contenido desplazable.
public struct SettingsRootView: View {
    let model: AppModel
    @State private var selection: SettingsScreen = .inicio
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var showingPermissionGuide = false

    public init(model: AppModel) {
        self.model = model
        // Ayuda de desarrollo: SAYSO_SCREEN=<pantalla> abre la ventana en esa pantalla.
        if let raw = ProcessInfo.processInfo.environment["SAYSO_SCREEN"], let screen = SettingsScreen(rawValue: raw) {
            _selection = State(initialValue: screen)
        }
    }

    /// Abre directamente en una pantalla (previsualizaciones y pruebas).
    init(model: AppModel, initialScreen: SettingsScreen, query: String = "") {
        self.model = model
        _selection = State(initialValue: initialScreen)
        _query = State(initialValue: query)
    }

    public var body: some View {
        Group {
            if model.showOnboarding {
                OnboardingView(model: model, initialStep: Self.forcedOnboardingStep ?? .welcome)
            } else {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: Theme.sidebarWidth)
                        .background(Theme.surface)
                    Rectangle().fill(Theme.border).frame(width: 1)
                    content
                }
                // Al cambiar de idioma se vuelve a pintar todo; la pantalla elegida se conserva.
                .id(model.language)
            }
        }
        .background(Theme.paper)
        .frame(minWidth: 920, minHeight: 620)
        .sheet(isPresented: $showingPermissionGuide) { PermissionGuideSheet(model: model) }
        .appLanguage()
    }

    /// Ayuda de desarrollo: SAYSO_ONBOARDING=<número de paso> abre la guía en ese paso.
    static var forcedOnboardingStep: OnboardingStep? {
        ProcessInfo.processInfo.environment["SAYSO_ONBOARDING"].flatMap(Int.init).flatMap(OnboardingStep.init(rawValue:))
    }

    // MARK: Barra lateral

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func open(_ screen: SettingsScreen) {
        selection = screen
        query = ""
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchField(text: $query, focused: $searchFocused) {
                // Intro abre el primer resultado.
                if let first = SettingsScreen.search(query).first { open(first.screen) }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
            // ⌘F lleva al buscador desde cualquier pantalla.
            .background(
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if searching { results } else { groupedList }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.xs)
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            StatusCard(model: model)
                .padding(Theme.Space.m)
        }
    }

    @ViewBuilder
    private var groupedList: some View {
        ForEach([SettingsScreen.Group.none, .agente, .permisos, .sistema], id: \.self) { group in
            let items = SettingsScreen.allCases.filter { $0.group == group }
            if group != .none {
                SectionLabel(group.rawValue)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)
            }
            ForEach(items) { screen in
                SidebarItem(screen: screen, selected: screen == selection,
                            badge: model.sidebarBadge(for: screen)) {
                    selection = screen
                }
            }
        }
    }

    /// Lista plana de resultados, cada uno con el ajuste que ha coincidido.
    @ViewBuilder
    private var results: some View {
        let hits = SettingsScreen.search(query)
        HStack(alignment: .firstTextBaseline) {
            SectionLabel("Resultados")
            Spacer(minLength: 4)
            Text(verbatim: "\(hits.count)")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.secondary)
                .accessibilityLabel(tr("%@ resultados", "\(hits.count)"))
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.xs)
        if hits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Sin resultados"))
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text(tr("Prueba con otra palabra: por ejemplo «idioma», «token» o «micrófono»."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, Theme.Space.xs)
        }
        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
            SidebarItem(screen: hit.screen, selected: hit.screen == selection, badge: nil,
                        reason: hit.reason, primary: index == 0) {
                open(hit.screen)
            }
        }
        if !hits.isEmpty {
            Text(tr("Intro abre el primero · Esc borra"))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, Theme.Space.s)
                .padding(.top, Theme.Space.s)
                .accessibilityHidden(true)
        }
    }

    // MARK: Contenido

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let error = model.lastError {
                        ErrorBand(error)
                    }
                    dictationWarning
                    screenView(selection)
                }
                .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, Theme.Space.xxl)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity)
            }
            .id(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Pie fijo: la firma de la marca queda siempre a la vista, en todas las pantallas.
            Rectangle().fill(Theme.border).frame(height: 1)
            // A todo el ancho: el copyright pegado a la izquierda y la marca a la derecha.
            PepebitsSignature()
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
    }

    /// Con el dictado activado pero sin permisos, la tecla no hace nada y no hay forma de saberlo
    /// salvo que se diga: el aviso sale en todas las pantallas hasta que se arregle.
    @ViewBuilder
    private var dictationWarning: some View {
        let missing = model.missingDictationPermissions
        if !missing.isEmpty {
            let names = missing.map { tr($0.title) }.joined(separator: ", ")
            WarningBand(tr("El dictado no funciona: macOS no le ha dado a SaySo el permiso de %@.", names),
                        actionTitle: "Arreglar permisos") {
                showingPermissionGuide = true
            }
        }
    }

    @ViewBuilder
    private func screenView(_ screen: SettingsScreen) -> some View {
        switch screen {
        case .inicio: HomeScreen(model: model) { selection = $0 }
        case .dictado: DictationScreen(model: model)
        case .estadisticas: StatsScreen(model: model)
        case .registros: LogsScreen(model: model)
        case .ajustes: PreferencesScreen(model: model) { selection = $0 }
        case .modelo: ModelScreen(model: model)
        case .ordenador: ComputerScreen(model: model)
        case .plugins: PluginsScreen(model: model)
        case .tareas: TasksScreen(model: model)
        case .memoria: MemoryScreen(model: model)
        case .telegram: TelegramScreen(model: model)
        case .mac: MacScreen(model: model)
        case .secretos: SecretsScreen(model: model)
        }
    }
}

// MARK: - Piezas de la barra lateral

private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("Buscar ajustes")
                        .foregroundStyle(Theme.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .onSubmit(onSubmit)
                    .onExitCommand { text = "" }
            }
            .font(Theme.body)
            if text.isEmpty {
                // El atajo a la vista: se quita al escribir para dejar sitio al botón de borrar.
                Text(verbatim: "⌘F")
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 16)
                    .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius).strokeBorder(Theme.controlBorder, lineWidth: 1))
                    .accessibilityHidden(true)
            } else {
                Button { text = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Borrar búsqueda")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, text.isEmpty ? 7 : 3)
        .frame(height: 30)
        .background(Theme.paper)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(focused.wrappedValue ? Theme.ink : Theme.controlBorder, lineWidth: focused.wrappedValue ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityLabel("Buscar en ajustes")
        .accessibilityHint(tr("Atajo: Comando F. Intro abre el primer resultado."))
    }
}

private struct SidebarItem: View {
    let screen: SettingsScreen
    let selected: Bool
    /// Dato corto a la derecha: un atajo, un recuento o un estado.
    var badge: SidebarBadge?
    /// En una búsqueda: el ajuste que ha coincidido, debajo del nombre.
    var reason: String?
    /// En una búsqueda: es el que abre Intro.
    var primary = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(screen.icon, size: 20, inverted: selected)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr(screen.title))
                        .font(Theme.text(13, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    if let reason {
                        Text(verbatim: reason)
                            .font(Theme.text(11))
                            .foregroundStyle(selected ? Theme.paper.opacity(0.85) : Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                if let badge { badgeView(badge) }
                if primary {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? Theme.paper : Theme.secondary)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? Theme.paper : Theme.ink)
            .padding(.horizontal, 8)
            .frame(height: reason == nil ? 32 : 42)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(selected ? Theme.ink : (hovering ? Theme.border : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel([tr(screen.title), reason, badge?.spoken].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func badgeView(_ badge: SidebarBadge) -> some View {
        switch badge {
        case let .text(value, _):
            Text(verbatim: value)
                .font(Theme.mono(11, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(selected ? Theme.paper : Theme.secondary)
                .padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 16)
                .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius)
                    .strokeBorder(selected ? Theme.paper.opacity(0.5) : Theme.controlBorder, lineWidth: 1))
                .frame(maxWidth: 84, alignment: .trailing)
        case let .state(on, _):
            Bit(size: 8, active: on, tone: .running)
        }
    }
}

/// Dato a la derecha de una fila de la barra lateral.
enum SidebarBadge: Equatable {
    /// Texto corto (atajo, modelo, recuento) y cómo se lee con VoiceOver.
    case text(String, spoken: String)
    /// Cuadro de estado: verde relleno si está activo, contorno si no.
    case state(Bool, spoken: String)

    var spoken: String {
        switch self {
        case let .text(_, spoken), let .state(_, spoken): return spoken
        }
    }
}

extension AppModel {
    /// Lo que cada pantalla enseña a la derecha en la barra lateral; `nil` si no hay nada que decir.
    func sidebarBadge(for screen: SettingsScreen) -> SidebarBadge? {
        switch screen {
        case .inicio, .mac, .estadisticas, .ajustes:
            return nil
        case .registros:
            // Solo los errores de hoy: un aviso de que hay algo que mirar, no un recuento histórico.
            let errors = logEntries.filter { $0.level == .error && Calendar.current.isDateInToday($0.date) }.count
            return errors > 0 ? .text("\(errors)", spoken: tr("%@ errores hoy", "\(errors)")) : nil
        case .dictado:
            if !missingDictationPermissions.isEmpty { return .text("!", spoken: tr("faltan permisos")) }
            let spoken = dictation.shortcut.kind == .option ? tr("atajo Opción") : tr("atajo %@", dictation.shortcut.symbol)
            return dictation.enabled ? .text(dictation.shortcut.symbol, spoken: spoken) : nil
        case .modelo:
            guard let account = activeAccount else { return nil }
            return .text(account.name, spoken: account.name)
        case .ordenador:
            return computerState == .notInstalled ? nil
                : .state(computerState == .running, spoken: tr(computerState == .running ? "en marcha" : "apagado"))
        case .plugins:
            let count = plugins.filter { $0.added && $0.config.enabled }.count
            return count > 0 ? .text("\(count)", spoken: tr("%@ activos", "\(count)")) : nil
        case .tareas:
            let count = tasks.filter(\.enabled).count
            return count > 0 ? .text("\(count)", spoken: tr("%@ programadas", "\(count)")) : nil
        case .memoria:
            return notes.isEmpty ? nil : .text("\(notes.count)", spoken: tr("%@ notas", "\(notes.count)"))
        case .telegram:
            let connected: Bool
            if case .connected = telegramStatus { connected = true } else { connected = telegramUser.isReady }
            return .state(connected, spoken: tr(connected ? "conectado" : "sin conectar"))
        case .secretos:
            let pending = secrets.filter { $0.status == .requested }.count
            return pending > 0 ? .text("\(pending)", spoken: tr("%@ pendientes", "\(pending)")) : nil
        }
    }
}

/// Tarjeta inferior: estado del agente, Telegram y botón de parar / reanudar.
struct StatusCard: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Bit(size: 10, active: model.agentRunning, tone: .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(model.agentRunning ? "En marcha" : "Detenido"))
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text(tr(telegramLine))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SquareIconButton(model.agentRunning ? "stop.fill" : "play.fill",
                             label: model.agentRunning ? "Detener el agente" : "Reanudar el agente") {
                model.actions?.setAgentRunning(!model.agentRunning)
            }
        }
        .padding(Theme.Space.s + 2)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var telegramLine: String {
        let account = model.telegramUser.isReady
        switch model.telegramStatus {
        case .disconnected: return account ? "Cuenta conectada · falta el bot" : "Telegram sin conectar"
        case .connecting: return "Telegram conectando…"
        case .connected: return account ? "Bot y cuenta conectados" : "Telegram conectado"
        case .failed: return "Error de Telegram"
        }
    }
}
