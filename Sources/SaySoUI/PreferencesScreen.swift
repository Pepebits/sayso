import SaySoCore
import SwiftUI

/// Pantalla Ajustes: apariencia, idioma y cómo se comporta la app en el Mac.
struct PreferencesScreen: View {
    let model: AppModel
    var navigate: (SettingsScreen) -> Void = { _ in }
    @State private var showingLicenses = false
    @State private var showingErase = false
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(icon: "gearshape", title: "Ajustes",
                         subtitle: "Apariencia, idioma y cómo se comporta SaySo en tu Mac.",
                         tag: "v" + HomeScreen.version)

            appearancePanel
            languagePanel

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("En tu Mac")
                SettingsCard {
                    SettingRow(icon: "power", title: "Abrir al iniciar sesión",
                               detail: "Arranca con tu Mac y espera en segundo plano.") {
                        BlockToggle(isOn: Binding(get: { model.openAtLogin }, set: { model.actions?.setOpenAtLogin($0) }),
                                    label: "Abrir al iniciar sesión")
                    }
                    CardDivider()
                    SettingRow(icon: "lock", title: "Pausar el agente al bloquear el Mac",
                               detail: "Mientras el Mac está bloqueado no atiende a Telegram ni ejecuta tareas. Se reanuda al desbloquear.") {
                        BlockToggle(isOn: Binding(get: { model.pauseWhenLocked }, set: { model.actions?.setPauseWhenLocked($0) }),
                                    label: "Pausar el agente al bloquear el Mac")
                    }
                    CardDivider()
                    SettingRow(icon: "moon.zzz", title: "Mantener el Mac activo",
                               detail: "Evita el reposo para atender mensajes. La pantalla puede apagarse.") {
                        BlockToggle(isOn: Binding(get: { model.keepAwake }, set: { model.actions?.setKeepAwake($0) }),
                                    label: "Mantener el Mac activo")
                    }
                    CardDivider()
                    SettingRow(icon: "bell.badge", title: "Avisos en el Mac",
                               detail: "Los avisos de mensajes y de trabajos terminados. Al bot y a Registros llegan siempre.") {
                        BlockSegmented("Cómo avisar en el Mac",
                                       selection: Binding(get: { model.alertStyle }, set: { model.actions?.setAlertStyle($0) }),
                                       options: [(AlertStyle.sound, "Con sonido"), (.silent, "Sin sonido"), (.none, "No avisar")],
                                       compact: true)
                    }
                    CardDivider()
                    SettingRow(icon: "speaker.wave.2", title: "Leer los avisos en voz alta",
                               detail: "Los avisos de mensajes y de trabajos terminados, con la voz del Mac. Esperan si estás dictando o si SaySo está hablando.") {
                        BlockToggle(isOn: Binding(get: { model.speakAlerts }, set: { model.actions?.setSpeakAlerts($0) }),
                                    label: "Leer los avisos en voz alta")
                    }
                }
            }

            protectionSection

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Ayuda y datos")
                SettingsCard {
                    SettingRow(icon: "list.number", title: "Guía de inicio",
                               detail: "Repasa permisos, cuenta de IA, bot y ordenador paso a paso.") {
                        BlockButton("Abrir", compact: true) { model.actions?.showOnboarding() }
                            .accessibilityLabel("Abrir la guía de inicio")
                    }
                    CardDivider()
                    updatesRow
                    CardDivider()
                    SettingRow(icon: "ladybug", title: "Informe de errores",
                               detail: "Versión, estado, avisos y errores de la última semana y cierres inesperados, con nombres y números ocultos. Se guarda en un archivo que revisas antes de adjuntarlo a un issue.") {
                        HStack(spacing: Theme.Space.s) {
                            BlockButton("Crear informe", compact: true) { model.actions?.createDiagnostics() }
                            BlockButton("Abrir issues", compact: true) { model.actions?.openIssues() }
                                .accessibilityLabel("Abrir los issues de SaySo en GitHub")
                        }
                    }
                    CardDivider()
                    SettingRow(icon: "externaldrive", title: "Copia de seguridad",
                               detail: "Memoria, tareas, avisos, reglas, cuentas y ajustes en un archivo, para otro Mac o para guardarla. Sin claves ni conversaciones.") {
                        HStack(spacing: Theme.Space.s) {
                            BlockButton("Exportar", compact: true) { model.actions?.exportBackup() }
                            BlockButton("Importar", compact: true) { model.actions?.importBackup() }
                        }
                    }
                    CardDivider()
                    SettingRow(icon: "folder", title: "Carpeta de datos",
                               detail: "Base de datos, registro, modelos de voz y la máquina Linux.") {
                        BlockButton("Mostrar en Finder", compact: true) { model.actions?.revealDataFolder() }
                            .accessibilityLabel("Mostrar la carpeta de datos en el Finder")
                    }
                    if !model.dataFolder.isEmpty {
                        CardDivider(inset: Theme.Space.l)
                        Text(verbatim: model.dataFolder)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.s + 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(tr("Ruta de la carpeta de datos: %@", model.dataFolder))
                    }
                    CardDivider()
                    SettingRow(icon: "clock.arrow.circlepath", title: "Conservar la actividad",
                               detail: "Lo anterior se borra solo: el registro de actividad y las conversaciones con el agente.") {
                        BlockSegmented("Cuánto tiempo se conserva la actividad",
                                       selection: Binding(get: { model.retentionDays },
                                                          set: { model.actions?.setRetentionDays($0) }),
                                       options: [(30, "30 días"), (90, "90 días"), (365, "1 año"), (0, "Siempre")],
                                       compact: true)
                    }
                    CardDivider()
                    SettingRow(icon: "doc.text", title: "Licencias",
                               detail: "El software de terceros que incluye SaySo y sus licencias.") {
                        BlockButton("Ver", compact: true) { showingLicenses = true }
                            .accessibilityLabel("Ver las licencias")
                    }
                    CardDivider()
                    SettingRow(icon: "list.bullet.rectangle", title: "Registros",
                               detail: "Qué ha hecho la app y qué ha fallado, para exportarlo si hace falta.") {
                        BlockButton("Ver", compact: true) { navigate(.registros) }
                            .accessibilityLabel("Ver los registros")
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionBar("Restablecer y borrar")
                SettingsCard {
                    SettingRow(icon: "arrow.counterclockwise", title: "Restablecer permisos de macOS",
                               detail: "Borra lo que macOS tiene apuntado para SaySo y la reinicia para pedirlo de cero. Útil si un permiso se queda atascado.") {
                        BlockButton("Restablecer", kind: .destructive, compact: true) { confirmingReset = true }
                            .accessibilityLabel("Restablecer los permisos de macOS")
                    }
                    CardDivider()
                    SettingRow(icon: "trash", title: "Borrar SaySo de este Mac",
                               detail: "Datos, claves, máquina Linux, permisos y, si quieres, la propia app. No deja restos.") {
                        BlockButton("Borrar todo…", kind: .destructive, compact: true) { showingErase = true }
                            .accessibilityLabel("Borrar SaySo de este Mac")
                    }
                }
            }

        }
        .sheet(isPresented: $showingLicenses) { LicensesSheet(notices: ThirdPartyNotices.bundled()) }
        .sheet(isPresented: $showingErase) { EraseSheet(model: model) }
        .confirmationDialog(tr("¿Restablecer los permisos de macOS?"), isPresented: $confirmingReset) {
            Button(tr("Restablecer y reiniciar"), role: .destructive) { model.actions?.resetSystemPermissions() }
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(tr("SaySo perderá Micrófono, Accesibilidad y Supervisión de entrada, y se reiniciará para pedirlos de nuevo. Tus datos no se tocan."))
        }
    }

    // MARK: Apariencia

    private var appearancePanel: some View {
        Panel {
            PanelLabel("Apariencia")
            HStack(alignment: .top, spacing: Theme.Space.s) {
                appearanceOption(.system, "Como el sistema", "Cambia con el modo claro u oscuro de macOS.")
                appearanceOption(.light, "Claro", "Fondo claro siempre.")
                appearanceOption(.dark, "Oscuro", "Fondo oscuro siempre.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Apariencia")
        }
    }

    private func appearanceOption(_ choice: AppearanceChoice, _ title: String, _ detail: String) -> some View {
        OptionCard(title: title, detail: detail, selected: model.appearance == choice) {
            model.actions?.setAppearance(choice)
        }
    }

    // MARK: Idioma

    private struct LanguageOption: Identifiable {
        var choice: LanguageChoice
        var id: String { choice.rawValue }
    }

    private var languagePanel: some View {
        Panel {
            PanelLabel("Idioma")
            // Cada idioma se nombra en su propia lengua, se muestre la app en la que se muestre.
            TileGrid(LanguageChoice.allCases.map(LanguageOption.init), columns: 3, minTileWidth: 170, spacing: Theme.Space.s) { option in
                OptionCard(title: option.choice.nativeName ?? "Como el sistema",
                           detail: Self.languageDetail(option.choice),
                           selected: model.language == option.choice) {
                    model.actions?.setLanguage(option.choice)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Idioma")
        }
    }

    private static func languageDetail(_ choice: LanguageChoice) -> String {
        switch choice {
        case .system: return "El de tu Mac, si la app lo tiene."
        case .es: return "Castellano"
        case .gl: return "Galego"
        case .en: return "English (UK)"
        case .fr: return "Français (France)"
        case .pt: return "Português (Portugal)"
        }
    }

    // MARK: Protección

    private var localStatus: (text: String, kind: StatusTag.Kind) {
        switch model.localDetector {
        case .notInstalled: return (tr("Sin instalar"), .neutral)
        case .installing: return (tr("Instalando…"), .connecting)
        case .installed: return (tr("Instalado"), .active)
        case .failed: return (tr("Falló"), .error)
        }
    }

    private var updatesDetail: String {
        switch model.updates {
        case .unavailable:
            return tr("Versión %@. Esta compilación no se actualiza sola.", model.appVersion)
        case .ready(_, let lastCheck?):
            return tr("Versión %@. Última comprobación: %@.", model.appVersion, RelativeDate.string(lastCheck))
        case .ready(_, nil):
            return tr("Versión %@. Las versiones nuevas se descargan de GitHub, firmadas por Pepebits.", model.appVersion)
        }
    }

    @ViewBuilder private var updatesRow: some View {
        SettingRow(icon: "arrow.down.app", title: "Actualizaciones", detail: updatesDetail) {
            if case .ready = model.updates {
                BlockButton("Buscar ahora", compact: true) { model.actions?.checkForUpdates() }
                    .accessibilityLabel("Buscar actualizaciones ahora")
            }
        }
        if case .ready(let automatic, _) = model.updates {
            CardDivider(inset: Theme.Space.l)
            SettingRow(title: "Buscar actualizaciones automáticamente",
                       detail: "Una vez al día. Antes de instalar una versión nueva, SaySo te pregunta.") {
                BlockToggle(isOn: Binding(get: { automatic }, set: { model.actions?.setAutomaticUpdates($0) }),
                            label: "Buscar actualizaciones automáticamente")
            }
        }
    }

    private var protectionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionBar("Protección", note: tr("frente a instrucciones coladas en webs y mensajes"))
            SettingsCard {
                SettingRow(icon: "checkmark.shield", title: "Revisar acciones tras leer contenido ajeno",
                           detail: "Si el agente ha leído una web o mensajes de otros y luego quiere enviar, borrar o abrir algo, el modelo rápido comprueba que lo pediste tú. Si no cuadra, te lo pregunta en el Mac.") {
                    BlockToggle(isOn: Binding(get: { model.guardReview }, set: { model.actions?.setGuardReview($0) }),
                                label: "Revisar acciones tras leer contenido ajeno")
                }
                CardDivider()
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SettingRow(icon: "eye.trianglebadge.exclamationmark", title: "Detector de inyecciones",
                               detail: "Lee lo que traen las webs y los mensajes de otros buscando órdenes para el agente. Si las encuentra, se lo advierte y cualquier acción de ese turno se pregunta.") {
                        EmptyView()
                    }
                    BlockSegmented("Detector de inyecciones",
                                   selection: Binding(get: { model.guardDetector }, set: { model.actions?.setGuardDetector($0) }),
                                   options: [(GuardSettings.Detector.off, "Desactivado"), (.fast, "Modelo rápido"),
                                             (.local, "Local")],
                                   compact: true)
                        .fixedSize()
                        .padding(.leading, Theme.Space.m)
                    Text(tr(detectorDetail))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Space.m)
                    if model.guardDetector == .local { localDetectorPanel }
                }
                .padding(.bottom, Theme.Space.m)
            }
        }
    }

    private var detectorDetail: String {
        switch model.guardDetector {
        case .off: return "Sin detector. Las acciones tras leer contenido ajeno se siguen revisando si lo de arriba está activado."
        case .fast: return "Usa el modelo rápido de tu cuenta: no ocupa nada, añade un segundo por cada web o lista de mensajes que lea el agente."
        case .local: return "Un clasificador dentro de la máquina Linux: no envía nada a ningún sitio. Elige uno de la lista; mientras no esté instalado se usa el modelo rápido."
        }
    }

    private var localDetectorPanel: some View {
        LocalModelPicker(model: model, localStatus: localStatus, navigate: navigate)
            .padding(.horizontal, Theme.Space.m)
    }
}

