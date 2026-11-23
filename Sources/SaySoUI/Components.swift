import SaySoCore
import SwiftUI

// Componentes reutilizables con la identidad Pepebits.

// MARK: - Bit

/// El «bit»: cuadrado de esquinas rectas. Rojo como acento de marca (grabando, atención);
/// verde cuando indica que algo está en marcha. Inactivo es un contorno, no un color.
public struct Bit: View {
    public enum Tone { case accent, running }

    var size: CGFloat
    var active: Bool
    var tone: Tone

    public init(size: CGFloat = 9, active: Bool = true, tone: Tone = .accent) {
        self.size = size
        self.active = active
        self.tone = tone
    }

    public var body: some View {
        Group {
            if active {
                Rectangle().fill(tone == .running ? Theme.running : Theme.red)
            } else {
                Rectangle().strokeBorder(Theme.tertiary, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - IconTile

/// Glifo SF Symbols relleno en hueso dentro de un cuadrado de tinta.
public struct IconTile: View {
    var systemName: String
    var size: CGFloat
    /// Invierte colores (p. ej. sobre la fila seleccionada).
    var inverted: Bool

    public init(_ systemName: String, size: CGFloat = 26, inverted: Bool = false) {
        self.systemName = systemName
        self.size = size
        self.inverted = inverted
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: min(Theme.radius, size * 0.14))
            .fill(inverted ? Theme.paper : Theme.ink)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .symbolVariant(.fill)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(inverted ? Theme.ink : Theme.paper)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - StatusTag

/// Etiqueta de estado puntual.
public struct StatusTag: View {
    public enum Kind { case active, pending, connecting, neutral, error }

    var text: String
    var kind: Kind

    public init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        HStack(spacing: 5) {
            if kind == .active { Bit(size: 8, tone: .running) }
            Text(tr(text).uppercased())
                .font(Theme.text(11, weight: .bold))
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous).strokeBorder(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr(text))
    }

    private var foreground: Color {
        switch kind {
        case .active: return Theme.ink
        case .pending, .connecting: return Theme.fixedInk
        case .neutral: return Theme.secondary
        case .error: return Theme.destructive
        }
    }

    private var background: Color {
        switch kind {
        case .pending: return Theme.yellow
        case .connecting: return Theme.turquoise
        case .active, .neutral, .error: return .clear
        }
    }

    private var borderColor: Color {
        switch kind {
        case .active: return Theme.ink
        case .pending, .connecting: return .clear
        case .neutral: return Theme.controlBorder
        case .error: return Theme.destructive
        }
    }
}

// MARK: - BlockToggle

/// Interruptor rectangular con mando cuadrado.
public struct BlockToggle: View {
    @Binding var isOn: Bool
    var label: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isOn: Binding<Bool>, label: String) {
        _isOn = isOn
        self.label = label
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: Theme.innerRadius)
                    .fill(isOn ? Theme.ink : Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.innerRadius)
                            .strokeBorder(isOn ? Theme.ink : Theme.controlBorder, lineWidth: 1)
                    )
                // Interruptor geométrico: pista rectangular y mando cuadrado.
                RoundedRectangle(cornerRadius: Theme.innerRadius)
                    .fill(isOn ? Theme.paper : Theme.secondary)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
            .frame(width: 42, height: 22)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(tr(label))
        .accessibilityValue(isOn ? tr("Activado") : tr("Desactivado"))
        .accessibilityAddTraits(.isToggle)
        .help(tr(label))
    }
}

// MARK: - BlockSegmented

/// Control segmentado: el segmento activo es un bloque de tinta con texto hueso.
public struct BlockSegmented<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    var label: String
    var compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(_ label: String, selection: Binding<Value>, options: [(value: Value, title: String)], compact: Bool = false) {
        self.label = label
        _selection = selection
        self.options = options
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(tr(option.title))
                        .font(Theme.text(compact ? 11.5 : 12.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, compact ? 10 : 14)
                        .frame(minHeight: compact ? 24 : 28)
                        .frame(maxWidth: compact ? nil : .infinity)
                        .foregroundStyle(selected ? Theme.paper : Theme.ink)
                        // Selector en forma de pastilla: es la única pieza redondeada del sistema.
                        .background(Capsule().fill(selected ? Theme.ink : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(option.title))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Theme.paper)
        .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1))
        .clipShape(Capsule())
        .fixedSize(horizontal: compact, vertical: true)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr(label))
    }
}

// MARK: - Botones

public enum BlockButtonKind { case primary, secondary, destructive }

public struct BlockButtonStyle: ButtonStyle {
    var kind: BlockButtonKind
    var compact: Bool

