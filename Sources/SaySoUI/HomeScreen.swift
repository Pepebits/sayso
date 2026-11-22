import SaySoCore
import SwiftUI

/// Icono de la app: comillas de bloques hueso y bit rojo sobre campo tinta
/// (rejilla de 120, ver `assets/brand/sayso-icon.svg`).
public struct AppIconView: View {
    var size: CGFloat

    public init(size: CGFloat = 56) { self.size = size }

    /// Rectángulos hueso: x, y, ancho, alto.
    private static let blocks: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (26, 30, 18, 32), (26, 62, 9, 16),
        (50, 30, 18, 32), (50, 62, 9, 16),
    ]

    public var body: some View {
        let s = size / 120
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.fixedInk)
            ForEach(0..<Self.blocks.count, id: \.self) { i in
                let b = Self.blocks[i]
                Rectangle()
                    .fill(Theme.fixedBone)
                    .frame(width: b.2 * s, height: b.3 * s)
                    .offset(x: b.0 * s, y: b.1 * s)
            }
            Rectangle()
                .fill(Theme.red)
                .frame(width: 20 * s, height: 20 * s)
                .offset(x: 74 * s, y: 70 * s)
        }
        .frame(width: size, height: size)
        // Borde solo visible en oscuro, donde el campo tinta se funde con el fondo.
        .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Pantalla Inicio: cabecera con el estado del agente y una rejilla de módulos, cada uno con su
/// estado y su atajo a la pantalla donde se configura.
struct HomeScreen: View {
    let model: AppModel
    let navigate: (SettingsScreen) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m, alignment: .top), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            hero

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Módulos")
                    Spacer()
                    Text(verbatim: modulesSummary)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(modules) { module in ModuleCard(module: module) { navigate(module.screen) } }
                }
            }

        }
    }

    // MARK: Cabecera

    private var hero: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                AppIconView(size: 60)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Theme.Space.s) {
                        Text(verbatim: "SaySo")
                            .font(Theme.display(26))
                            .tracking(-0.8)
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        StatusTag(model.agentRunning ? "En marcha" : "Detenido",
                                  kind: model.agentRunning ? .active : .neutral)
                        MonoTag(text: "v" + Self.version)
                    }
                    Text(tr("Agente para tu Mac · Dictado y asistente por Telegram"))
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Theme.Space.s) {
                        Text(tr("Motor activo:"))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                        MonoTag(text: model.activeAccount.map { $0.fullModel.isEmpty ? $0.name : $0.fullModel } ?? tr("Sin configurar"),
                                marked: model.activeAccount != nil)
                        Button(tr(model.activeAccount == nil ? "Añadir" : "Cambiar")) { navigate(.modelo) }
                            .buttonStyle(LinkTextStyle())
                            .accessibilityLabel(tr("Cambiar el modelo"))
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: Theme.Space.m) {
                    BlockButton(model.agentRunning ? "Detener" : "Reanudar",
                                systemImage: model.agentRunning ? "stop.fill" : "play.fill",
                                kind: model.agentRunning ? .secondary : .primary) {
                        model.actions?.setAgentRunning(!model.agentRunning)
                    }
                    RequestsMeter(today: model.requestsToday, week: model.requestsWeek)
                }
            }
            .padding(Theme.Space.l)
            CardDivider()
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "lock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
                Text(tr("El agente trabaja aislado de tus archivos. Las claves se quedan en el Llavero de este Mac."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.s)
                MonoTag(text: tr(model.computerState == .notInstalled ? "Linux: sin instalar" : "Linux: aislado"))
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s + 2)
        }
    }

    static let version = Bundle.main.bundleIdentifier?.hasPrefix("com.pepebits.sayso") == true
        ? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0") : "0.3.0"

    // MARK: Módulos

    private var modulesSummary: String {
        let ready = modules.filter(\.ok).count
        // Plugins y tareas son extras: sin ellos el agente funciona igual.
        let pending = modules.filter { !$0.ok && !$0.optional }.count
        return pending == 0 ? tr("%@ listos", "\(ready)") : tr("%@ listos / %@ por configurar", "\(ready)", "\(pending)")
    }

    private var modules: [HomeModule] {
        let botConnected: Bool
        if case .connected = model.telegramStatus { botConnected = true } else { botConnected = false }
        let activePlugins = model.plugins.filter { $0.added && $0.config.enabled }
        let activeTasks = model.tasks.filter(\.enabled)
        let voice = tr("Habla con el agente")
        return [
            HomeModule(screen: .telegram, icon: "paperplane", title: "Telegram",
                       subtitle: model.telegramSummary, badge: model.telegramUser.isReady ? tr("bot + cuenta") : tr("bot"),
                       status: botConnected ? "Conectado" : "Falta el bot", ok: botConnected, link: "Configurar"),
            HomeModule(screen: .modelo, icon: "square.stack.3d.up", title: "Cuenta de IA",
                       subtitle: model.activeAccount?.name ?? tr("Sin configurar"),
                       badge: model.autoSpeed ? tr("auto") : tr("completo"),
                       status: model.activeAccount == nil ? "Falta una cuenta" : "Clave guardada",
                       ok: model.activeAccount != nil, link: "Ajustar"),
            HomeModule(screen: .dictado, icon: "mic", title: "Voz",
                       subtitle: voice, badge: model.dictation.shortcut.symbol,
                       status: !model.missingDictationPermissions.isEmpty ? "Faltan permisos"
                           : (model.dictation.enabled ? "Activa" : "Desactivada"),
                       ok: model.dictation.enabled && model.missingDictationPermissions.isEmpty, link: "Ajustar"),
            HomeModule(screen: .ordenador, icon: "terminal", title: "Ordenador",
                       subtitle: tr("Linux del agente"), badge: "Debian 13",
                       status: computerStatus, ok: model.computerState != .notInstalled, link: "Abrir"),
            HomeModule(screen: .plugins, icon: "puzzlepiece.extension", title: "Plugins",
                       subtitle: activePlugins.isEmpty ? tr("Ninguno añadido")
                           : activePlugins.prefix(3).map { tr($0.config.name) }.joined(separator: ", "),
                       badge: tr("%@ activos", "\(activePlugins.count)"),
                       status: activePlugins.isEmpty ? "Opcional" : "Disponibles", ok: !activePlugins.isEmpty,
                       link: "Gestionar", optional: true),
            HomeModule(screen: .tareas, icon: "clock", title: "Tareas",
                       subtitle: activeTasks.first.map { $0.schedule.summary() } ?? tr("Nada programado"),
                       badge: "\(activeTasks.count)",
                       status: activeTasks.isEmpty ? "Opcional" : "Programadas", ok: !activeTasks.isEmpty,
                       link: "Ver", optional: true),
        ]
    }

    private var computerStatus: String {
        switch model.computerState {
        case .notInstalled: return "Sin instalar"
        case .preparing: return "Instalando"
        case .starting: return "Arrancando"
        case .running: return "En marcha"
        case .paused: return "En pausa"
        case .stopped: return "En reposo"
        case .failed: return "Error"
        }
    }
}

