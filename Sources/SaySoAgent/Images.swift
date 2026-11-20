import Foundation
import ImageIO
import UniformTypeIdentifiers
import SaySoCore

// Imágenes para modelos que las ven: fotos que manda el usuario, de sus chats o de la máquina Linux.

/// Una imagen lista para mandar al modelo.
public struct ModelImage: Sendable, Hashable {
    public var mediaType: String
    public var data: Data
    public var width: Int
    public var height: Int

    public init(mediaType: String, data: Data, width: Int, height: Int) {
        self.mediaType = mediaType
        self.data = data
        self.width = width
        self.height = height
    }

    /// Lado mayor tras reducirla: más no ayuda al modelo y cuesta tokens.
    public static let maxSide = 1568
    /// Lo más que se acepta de entrada.
    public static let maxInputBytes = 20 * 1024 * 1024

    public enum Failure: Error, LocalizedError {
        case notAnImage, tooLarge
        public var errorDescription: String? {
            switch self {
            case .notAnImage: return tr("Ese archivo no es una imagen que se pueda abrir.")
            case .tooLarge: return tr("La imagen pasa de 20 MB.")
            }
        }
    }

    /// La reduce si hace falta y la pasa a JPEG.
    public static func prepared(from data: Data) throws -> ModelImage {
        guard data.count <= maxInputBytes else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.notAnImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.notAnImage }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.notAnImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.notAnImage }
        return ModelImage(mediaType: "image/jpeg", data: out as Data, width: image.width, height: image.height)
    }
}

/// Herramienta que, además de texto, devuelve imágenes para que las vea el modelo.
public protocol ImageProducingTool: AgentTool {
    func callWithImages(input: JSONValue, context: ToolContext) async throws -> (String, [ModelImage])
}

public extension ImageProducingTool {
    func call(input: JSONValue, context: ToolContext) async throws -> String {
        try await callWithImages(input: input, context: context).0
    }
}

/// `view_image(path)`: mira una imagen del ordenador Linux.
public struct ViewImageTool: ImageProducingTool {
    let computer: AgentComputer
    public init(computer: AgentComputer) { self.computer = computer }
    public var name: String { "view_image" }
    public var description: String {
        "Mira una imagen de tu ordenador Linux (JPEG, PNG, HEIC, WebP…) para describirla, leer su texto o comprobar " +
            "que es la que buscas antes de mandarla."
    }
    public var inputSchema: JSONValue {
        .objectSchema(["path": .property("string", "Ruta de la imagen; relativa a ~/sayso")], required: ["path"])
    }
    public func callWithImages(input: JSONValue, context: ToolContext) async throws -> (String, [ModelImage]) {
        let path = try input.requiredString("path", maxLength: 1000)
        let image = try ModelImage.prepared(from: try await computer.readData(path, origin: context.origin))
        return ("Imagen \(path) (\(image.width)×\(image.height)) adjunta a continuación.", [image])
    }
}

/// `telegram_view_image(chat, message_id)`: mira la foto de un mensaje de los chats del usuario.
public struct ViewTelegramImageTool: ImageProducingTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_view_image" }
    public var description: String {
        "Mira la foto (o la imagen enviada como archivo) de un mensaje de un chat de Telegram del usuario: los que " +
            "telegram_read_messages muestra como [foto]. Sirve para describirla o leer su texto."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "message_id": ["type": "integer", "description": "Número del mensaje con la foto"],
        ], required: ["chat", "message_id"])
    }
    public func callWithImages(input: JSONValue, context: ToolContext) async throws -> (String, [ModelImage]) {
        let messageID = try TelegramUserTools.messageID(input)
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        let id = chat.id
        let api = self.api
        let media = try await broker.run(ActionRequest(
            action: TelegramAction.download, summary: "Ver la foto del mensaje #\(messageID) de «\(chat.title)»",
            parameters: ["Chat": chat.title, "Mensaje": "#\(messageID)"], origin: context.origin)) {
            try await api.download(chatID: id, messageID: messageID)
        }
        guard media.kind == "foto" || media.kind == "documento" else {
            throw ToolInputError("El mensaje #\(messageID) no es una foto: es \(media.kind).")
        }
        let image = try ModelImage.prepared(from: media.data)
        return (TelegramUserTools.untrusted + "\nFoto del mensaje #\(messageID) de «\(chat.title)» adjunta a continuación.", [image])
    }
}

