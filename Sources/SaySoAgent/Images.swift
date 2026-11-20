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
