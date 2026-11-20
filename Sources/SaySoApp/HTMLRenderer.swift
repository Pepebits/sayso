import AppKit
import SaySoAgent
import WebKit

/// Convierte HTML en una imagen de la página entera (también las muy largas) o en un PDF, con
/// WebKit en el Mac: así funciona WebGL (escenas 3D). Sin cookies ni datos guardados, y en una
/// ventana fuera de la pantalla que nunca se ve.
@MainActor
final class HTMLRenderer: NSObject, WKNavigationDelegate {
    /// Alto máximo de una captura, en puntos: más es memoria sin sentido.
    static let maxHeight: CGFloat = 16_000

    private var finished: CheckedContinuation<Void, Error>?

    func render(_ html: String, options: HTMLRenderOptions) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finished = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        // Tiempo para scripts, fuentes y animaciones (una escena 3D tarda en pintar).
        try await Task.sleep(nanoseconds: UInt64(min(max(options.wait, 0.5), 15) * 1_000_000_000))
        let measured = try await webView.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)") as? Double ?? 900
        let height = min(max(CGFloat(measured), 200), Self.maxHeight)
        window.setContentSize(NSSize(width: width, height: height))
        webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        try await Task.sleep(nanoseconds: 400_000_000)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        switch options.format {
        case .pdf:
            let pdf = WKPDFConfiguration()
            pdf.rect = rect
            return try await webView.pdf(configuration: pdf)
        case .png:
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = rect
            snapshot.afterScreenUpdates = true
            let image = try await webView.takeSnapshot(configuration: snapshot)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw HTMLRenderError.failed("no se pudo guardar la imagen")
            }
            return png
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
