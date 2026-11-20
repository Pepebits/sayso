import SaySoCore
import AppKit
import SwiftUI

// Tokens visuales de la marca Pepebits: tinta sobre hueso y un único acento rojo.

public enum Theme {
    // MARK: Colores base (fijos)

    static let inkHex: UInt32 = 0x1C1B1B
    static let boneHex: UInt32 = 0xFCF9F8

    /// Rojo eléctrico: el «bit» de la marca, la grabación y los avisos. Nunca «en marcha».
    public static let red = Color(hex: 0xFF3E3E)
    /// Etiqueta «pendiente».
    public static let yellow = Color(hex: 0xFDD400)
    /// Etiqueta «conectando».
    public static let turquoise = Color(hex: 0x00C2BA)
    /// Tinta fija, para texto sobre amarillo o turquesa en ambos modos.
    public static let fixedInk = Color(hex: inkHex)
    public static let fixedBone = Color(hex: boneHex)

    // MARK: Colores adaptados (claro / oscuro)
    //
    // Los pares están medidos contra el fondo y contra las tarjetas (WCAG 2.2): el texto llega a
    // 4,5:1 y los bordes de controles a 3:1. `PaletteTests` lo comprueba. Con «Aumentar contraste»
    // activado en macOS se usan las variantes `HC`.

    /// Texto, iconos y bloques sólidos (fila seleccionada, botón primario, interruptor activo).
    public static let ink = Color.adaptive(Palette.ink)
    /// Fondo de ventana y texto sobre bloques de tinta.
    public static let paper = Color.adaptive(Palette.paper)
    /// Tarjetas y barra lateral.
    public static let surface = Color.adaptive(Palette.surface)
    /// Separadores y contorno de tarjetas: decorativos, no delimitan controles.
    public static let border = Color.adaptive(Palette.border)
    /// Contorno de campos, botones, interruptores y segmentados: 3:1 como mínimo.
    public static let controlBorder = Color.adaptive(Palette.controlBorder)
    /// Texto secundario.
    public static let secondary = Color.adaptive(Palette.secondary)
    /// Texto de menor peso (valores vacíos, cheurones). Sigue siendo legible: 4,5:1.
    public static let tertiary = Color.adaptive(Palette.tertiary)
    /// Rojo para textos destructivos y errores.
    public static let destructive = Color.adaptive(Palette.destructive)
    /// Fondo de la consola: tinta en claro y casi negro en oscuro, donde la tinta es ya el fondo
    /// de la ventana y la consola no se distinguiría.
    public static let console = Color.adaptive(Palette.console)
    /// Barra superior de la consola, un punto más clara que su fondo.
    public static let consoleBar = Color.adaptive(Palette.consoleBar)
    /// Verde de «en marcha».
    public static let running = Color.adaptive(Palette.running)
    /// Barras de lo que hace la IA o el agente.
    public static let chartAI = Color.adaptive(Palette.chartAI)
    /// Barras de lo que dictas.
    public static let chartVoice = Color.adaptive(Palette.chartVoice)

    // MARK: Forma y espacios

    /// Radio de botones, campos y controles. El «bit» y el logo siguen siendo cuadrados.
    public static let radius: CGFloat = 4
    /// Radio de tarjetas y paneles.
    public static let cardRadius: CGFloat = 4
    /// Radio de piezas pequeñas dentro de un control (segmento activo, etiquetas, mando).
    public static let innerRadius: CGFloat = 2
    public static let hairline: CGFloat = 1

    public enum Space {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public static let sidebarWidth: CGFloat = 230
    public static let contentMaxWidth: CGFloat = 760

    // MARK: Tipografía

    private static let families = Set(NSFontManager.shared.availableFontFamilies)
    static let hasHanken = families.contains("Hanken Grotesk")
    static let hasInter = families.contains("Inter")

    /// Títulos de pantalla y nombre de la app: Hanken Grotesk 800 o la del sistema en heavy.
    public static func display(_ size: CGFloat) -> Font {
        if hasHanken { return Font.custom("Hanken Grotesk", size: size).weight(.heavy) }
        return .system(size: size, weight: .heavy)
    }

