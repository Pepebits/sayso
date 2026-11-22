import SaySoCore
import AppKit
import SwiftUI

/// Píldora flotante del dictado. La muestra un `NSPanel` externo; aquí solo se dibuja.
/// Lo que enseña la píldora. El panel se crea una vez y solo cambia este estado: así no se
/// reconstruye ni se recoloca con cada palabra o cada nivel de audio.
@MainActor
public final class DictationHUDState: ObservableObject {
    @Published public var phase: DictationPhase = .idle
    @Published public var transcript = ""
    /// El atajo, tal como se dibuja en la píldora.
    @Published public var keySymbol = "⌥"
    /// Qué hace el agente ahora mismo («🔎 Buscando en la web»), mientras piensa.
    @Published public var step: String?
    /// Estado del modelo de voz mientras se descarga o carga («Descargando modelo… 34 %»).
    @Published public var modelStatus: String?
    public init() {}
}

/// Lienzo fijo y transparente del panel: la píldora queda anclada abajo y centrada, y la burbuja
/// crece hacia arriba sin mover nada.
public struct DictationHUDStage: View {
    @ObservedObject var state: DictationHUDState
    public static let size = CGSize(width: 520, height: 460)

    public init(state: DictationHUDState) { self.state = state }

    public var body: some View {
        DictationHUDView(phase: state.phase, transcript: state.transcript, keySymbol: state.keySymbol,
                         step: state.step, modelStatus: state.modelStatus)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
    }
}

public struct DictationHUDView: View {
    var phase: DictationPhase
    /// Lo reconocido hasta ahora: en vivo mientras se habla y definitivo al terminar.
    var transcript: String
    var keySymbol: String
    var step: String?
    var modelStatus: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(phase: DictationPhase, transcript: String = "", keySymbol: String = "⌥",
                step: String? = nil, modelStatus: String? = nil) {
        self.phase = phase
        self.transcript = transcript
        self.keySymbol = keySymbol
        self.step = step
        self.modelStatus = modelStatus
    }