    public init(_ kind: BlockButtonKind = .secondary, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, kind: kind, compact: compact)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let kind: BlockButtonKind
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.text(compact ? 12 : 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, compact ? 11 : 16)
                .frame(minHeight: compact ? 26 : 32)
                .foregroundStyle(foreground)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(kind == .primary ? Color.clear : (kind == .destructive ? Theme.destructive : Theme.controlBorder), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Rectangle())
        }

        private var foreground: Color {
            switch kind {
            case .primary: return Theme.paper
            case .secondary: return Theme.ink
            case .destructive: return Theme.destructive
            }
        }

        private var background: Color {
            switch kind {
            case .primary: return Theme.ink
            case .secondary, .destructive: return configuration.isPressed ? Theme.border : Theme.paper
            }
        }
    }
}

/// Botón de bloque con título y glifo opcional.
public struct BlockButton: View {
    var title: String
    var systemImage: String?
    var kind: BlockButtonKind
    var compact: Bool
    var action: () -> Void

    public init(_ title: String, systemImage: String? = nil, kind: BlockButtonKind = .secondary,
                compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.compact = compact
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: compact ? 10 : 11, weight: .bold))
                }
                Text(tr(title))
            }
        }
        .buttonStyle(BlockButtonStyle(kind, compact: compact))
    }
}

/// Botón cuadrado solo con glifo (parar / reanudar).
public struct SquareIconButton: View {
    var systemName: String
    var label: String
    var size: CGFloat
    var action: () -> Void

    public init(_ systemName: String, label: String, size: CGFloat = 28, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: size, height: size)
                .background(Theme.paper)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.controlBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr(label))
        .help(tr(label))
    }
}

// MARK: - BlockProgress

/// Barra de progreso recta. `value` entre 0 y 1.
public struct BlockProgress: View {
    var value: Double
    var label: String
    var tint: Color

    public init(value: Double, label: String = "Progreso", tint: Color = Theme.ink) {
        self.value = value
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.controlBorder.opacity(0.45))
                Rectangle().fill(tint)
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(tr(label))
        .accessibilityValue(Text(verbatim: "\(Int((min(max(value, 0), 1)) * 100)) %"))
    }
}

// MARK: - Tarjetas y filas

/// Contenedor de filas: superficie con borde de 1 px.
public struct SettingsCard<Content: View>: View {
    var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Separador entre filas de una tarjeta.
public struct CardDivider: View {
    var inset: CGFloat
    public init(inset: CGFloat = 0) { self.inset = inset }
    public var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, inset)
    }
}

/// Sección con rótulo en mayúsculas sobre una tarjeta.
public struct SettingsSection<Content: View>: View {
    var title: String
    var footer: String?
    var content: Content

    public init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(title)
            content
            if let footer {
                Text(tr(footer))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

public struct SectionLabel: View {
    var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(tr(text).uppercased())
            .font(Theme.sectionLabel)
            .tracking(0.8)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Fila de ajuste: icono, título, descripción y control a la derecha.
public struct SettingRow<Trailing: View>: View {
    var icon: String?
    var title: String
    var detail: String?
    var mono: Bool
    var trailing: Trailing

    public init(icon: String? = nil, title: String, detail: String? = nil, mono: Bool = false,
                @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.mono = mono
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            if let icon { IconTile(icon) }
            VStack(alignment: .leading, spacing: 2) {
                Text(mono ? title : tr(title))
                    .font(mono ? Theme.mono(12.5, weight: .semibold) : Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let detail, !detail.isEmpty {
                    Text(tr(detail))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(minHeight: 54)
        .accessibilityElement(children: .contain)
    }
}

public extension SettingRow where Trailing == EmptyView {
    init(icon: String? = nil, title: String, detail: String? = nil, mono: Bool = false) {
        self.init(icon: icon, title: title, detail: detail, mono: mono) { EmptyView() }
    }
}

/// Fila que lleva a otra pantalla: valor a la derecha y cheurón.
public struct NavigationRow: View {
    var icon: String
    var title: String
    var value: String
    var mono: Bool
    var action: () -> Void

    public init(icon: String, title: String, value: String, mono: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.value = value
        self.mono = mono
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                IconTile(icon)
                Text(tr(title))
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.m)
                Text(mono ? value : tr(value))
                    .font(mono ? Theme.mono(12.5) : Theme.body)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(tr(title)): \(tr(value))"))
        .accessibilityHint(tr("Abre la pantalla %@", tr(title)))
    }
}

// MARK: - Cabecera de pantalla

public struct ScreenHeader<Trailing: View>: View {
    var icon: String
    var title: String
    var subtitle: String
    /// Dato corto junto al título, ya traducido (recuentos, motor en uso).
    var tag: String?
    var trailing: Trailing

    public init(icon: String, title: String, subtitle: String, tag: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tag = tag
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                IconTile(icon, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: Theme.Space.s) {
                        Text(tr(title))
                            .font(Theme.display(26))
                            .tracking(-0.8)
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        if let tag { MonoTag(text: tag) }
                    }
                    Text(tr(subtitle))
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            CardDivider()
        }
    }
}

public extension ScreenHeader where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String, tag: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle, tag: tag) { EmptyView() }
    }
}

// MARK: - Campos de texto

/// Campo de texto con borde de 1 px; el borde pasa a tinta con el foco.
public struct BlockField: View {
    var placeholder: String
    @Binding var text: String
    var secure: Bool
    var mono: Bool
    var label: String
    @FocusState private var focused: Bool