    /// Texto general: Inter si está instalada; si no, la del sistema.
    public static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if hasInter { return Font.custom("Inter", size: size).weight(weight) }
        return .system(size: size, weight: weight)
    }

    /// Terminal y nombres de claves.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static let body = text(13)
    public static let bodyStrong = text(13, weight: .semibold)
    public static let caption = text(12)
    /// Encabezado de sección en mayúsculas.
    public static let sectionLabel = text(11.5, weight: .bold)
}

// MARK: - Paleta

/// Un color en sus cuatro variantes: claro, oscuro y ambas con «Aumentar contraste».
struct PaletteColor {
    var light: UInt32
    var dark: UInt32
    var lightHC: UInt32
    var darkHC: UInt32

    init(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil) {
        self.light = light
        self.dark = dark
        self.lightHC = lightHC ?? light
        self.darkHC = darkHC ?? dark
    }
}

enum Palette {
    static let ink = PaletteColor(light: Theme.inkHex, dark: Theme.boneHex)
    static let paper = PaletteColor(light: Theme.boneHex, dark: Theme.inkHex)
    static let surface = PaletteColor(light: 0xF2EEEC, dark: 0x262524)
    static let border = PaletteColor(light: 0xDDD7D3, dark: 0x403E3D, lightHC: 0x6B6968, darkHC: 0x94908E)
    static let controlBorder = PaletteColor(light: 0x8A8684, dark: 0x7D7977,
                                            lightHC: Theme.inkHex, darkHC: Theme.boneHex)
    static let secondary = PaletteColor(light: 0x595756, dark: 0xB5B1AF, lightHC: 0x3A3838, darkHC: 0xD9D5D3)
    static let tertiary = PaletteColor(light: 0x6B6968, dark: 0x94908E, lightHC: 0x4A4847, darkHC: 0xC4C0BE)
    static let destructive = PaletteColor(light: 0xC21F1F, dark: 0xFF6B6B, lightHC: 0x9E1414, darkHC: 0xFF8F8F)
    static let console = PaletteColor(light: Theme.inkHex, dark: 0x0A0909)
    static let consoleBar = PaletteColor(light: 0x2B2928, dark: 0x343231)
    static let running = PaletteColor(light: 0x178A3A, dark: 0x3DDC84, lightHC: 0x0F6B2B, darkHC: 0x6BEBA3)
    /// Series de los gráficos: turquesa para la IA y el agente, amarillo para la voz. En claro van
    /// oscurecidos para llegar a 3:1 sobre el fondo; en oscuro son los de la marca.
    static let chartAI = PaletteColor(light: 0x007F7A, dark: 0x00C2BA, lightHC: 0x005E5A, darkHC: 0x4DE0D9)
    static let chartVoice = PaletteColor(light: 0x946C00, dark: 0xFDD400, lightHC: 0x6E5000, darkHC: 0xFFE14D)

    /// Contraste WCAG entre dos colores opacos (1…21).
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func luminance(_ hex: UInt32) -> Double {
            0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

// MARK: - Utilidades de color

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }

    static func adaptive(_ color: PaletteColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let names: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                              .accessibilityHighContrastDarkAqua]
            switch appearance.bestMatch(from: names) {
            case .darkAqua: return NSColor(hex: color.dark)
            case .accessibilityHighContrastAqua: return NSColor(hex: color.lightHC)
            case .accessibilityHighContrastDarkAqua: return NSColor(hex: color.darkHC)
            default: return NSColor(hex: color.light)
            }
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: CGFloat(alpha))
    }
}

// MARK: - Fechas relativas

enum RelativeDate {
    /// Uno por idioma: si se cambia el idioma en Ajustes, las fechas cambian con él.
    private static var formatters: [String: RelativeDateTimeFormatter] = [:]

    private static var formatter: RelativeDateTimeFormatter {
        let code = L10n.languageCode
        if let cached = formatters[code] { return cached }
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        f.unitsStyle = .full
        formatters[code] = f
        return f
    }

    /// «hace 5 minutos», «ayer»…
    static func string(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 45 { return tr("ahora mismo") }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