// MARK: - HTML a imagen o PDF

public struct HTMLRenderOptions: Sendable, Hashable {
    public enum Format: String, Sendable { case png, pdf }
    public var format: Format
    /// Ancho de la página en puntos.
    public var width: Int
    /// Segundos de espera tras cargar, para scripts y escenas 3D.
    public var wait: Double

    public init(format: Format = .png, width: Int = 1200, wait: Double = 1.5) {
        self.format = format
        self.width = width
        self.wait = wait
    }
}

public enum HTMLRenderError: Error, LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        switch self { case let .failed(reason): return "No se pudo convertir el HTML: \(reason)." }
    }
}

/// `render_html`: convierte un HTML de la máquina Linux en PNG (la página entera, aunque sea muy
/// larga) o en PDF, con WebKit en el Mac (WebGL incluido). El resultado queda en la máquina.
public struct RenderHTMLTool: ImageProducingTool {
    public typealias Render = @Sendable (String, HTMLRenderOptions) async throws -> Data
    let computer: AgentComputer
    let render: Render
    public init(computer: AgentComputer, render: @escaping Render) {
        self.computer = computer
        self.render = render
    }
    public var name: String { "render_html" }
    public var description: String {
        """
        Convierte un archivo HTML de tu ordenador Linux en una imagen PNG de la página entera (también las \
        muy largas) o en un PDF, para enviarlo con send_file. Funcionan CSS, JavaScript, gráficos y escenas \
        3D con WebGL (three.js…); las librerías pueden cargarse de un CDN. El resultado se guarda junto al HTML \
        con la extensión nueva. Si la página anima o pinta tarde, sube «wait».
        """
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "path": .property("string", "Ruta del .html; relativa a ~/sayso"),
            "format": ["type": "string", "enum": ["png", "pdf"], "description": "png (por defecto) o pdf"],
            "width": ["type": "integer", "minimum": 320, "maximum": 2400, "description": "Ancho en puntos (1200 por defecto)"],
            "wait": ["type": "number", "minimum": 0.5, "maximum": 15, "description": "Segundos de espera tras cargar (1,5 por defecto)"],
        ], required: ["path"])
    }

    /// `informe.html` → `informe.png`.
    static func outputPath(for path: String, format: HTMLRenderOptions.Format) -> String {
        let base = path.hasSuffix(".html") ? String(path.dropLast(5)) : (path.hasSuffix(".htm") ? String(path.dropLast(4)) : path)
        return base + "." + format.rawValue
    }

    public func callWithImages(input: JSONValue, context: ToolContext) async throws -> (String, [ModelImage]) {
        let path = try input.requiredString("path", maxLength: 1000)
        let format = input["format"]?.stringValue.flatMap(HTMLRenderOptions.Format.init(rawValue:)) ?? .png
        let options = HTMLRenderOptions(format: format, width: input["width"]?.intValue ?? 1200,
                                        wait: input["wait"]?.doubleValue ?? 1.5)
        let html = try await computer.readFile(path, origin: context.origin)
        guard html.count <= 5_000_000 else { throw ToolInputError("El HTML pasa de 5 MB.") }
        let data = try await render(html, options)
        let output = Self.outputPath(for: path, format: format)
        try await computer.writeData(output, data: data, origin: context.origin)
        let kb = max(1, data.count / 1024)
        if format == .png, let image = try? ModelImage.prepared(from: data) {
            return ("Guardado en \(output) (\(kb) KB). Vista previa adjunta: compruébala antes de enviarla.", [image])
        }
        return ("Guardado en \(output) (\(kb) KB).", [])
    }
}