/// Lista de clasificadores locales con lo que pide cada uno, más un campo para cualquier otro.
private struct LocalModelPicker: View {
    let model: AppModel
    let localStatus: (text: String, kind: StatusTag.Kind)
    var navigate: (SettingsScreen) -> Void = { _ in }
    @State private var customRepo = ""
    /// La lista de modelos, desplegada. Sin valor: plegada si ya hay uno instalado.
    @State private var expanded: Bool?
    @Environment(\.openURL) private var openURL

    private var isExpanded: Bool { expanded ?? (model.localDetector != .installed) }

    static func page(_ repo: String) -> URL { URL(string: "https://huggingface.co/\(repo)")! }
    static let tokens = URL(string: "https://huggingface.co/settings/tokens")!

    /// Si ya está guardado HF_TOKEN en Secretos.
    private var hasToken: Bool {
        model.secrets.contains { $0.name == "HF_TOKEN" && $0.status == .stored }
    }

    private var selected: LocalGuardModel { LocalGuardModel.model(repo: model.localModel) }
    private var isCustom: Bool { !LocalGuardModel.catalog.contains { $0.repo == model.localModel } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(tr("Modelo")).font(Theme.text(12, weight: .semibold)).foregroundStyle(Theme.ink)
                if !isExpanded {
                    Text(verbatim: selected.name).font(Theme.bodyStrong).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(verbatim: summary(selected)).font(Theme.mono(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                BlockButton(isExpanded ? "Ocultar" : "Cambiar", systemImage: isExpanded ? "chevron.up" : "chevron.down",
                            compact: true) {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded = !isExpanded }
                }
                .accessibilityLabel(isExpanded ? tr("Ocultar la lista de modelos") : tr("Mostrar la lista de modelos"))
            }
            if isExpanded {
                VStack(spacing: Theme.Space.s) {
                    ForEach(LocalGuardModel.catalog) { candidate in card(candidate) }
                    customCard
                }
            }
            HStack(spacing: Theme.Space.s) {
                StatusTag(localStatus.text, kind: localStatus.kind)
                Text(verbatim: selected.repo).font(Theme.mono(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if model.localDetector != .installed {
                    BlockButton(model.localDetector == .installing ? "Instalando…" : "Instalar",
                                systemImage: "arrow.down.circle", kind: .primary, compact: true) {
                        model.actions?.installLocalDetector()
                    }
                    .disabled(model.localDetector == .installing)
                }
            }
            if case let .failed(reason) = model.localDetector {
                Text(verbatim: reason)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.localDetector != .installed {
                if selected.needsToken { tokenSteps } else {
                    Text(tr("No necesita cuenta. Necesita la máquina Linux instalada; la primera vez también se descargan Python y PyTorch (unos cientos de MB más)."))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// «1,1 GB · Multilingüe»: lo que se ve con la lista plegada.
    private func summary(_ m: LocalGuardModel) -> String {
        var parts: [String] = []
        if let size = m.sizeMB { parts.append(size >= 1000 ? String(format: "%.1f GB", Double(size) / 1000) : "\(size) MB") }
        parts.append(tr(m.languages))
        return parts.joined(separator: " · ")
    }

    /// Los tres pasos de un modelo de acceso restringido, cada uno con su botón.
    private var tokenSteps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(tr("Este modelo es de acceso restringido. Antes de instalarlo, con tu cuenta de Hugging Face:"))
                .font(Theme.caption).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            step("1", tr("Acepta la licencia en la página del modelo."), button: "Abrir la página del modelo",
                 icon: "arrow.up.right.square") { openURL(Self.page(selected.repo)) }
            step("2", tr("Crea un token de lectura («Read»). Es gratuito y solo sirve para que Hugging Face sepa que aceptaste."),
                 button: "Crear un token", icon: "key") { openURL(Self.tokens) }
            step("3", hasToken ? tr("HF_TOKEN ya está guardado en Secretos.") : tr("Guárdalo en Secretos con el nombre HF_TOKEN."),
                 button: hasToken ? nil : "Ir a Secretos", icon: "lock") { navigate(.secretos) }
        }
    }

    private func step(_ number: String, _ text: String, button: String?, icon: String,
                      action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Text(verbatim: number)
                .font(Theme.mono(11, weight: .bold))
                .foregroundStyle(Theme.paper)
                .frame(width: 18, height: 18)
                .background(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(Theme.caption).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let button {
                BlockButton(button, systemImage: icon, compact: true, action: action)
            } else {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.running)
                    .accessibilityLabel(tr("Hecho"))
            }
        }
    }

    private func card(_ candidate: LocalGuardModel) -> some View {
        let isSelected = candidate.repo == model.localModel
        return Button { model.actions?.setLocalModel(candidate.repo) } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.s) {
                        Text(verbatim: candidate.name).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                        if candidate == LocalGuardModel.recommended { MonoTag(text: tr("recomendado")) }
                        Spacer(minLength: 0)
                        if let size = candidate.sizeMB {
                            Text(verbatim: size >= 1000 ? String(format: "%.1f GB", Double(size) / 1000) : "\(size) MB")
                                .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                        }
                    }
                    Text(verbatim: "\(tr(candidate.languages)) · \(tr(candidate.license)) · " + tr(candidate.needsToken ? "pide cuenta y HF_TOKEN" : "libre, sin cuenta"))
                        .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(tr(candidate.note))
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { openURL(Self.page(candidate.repo)) } label: {
                        Label(tr("Ver en Hugging Face"), systemImage: "arrow.up.right.square")
                            .font(Theme.text(12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help(Self.page(candidate.repo).absoluteString)
                }
            }
            .padding(Theme.Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(isSelected ? Theme.ink : Theme.border, lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var customCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: isCustom ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
                Text(tr("Otro modelo de Hugging Face")).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            HStack(spacing: Theme.Space.s) {
                BlockField("organización/nombre", text: $customRepo, mono: true, label: "Repositorio de Hugging Face")
                    .onSubmit(useCustom)
                BlockButton("Usar", compact: true, action: useCustom)
                    .disabled(!LocalGuardModel.isValidRepo(customRepo.trimmingCharacters(in: .whitespaces)))
            }
            Text(tr("Tiene que ser un modelo de clasificación de texto para inyecciones (transformers). Si es de acceso restringido, acepta su licencia y guarda HF_TOKEN. Antes de instalarlo, mira su ficha: tamaño, idiomas y licencia."))
                .font(Theme.caption).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                BlockButton("Buscar clasificadores en Hugging Face", systemImage: "magnifyingglass", compact: true) {
                    openURL(URL(string: "https://huggingface.co/models?pipeline_tag=text-classification&search=prompt+injection")!)
                }
                if LocalGuardModel.isValidRepo(customRepo.trimmingCharacters(in: .whitespaces)) {
                    BlockButton("Ver su ficha", systemImage: "arrow.up.right.square", compact: true) {
                        openURL(Self.page(customRepo.trimmingCharacters(in: .whitespaces)))
                    }
                }
            }
        }
        .padding(Theme.Space.s + 2)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius)
            .strokeBorder(isCustom ? Theme.ink : Theme.border, lineWidth: isCustom ? 2 : 1))
        .onAppear { if isCustom { customRepo = model.localModel } }
    }

    private func useCustom() {
        let repo = customRepo.trimmingCharacters(in: .whitespaces)
        guard LocalGuardModel.isValidRepo(repo) else { return }
        model.actions?.setLocalModel(repo)
    }
}