    public init(_ placeholder: String, text: Binding<String>, secure: Bool = false, mono: Bool = false, label: String? = nil) {
        self.placeholder = placeholder
        _text = text
        self.secure = secure
        self.mono = mono
        self.label = label ?? placeholder
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            // macOS pinta su texto de ejemplo en un gris por debajo de 4,5:1 y no deja cambiarlo:
            // se dibuja aparte, con el terciario, y desaparece al escribir.
            if text.isEmpty {
                Text(tr(placeholder))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if secure {
                SecureField("", text: $text)
            } else {
                TextField("", text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? Theme.mono(12.5) : Theme.body)
        .foregroundStyle(Theme.ink)
        .focused($focused)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(Theme.paper)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(focused ? Theme.ink : Theme.controlBorder, lineWidth: focused ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityLabel(tr(label))
    }
}

/// Campo con rótulo encima.
public struct LabeledField: View {
    var title: String
    var placeholder: String
    @Binding var text: String
    var secure: Bool
    var mono: Bool
    var hint: String?

    public init(_ title: String, placeholder: String = "", text: Binding<String>, secure: Bool = false,
                mono: Bool = false, hint: String? = nil) {
        self.title = title
        self.placeholder = placeholder
        _text = text
        self.secure = secure
        self.mono = mono
        self.hint = hint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(tr(title))
                .font(Theme.text(12, weight: .semibold))
                .foregroundStyle(Theme.ink)
            BlockField(placeholder, text: $text, secure: secure, mono: mono, label: title)
            if let hint {
                Text(tr(hint))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Notas y avisos

/// Aviso de algo que no funciona hasta que el usuario haga algo: barra amarilla, etiqueta
/// «Atención» y, si procede, un botón que lleva a arreglarlo.
public struct WarningBand: View {
    var message: String
    var actionTitle: String?
    var action: () -> Void

    /// `message` ya traducido.
    public init(_ message: String, actionTitle: String? = nil, action: @escaping () -> Void = {}) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            StatusTag("Atención", kind: .pending)
            Text(verbatim: message)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                BlockButton(actionTitle, kind: .primary, compact: true, action: action)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.yellow).frame(width: 4) }
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Nota en línea con un glifo a la izquierda.
public struct InlineNote: View {
    var systemImage: String
    var text: String
    var emphasis: Bool

    public init(_ text: String, systemImage: String = "info.circle", emphasis: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.emphasis = emphasis
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(tr(text))
                .font(Theme.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(emphasis ? Theme.ink : Theme.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Banda discreta para el último error.
public struct ErrorBand: View {
    var message: String
    var date: Date?
    var onClose: (() -> Void)?
    public init(_ message: String, date: Date? = nil, onClose: (() -> Void)? = nil) {
        self.message = message
        self.date = date
        self.onClose = onClose
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Rectangle().fill(Theme.destructive).frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(message))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let date {
                    Text(date, style: .time)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tr("Error: %@", tr(message)))
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Cerrar"))
                .accessibilityLabel(tr("Cerrar el aviso de error"))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.red).frame(width: 2) }
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .onAppear { announce() }
        .onChange(of: message) { _, _ in announce() }
    }

    /// VoiceOver lo dice al aparecer: si no, un error se queda sin oír hasta que se llega a él.
    private func announce() {
        AccessibilityNotification.Announcement(tr("Error: %@", tr(message))).post()
    }
}

/// Estado vacío dentro de una tarjeta.
public struct EmptyState: View {
    var systemImage: String
    var title: String
    var detail: String

    public init(systemImage: String, title: String, detail: String) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        VStack(spacing: Theme.Space.s) {
            IconTile(systemImage, size: 28)
            Text(tr(title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
            Text(tr(detail))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .padding(.horizontal, Theme.Space.l)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Reglas Permitir / Preguntar / Nunca

/// Segmentado compacto para una regla de permisos.
public struct RuleSegmented: View {
    var title: String
    @Binding var rule: PermissionRule

    public init(_ title: String, rule: Binding<PermissionRule>) {
        self.title = title
        _rule = rule
    }

    public var body: some View {
        BlockSegmented(tr("Regla para %@", tr(title)), selection: $rule,
                       options: PermissionRule.allCases.map { ($0, $0.title) }, compact: true)
    }
}

extension View {
    /// Pide confirmación antes de borrar algo que no se recupera con un clic (una clave del
    /// Llavero, una nota, una tarea…). Se enseña mientras `isPresented` es verdadero.
    func confirmRemoval(isPresented: Binding<Bool>, title: String, message: String,
                        button: String, action: @escaping () -> Void) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(button, role: .destructive, action: action)
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
