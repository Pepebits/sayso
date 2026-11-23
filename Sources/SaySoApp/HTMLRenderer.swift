import AppKit
import SaySoAgent
import WebKit

/// Convierte HTML en una imagen de la página entera (también las muy largas) o en un PDF, con
/// WebKit en el Mac: así funciona WebGL (escenas 3D). Sin cookies ni datos guardados, y en una
/// ventana fuera de la pantalla que nunca se ve.
///
/// El HTML lo escribe el agente y puede venir de contenido ajeno: no tiene red salvo unas pocas CDN
/// de librerías (three.js, fuentes…), ni puede navegar a otra página. Así no lee la red local del Mac
/// (el router, servicios en localhost) ni saca datos con `<img src="https://…?datos">`.
@MainActor
final class HTMLRenderer: NSObject, WKNavigationDelegate {
    /// Alto máximo de una captura, en puntos: más es memoria sin sentido.
    static let maxHeight: CGFloat = 16_000

    private var finished: CheckedContinuation<Void, Error>?
    private var loaded = false
    /// Cuánto puede tardar en cargar antes de darlo por fallido.
    static let loadTimeout: UInt64 = 20_000_000_000

    /// Bloquea todo menos `data:`, `blob:` y las CDN de librerías. Las listas de contenido de WebKit no
    /// admiten alternativas (`a|b`) en sus expresiones: una regla por cada excepción.
    static let allowedHosts = ["cdn.jsdelivr.net", "cdnjs.cloudflare.com", "unpkg.com", "esm.sh",
                               "fonts.googleapis.com", "fonts.gstatic.com"]
    static var rules: String {
        let allow = ["^data:", "^blob:", "^about:"]
            + allowedHosts.map { "^https://" + $0.replacingOccurrences(of: ".", with: "\\.") + "/" }
        let entries = [#"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#]
            + allow.map { #"{"trigger":{"url-filter":""# + $0.replacingOccurrences(of: "\\", with: "\\\\") + #""},"action":{"type":"ignore-previous-rules"}}"# }
        return "[" + entries.joined(separator: ",") + "]"
    }
    private static var compiled: WKContentRuleList?

    private static func ruleList() async throws -> WKContentRuleList {
        if let compiled { return compiled }
        guard let list = try await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "sayso-render-html-2", encodedContentRuleList: rules) else {
            throw HTMLRenderError.failed("no se pudieron preparar las reglas de red")
        }
        compiled = list
        return list
    }

    func render(_ html: String, options: HTMLRenderOptions) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(try await Self.ruleList())
        loaded = false
        let width = CGFloat(min(max(options.width, 320), 2400))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        // Fuera de la pantalla, pero en una ventana: sin ella, WebGL y las capas no se dibujan.
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        defer {
            webView.navigationDelegate = nil
            window.orderOut(nil)
            window.close()
        }
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.loadTimeout)
            guard !Task.isCancelled else { return }
            self?.finished?.resume(throwing: HTMLRenderError.failed("la página no terminó de cargar en 20 s"))
            self?.finished = nil
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finished = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        // Tiempo para scripts, fuentes y animaciones (una escena 3D tarda en pintar).
        try await Task.sleep(nanoseconds: UInt64(min(max(options.wait, 0.5), 15) * 1_000_000_000))
        // Con la vista casi sin alto, scrollHeight es el alto del contenido y no el de la ventana.
        window.setContentSize(NSSize(width: width, height: 10))
        webView.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        try await Task.sleep(nanoseconds: 150_000_000)
        // Un script que no acaba (un bucle infinito) dejaba colgadas la medida y la captura sin
        // límite: cada paso tiene ahora su tope.
        let measured: Double = try await Self.limited(Self.stepTimeout) {
            try await webView.evaluateJavaScript(
                "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)") as? Double ?? 900
        }
        let height = min(max(CGFloat(measured), 200), Self.maxHeight)
        window.setContentSize(NSSize(width: width, height: height))
        webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        try await Task.sleep(nanoseconds: 400_000_000)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        switch options.format {
        case .pdf:
            let pdf = WKPDFConfiguration()
            pdf.rect = rect
            return try await Self.limited(Self.stepTimeout) { try await webView.pdf(configuration: pdf) }
        case .png:
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = rect
            snapshot.afterScreenUpdates = true
            let image = try await Self.limited(Self.stepTimeout) { try await SendableImage(webView.takeSnapshot(configuration: snapshot)) }.image
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw HTMLRenderError.failed("no se pudo guardar la imagen")
            }
            return png
        }
    }

    /// Tope de cada paso tras la carga (medir, capturar), en segundos.
    static let stepTimeout: Double = 20

    /// Ejecuta `operation` y falla si tarda más de `seconds`, sin esperar a que termine.
    static func limited<T: Sendable>(_ seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let once = RenderOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task { @MainActor in
                do {
                    let value = try await operation()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard once.claim() else { return }
                work.cancel()
                continuation.resume(throwing: HTMLRenderError.failed("la página no respondió en \(Int(seconds)) s"))
            }
        }
    }

    /// Solo la carga inicial del HTML: ni enlaces, ni redirecciones, ni `location = …`.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Los iframes los frena la lista de red; la página principal solo carga una vez.
        guard navigationAction.targetFrame?.isMainFrame ?? true else { return decisionHandler(.allow) }
        if loaded { return decisionHandler(.cancel) }
        loaded = true
        decisionHandler(.allow)
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.finished?.resume(throwing: HTMLRenderError.failed("WebKit se ha cerrado al dibujar la página"))
            self.finished = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finished?.resume(throwing: error); self.finished = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finished?.resume(throwing: error); self.finished = nil }
    }
}

/// Garantiza una sola reanudación entre la tarea y su tope.
private final class RenderOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// `NSImage` no es `Sendable`; solo se usa en el hilo principal.
private struct SendableImage: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}