/// Un módulo de Inicio.
struct HomeModule: Identifiable {
    var id: SettingsScreen { screen }
    var screen: SettingsScreen
    var icon: String
    var title: String
    var subtitle: String
    var badge: String
    var status: String
    /// Listo para usarse (cuadro relleno) o por configurar (contorno).
    var ok: Bool
    var link: String
    /// Un extra: vacío no cuenta como «por configurar».
    var optional = false
}

/// Tarjeta de módulo: icono y dato arriba, nombre y detalle, y abajo el estado con su enlace.
struct ModuleCard: View {
    let module: HomeModule
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(alignment: .top) {
                        IconTile(module.icon, size: 28)
                        Spacer(minLength: Theme.Space.s)
                        MonoTag(text: module.badge)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr(module.title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                        Text(verbatim: module.subtitle)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(Theme.Space.m + 2)
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 6) {
                    Bit(size: 7, active: module.ok, tone: .running)
                    Text(tr(module.status))
                        .font(Theme.text(11.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: tr(module.link) + " ›")
                        .font(Theme.text(11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .underline(hovering)
                }
                .padding(.horizontal, Theme.Space.m + 2)
                .padding(.vertical, Theme.Space.s + 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(hovering ? Theme.controlBorder : Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(tr(module.title)): \(module.subtitle). \(tr(module.status))"))
        .accessibilityHint(tr("Abre la pantalla %@", tr(module.title)))
        .accessibilityAddTraits(.isButton)
    }
}

/// Etiqueta pequeña en monoespaciada para datos (versión, modelo, recuentos).
struct MonoTag: View {
    var text: String
    /// Lleva delante un cuadro de tinta, para destacar un valor elegido.
    var marked = false

    var body: some View {
        HStack(spacing: 5) {
            if marked { Rectangle().fill(Theme.ink).frame(width: 6, height: 6).accessibilityHidden(true) }
            Text(verbatim: text)
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius))
    }
}

/// Solicitudes de hoy con las barras de los últimos siete días.
struct RequestsMeter: View {
    var today: Int
    /// Del día más antiguo al de hoy.
    var week: [Int]

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Solicitudes hoy").uppercased())
                    .font(Theme.text(11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondary)
                Text(verbatim: "\(today)")
                    .font(Theme.mono(17, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }
            if week.count > 1 {
                Rectangle().fill(Theme.border).frame(width: 1, height: 26)
                HStack(alignment: .bottom, spacing: 3) {
                    let top = max(week.max() ?? 1, 1)
                    ForEach(Array(week.enumerated()), id: \.offset) { index, value in
                        Rectangle()
                            .fill(index == week.count - 1 ? Theme.ink : Theme.controlBorder)
                            .frame(width: 4, height: max(2, 22 * CGFloat(value) / CGFloat(top)))
                    }
                }
                .frame(height: 22, alignment: .bottom)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Solicitudes de hoy: %@", "\(today)"))
    }
}

/// Enlace de texto subrayado, para acciones secundarias dentro de una línea.
struct LinkTextStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.text(11.5, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .underline()
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