    public var body: some View {
        VStack(spacing: 8) {
            if let text = bubbleText {
                // Burbuja clara sobre la píldora: lo que has dicho o lo que contesta el agente.
                Text(verbatim: text)
                    .font(Theme.text(isReply ? 14 : 13.5, weight: isReply ? .medium : .regular))
                    .foregroundStyle(Theme.fixedInk.opacity(phase == .correcting ? 0.45 : 1))
                    .lineLimit(isReply ? 12 : 4)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    // Ancho fijo: si la burbuja se ajustara al texto, cambiaría de tamaño con cada
                    // palabra reconocida y todo bailaría.
                    .frame(width: Self.bubbleWidth - 28, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Theme.fixedBone)
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Color(hex: 0xDDD7D3), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }
            HStack(spacing: 10) {
                KeyCap(symbol: keySymbol, size: 22, foreground: Theme.fixedBone, border: Theme.fixedBone.opacity(0.45))
                content
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 40)
            .background(Theme.fixedInk)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Color(hex: 0x383635), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .fixedSize()
        }
        // Sin `fixedSize` en el conjunto: con él, el alto se calculaba como si el texto de la
        // burbuja cupiera en una línea y la píldora quedaba cortada. El panel mide con `fittingSize(in:)`.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    static let bubbleWidth: CGFloat = 460
    /// Ancho máximo que se le propone a la vista al medirla.
    public static let maxWidth: CGFloat = 488

    /// Tamaño real de la vista para una fase y un texto dados, con el texto ya partido en líneas.
    @MainActor public static func fittingSize(phase: DictationPhase, transcript: String) -> CGSize {
        let controller = NSHostingController(rootView: DictationHUDView(phase: phase, transcript: transcript))
        let size = controller.sizeThatFits(in: CGSize(width: maxWidth, height: 2000))
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private var isReply: Bool {
        if case .agentReply = phase { return true }
        return false
    }

    /// Texto de la burbuja según la fase; `nil` si no hay nada que enseñar.
    private var bubbleText: String? {
        switch phase {
        case let .agentReply(answer): return answer
        case let .agentThinking(question): return question
        case .listening, .agentListening, .transcribing, .correcting:
            return transcript.isEmpty ? nil : transcript
        case .idle, .failed, .notice: return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case let .agentListening(level, handsFree):
            Waveform(level: CGFloat(level), animated: !reduceMotion)
            label(handsFree ? "Agente · manos libres" : "Te escucha el agente")
            Bit(size: 8, tone: .running)
        case .agentThinking:
            ProgressView().controlSize(.small).tint(Theme.fixedBone)
            // El paso en curso, si lo hay, dice qué hace en vez de un «en ello» genérico.
            label(step ?? "El agente está en ello…", translate: step == nil)
        case .agentReply:
            Bit(size: 8, tone: .running)
            label("Agente")
        case .idle:
            label("Mantén para hablar", dimmed: true)
        case let .listening(level, handsFree):
            Waveform(level: CGFloat(level), animated: !reduceMotion)
            label(handsFree ? "Manos libres" : "Escuchando")
            Bit(size: 8, tone: .running)
        case .transcribing:
            Waveform(level: 0, animated: false)
            // La primera vez el modelo se descarga (~480 MB): mejor decirlo que «transcribiendo» minutos.
            label(modelStatus ?? tr("Transcribiendo…"), translate: false)
        case .correcting:
            Waveform(level: 0, animated: false)
            label("Corrigiendo")
        case let .notice(message):
            Image(systemName: "ear")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.fixedBone)
                .accessibilityHidden(true)
            label(message, translate: false)
        case let .failed(message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.fixedBone)
            Text(tr(message))
                .font(Theme.text(12.5, weight: .semibold))
                .foregroundStyle(Theme.fixedBone)
                .lineLimit(2)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ text: String, dimmed: Bool = false, translate: Bool = true) -> some View {
        Text(verbatim: translate ? tr(text) : text)
            .font(Theme.text(12.5, weight: .semibold))
            .foregroundStyle(Theme.fixedBone.opacity(dimmed ? 0.6 : 1))
            .lineLimit(1)
    }

    private var accessibilityText: String {
        switch phase {
        case .agentListening: return tr("Te escucha el agente")
        case let .agentThinking(question):
            if let step { return tr("El agente está trabajando en: %@", question) + ". " + step }
            return tr("El agente está trabajando en: %@", question)
        case let .agentReply(answer): return tr("Respuesta del agente: %@", answer)
        case .idle: return "Dictado en espera"
        case let .listening(_, handsFree): return handsFree ? "Dictado manos libres" : "Escuchando"
        case .transcribing: return modelStatus ?? tr("Transcribiendo")
        case let .notice(message): return message
        case .correcting: return "Corrigiendo"
        case let .failed(message): return tr("Error de dictado: %@", tr(message))
        }
    }
}

/// Forma de onda de barras rectas que sigue el nivel de entrada.
private struct Waveform: View {
    var level: CGFloat
    var animated: Bool

    private let count = 11
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 20

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                bars(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(time: 0)
        }
    }

    private func bars(time: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                Rectangle()
                    .fill(Theme.fixedBone.opacity(level > 0 ? 1 : 0.35))
                    .frame(width: 3, height: height(for: i, time: time))
            }
        }
        .frame(height: maxHeight)
        .animation(animated ? .linear(duration: 0.08) : nil, value: level)
    }

    private func height(for index: Int, time: TimeInterval) -> CGFloat {
        let clamped = min(max(level, 0), 1)
        // Envolvente: más alta en el centro.
        let center = CGFloat(count - 1) / 2
        let envelope = 1 - abs(CGFloat(index) - center) / (center + 1)
        let wobble = animated ? CGFloat(0.55 + 0.45 * sin(time * 9 + Double(index) * 1.7)) : 1
        return minHeight + (maxHeight - minHeight) * clamped * envelope * wobble
    }
}
