import Foundation
import SaySoCore
import SaySoAgent

// Envíos más completos, gestión de chats y de la cuenta, y lo menos habitual, con las firmas de
// TDLib 1.8.70 (td/generate/scheme/td_api.tl del paquete).

extension TDLibSession {
    private static func number(_ value: Int64) -> JSONValue { .number(Double(value)) }
    private static func formatted(_ text: String) -> JSONValue { ["@type": "formattedText", "text": .string(text)] }

    /// La persona de un chat privado. En TDLib el id del chat privado coincide con el del usuario,
    /// pero se lee del tipo para no depender de eso.
    func userID(ofChat chatID: Int64) async throws -> Int64 {
        let raw = try await request(["@type": "getChat", "chat_id": Self.number(chatID)])
        guard raw["type"]?["@type"]?.stringValue == "chatTypePrivate", let id = raw["type"]?["user_id"]?.intValue else {
            throw ToolInputError("Ese chat no es de una persona.")
        }
        return Int64(id)
    }

    // MARK: Envíos

    public func send(chatID: Int64, text: String, at date: Date?) async throws {
        guard let date else { return try await send(chatID: chatID, text: text) }
        try requireReady()
        // Hasta que Telegram lo confirma, no aparece entre los programados del chat.
        let message = try await request([
            "@type": "sendMessage", "chat_id": Self.number(chatID),
            "options": ["@type": "messageSendOptions",
                        "scheduling_state": ["@type": "messageSchedulingStateSendAtDate",
                                             "send_date": .number(date.timeIntervalSince1970.rounded()), "repeat_period": 0]],
            "input_message_content": Self.textContent(text),
        ])
        if let id = message["id"]?.intValue { try await waitForDelivery(messageID: Int64(id), timeout: 30) }
    }

    public func sendAlbum(chatID: Int64, files: [TGOutgoingFile], caption: String?) async throws {
        try requireReady()
        let folder = try Self.outgoingFolder().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var contents: [JSONValue] = []
        for (index, file) in files.enumerated() {
            let name = (file.filename as NSString).lastPathComponent
            let url = folder.appendingPathComponent("\(index)-\(name.isEmpty ? "archivo" : name)")
            try file.data.write(to: url)
            // El texto va en el primero: Telegram lo enseña bajo el álbum.
            contents.append(Self.fileContent(path: url.path, caption: index == 0 ? caption : nil, kind: file.kind))
        }
        let sent = try await request([
            "@type": "sendMessageAlbum", "chat_id": Self.number(chatID), "input_message_contents": .array(contents),
        ])
        if let last = sent["messages"]?.arrayValue?.last?["id"]?.intValue {
            try await waitForDelivery(messageID: Int64(last), timeout: 180)
        }
    }

    static func specialContent(_ content: TGSpecialContent, contact: JSONValue? = nil) -> JSONValue {
        switch content {
        case .poll(let question, let options, let anonymous, let multiple, let correct):
            let type: JSONValue = correct.map {
                ["@type": "inputPollTypeQuiz", "correct_option_ids": [.number(Double($0))], "explanation": formatted("")]
            } ?? ["@type": "inputPollTypeRegular", "allow_adding_options": false]
            return [
                "@type": "inputMessagePoll", "question": formatted(question),
                "options": .array(options.map { ["@type": "inputPollOption", "text": formatted($0)] }),
                "is_anonymous": .bool(anonymous), "allows_multiple_answers": .bool(multiple), "type": type,
            ]
        case .location(let latitude, let longitude):
            return ["@type": "inputMessageLocation",
                    "location": ["@type": "location", "latitude": .number(latitude), "longitude": .number(longitude),
                                 "horizontal_accuracy": 0]]
        case .contact:
            return ["@type": "inputMessageContact", "contact": contact ?? .null]
        case .dice(let emoji):
            return ["@type": "inputMessageDice", "emoji": .string(emoji), "clear_draft": false]
        }
    }

    public func sendSpecial(chatID: Int64, content: TGSpecialContent) async throws {
        try requireReady()
        var contact: JSONValue?
        if case .contact(let personChat) = content {
            let userID = try await userID(ofChat: personChat)
            let user = try await request(["@type": "getUser", "user_id": Self.number(userID)])
            // Sin teléfono Telegram rechaza la tarjeta («Wrong phone number specified»).
            guard let phone = user["phone_number"]?.stringValue, !phone.isEmpty else {
                throw ToolInputError("Esa persona no comparte su teléfono contigo: Telegram no deja enviar su tarjeta de contacto. Envía su @alias en un mensaje.")
            }
            contact = ["@type": "contact", "phone_number": .string(phone),
                       "first_name": .string(user["first_name"]?.stringValue ?? ""),
                       "last_name": .string(user["last_name"]?.stringValue ?? ""), "vcard": "",
                       "user_id": Self.number(userID)]
        }
        let message = try await request([
            "@type": "sendMessage", "chat_id": Self.number(chatID),
            "input_message_content": Self.specialContent(content, contact: contact),
        ])
        if let id = message["id"]?.intValue { try await waitForDelivery(messageID: Int64(id), timeout: 30) }
    }

    public func scheduledMessages(chatID: Int64) async throws -> [TGUserMessage] {
        try requireReady()
        let raw = try await request(["@type": "getChatScheduledMessages", "chat_id": Self.number(chatID)])
        let list = raw["messages"]?.arrayValue ?? []
        var messages = await convert(list)
        // La fecha que importa es la de envío, no la de creación.
        for (index, item) in list.enumerated() where index < messages.count {
            if let send = item["scheduling_state"]?["send_date"]?.doubleValue {
                messages[index].date = Date(timeIntervalSince1970: send)
            }
        }
        return messages
    }

    // MARK: Gestión de chats y de la cuenta

    public func pin(chatID: Int64, messageID: Int64, pinned: Bool, onlyForSelf: Bool) async throws {
        try requireReady()
        if pinned {
            _ = try await request(["@type": "pinChatMessage", "chat_id": Self.number(chatID), "message_id": Self.number(messageID),
                                   "disable_notification": false, "only_for_self": .bool(onlyForSelf)])
        } else {
            _ = try await request(["@type": "unpinChatMessage", "chat_id": Self.number(chatID), "message_id": Self.number(messageID)])
        }
    }

    /// Silenciado «para siempre», como hacen las apps oficiales (algo más de un año basta).
    static let muteForever = 2_147_483_647

    public func setMuted(chatID: Int64, muted: Bool) async throws {
        try requireReady()
        // Se parte de los ajustes actuales del chat: los campos que no se envían volverían a su
        // valor vacío (por ejemplo, el sonido).
        let raw = try await request(["@type": "getChat", "chat_id": Self.number(chatID)])
        var settings = raw["notification_settings"]?.objectValue ?? [:]
        settings["@type"] = "chatNotificationSettings"
        settings["use_default_mute_for"] = false
        settings["mute_for"] = .number(Double(muted ? Self.muteForever : 0))
        _ = try await request(["@type": "setChatNotificationSettings", "chat_id": Self.number(chatID),
                               "notification_settings": .object(settings)])
    }

    public func setArchived(chatID: Int64, archived: Bool) async throws {
        try requireReady()
        _ = try await request(["@type": "addChatToList", "chat_id": Self.number(chatID),
                               "chat_list": ["@type": .string(archived ? "chatListArchive" : "chatListMain")]])
    }

    static func lastSeen(_ status: JSONValue?) -> String {
        switch status?["@type"]?.stringValue {
        case "userStatusOnline": return "en línea"
        case "userStatusOffline":
            let date = Date(timeIntervalSince1970: status?["was_online"]?.doubleValue ?? 0)
            let f = DateFormatter()
            f.locale = Locale(identifier: "es_ES")
            f.dateFormat = "d MMM yyyy HH:mm"
            return "última vez el \(f.string(from: date))"
        case "userStatusRecently": return "hace poco"
        case "userStatusLastWeek": return "esta semana"
        case "userStatusLastMonth": return "este mes"
        default: return "hace mucho o no lo enseña"
        }
    }

    public func profile(chatID: Int64) async throws -> String {
        try requireReady()
        let raw = try await request(["@type": "getChat", "chat_id": Self.number(chatID)])
        let title = raw["title"]?.stringValue ?? ""
        var lines: [String] = []
        switch raw["type"]?["@type"]?.stringValue {
        case "chatTypePrivate":
            guard let id = raw["type"]?["user_id"]?.intValue else { break }
            let user = try await request(["@type": "getUser", "user_id": .number(Double(id))])
            let full = try? await request(["@type": "getUserFullInfo", "user_id": .number(Double(id))])
            lines.append("Persona: \(Self.name(of: user))")
            if let alias = Self.alias(fromUsernames: user["usernames"]) { lines.append("Alias: @\(alias)") }
            if let bio = full?["bio"]?["text"]?.stringValue, !bio.isEmpty { lines.append("Biografía: \(bio)") }
            lines.append("Conexión: \(Self.lastSeen(user["status"]))")
            lines.append("En tus contactos: \(user["is_contact"]?.boolValue == true ? "sí" : "no")")
            let blocked = full?["block_list"].map { !$0.isNull } ?? false
            lines.append("Bloqueada: \(blocked ? "sí" : "no")")
            if let common = full?["group_in_common_count"]?.intValue, common > 0 { lines.append("Grupos en común: \(common)") }
            if user["type"]?["@type"]?.stringValue == "userTypeBot" { lines.append("Es un bot.") }
        case "chatTypeSupergroup":
            guard let id = raw["type"]?["supergroup_id"]?.intValue else { break }
            let full = try? await request(["@type": "getSupergroupFullInfo", "supergroup_id": .number(Double(id))])
            lines.append("\(raw["type"]?["is_channel"]?.boolValue == true ? "Canal" : "Grupo"): \(title)")
            if let alias = await aliasOfChat(raw) { lines.append("Alias: @\(alias)") }
            if let members = full?["member_count"]?.intValue { lines.append("Miembros: \(members)") }
            if let text = full?["description"]?.stringValue, !text.isEmpty { lines.append("Descripción: \(text)") }
        case "chatTypeBasicGroup":
            guard let id = raw["type"]?["basic_group_id"]?.intValue else { break }
            let full = try? await request(["@type": "getBasicGroupFullInfo", "basic_group_id": .number(Double(id))])
            lines.append("Grupo: \(title)")
            if let members = full?["members"]?.arrayValue?.count { lines.append("Miembros: \(members)") }
            if let text = full?["description"]?.stringValue, !text.isEmpty { lines.append("Descripción: \(text)") }
        default:
            break
        }
        return lines.isEmpty ? "No hay datos del perfil de «\(title)»." : lines.joined(separator: "\n")
    }

    private func aliasOfChat(_ raw: JSONValue) async -> String? {
        guard let id = raw["type"]?["supergroup_id"]?.intValue,
              let group = try? await request(["@type": "getSupergroup", "supergroup_id": .number(Double(id))]) else { return nil }
        return Self.alias(fromUsernames: group["usernames"])
    }

    public func addContact(chatID: Int64, firstName: String, lastName: String) async throws {
        try requireReady()
        let userID = try await userID(ofChat: chatID)
        _ = try await request([
            "@type": "addContact", "user_id": Self.number(userID),
            "contact": ["@type": "importedContact", "phone_number": "", "first_name": .string(firstName),
                        "last_name": .string(lastName)],
            "share_phone_number": false,
        ])
    }

    public func setBlocked(chatID: Int64, blocked: Bool) async throws {
        try requireReady()
        let userID = try await userID(ofChat: chatID)
        _ = try await request([
            "@type": "setMessageSenderBlockList",
            "sender_id": ["@type": "messageSenderUser", "user_id": Self.number(userID)],
            "block_list": blocked ? ["@type": "blockListMain"] : .null,
        ])
    }

    public func createGroup(title: String, memberChatIDs: [Int64]) async throws -> TGUserChat {
        try requireReady()
        var users: [JSONValue] = []
        for chat in memberChatIDs { users.append(Self.number(try await userID(ofChat: chat))) }
        let created = try await request(["@type": "createNewBasicGroupChat", "user_ids": .array(users),
                                         "title": .string(title), "message_auto_delete_time": 0])
        guard let id = created["chat_id"]?.intValue else { throw ToolInputError("Telegram no ha devuelto el grupo creado.") }
        return try await chat(id: Int64(id))
    }

    public func addMembers(chatID: Int64, memberChatIDs: [Int64]) async throws {
        try requireReady()
        var users: [Int64] = []
        for chat in memberChatIDs { users.append(try await userID(ofChat: chat)) }
        let raw = try await request(["@type": "getChat", "chat_id": Self.number(chatID)])
        if raw["type"]?["@type"]?.stringValue == "chatTypeSupergroup" {
            _ = try await request(["@type": "addChatMembers", "chat_id": Self.number(chatID),
                                   "user_ids": .array(users.map(Self.number))])
        } else {
            // En los grupos básicos se añaden de uno en uno; ven los últimos 100 mensajes.
            for user in users {
                _ = try await request(["@type": "addChatMember", "chat_id": Self.number(chatID),
                                       "user_id": Self.number(user), "forward_limit": 100])
            }
        }
    }

    public func removeMember(chatID: Int64, memberChatID: Int64) async throws {
        try requireReady()
        let userID = try await userID(ofChat: memberChatID)
        let member: JSONValue = ["@type": "messageSenderUser", "user_id": Self.number(userID)]
        _ = try await request(["@type": "setChatMemberStatus", "chat_id": Self.number(chatID), "member_id": member,
                               "status": ["@type": "chatMemberStatusBanned", "banned_until_date": 0]])
        // En un supergrupo, expulsar deja a la persona vetada: se levanta el veto para que solo quede fuera.
        let raw = try await request(["@type": "getChat", "chat_id": Self.number(chatID)])
        if raw["type"]?["@type"]?.stringValue == "chatTypeSupergroup" {
            _ = try await request(["@type": "setChatMemberStatus", "chat_id": Self.number(chatID), "member_id": member,
                                   "status": ["@type": "chatMemberStatusLeft"]])
        }
    }

    public func join(inviteLink: String) async throws -> TGUserChat? {
        try requireReady()
        let link = inviteLink.hasPrefix("http") ? inviteLink : "https://" + inviteLink
        let result = try await request(["@type": "joinChatByInviteLink", "invite_link": .string(link)])
        guard result["@type"]?.stringValue == "chatJoinResultSuccess", let id = result["chat_id"]?.intValue else { return nil }
        return try await chat(id: Int64(id))
    }

    public func leave(chatID: Int64) async throws {
        try requireReady()
        _ = try await request(["@type": "leaveChat", "chat_id": Self.number(chatID)])
    }

    public func messageLink(chatID: Int64, messageID: Int64) async throws -> String {
        try requireReady()
        let link = try await request([
            "@type": "getMessageLink", "chat_id": Self.number(chatID), "message_id": Self.number(messageID),
            "media_timestamp": 0, "for_album": false, "in_message_thread": false,
        ])
        guard let url = link["link"]?.stringValue, !url.isEmpty else { throw ToolInputError("Ese mensaje no tiene enlace.") }
        return url
    }

    // MARK: Menos habitual

    public func vote(chatID: Int64, messageID: Int64, options: [Int]) async throws {
        try requireReady()
        _ = try await request(["@type": "setPollAnswer", "chat_id": Self.number(chatID), "message_id": Self.number(messageID),
                               "option_ids": .array(options.map { .number(Double($0)) })])
    }

    public func savedMessagesChat() async throws -> TGUserChat {
        try requireReady()
        let me = try await request(["@type": "getMe"])
        guard let id = me["id"]?.intValue else { throw TelegramUserError.notReady }
        let raw = try await request(["@type": "createPrivateChat", "user_id": .number(Double(id)), "force": false])
        guard let chatID = raw["id"]?.intValue else { throw TelegramUserError.notReady }
        return TGUserChat(id: Int64(chatID), title: tr("Mensajes guardados"), kind: .personal)
    }

    public func stories(chatID: Int64) async throws -> [TGStory] {
        try requireReady()
        let active = try await request(["@type": "getChatActiveStories", "chat_id": Self.number(chatID)])
        var out: [TGStory] = []
        for info in (active["stories"]?.arrayValue ?? []).suffix(10) {
            guard let id = info["story_id"]?.intValue else { continue }
            let story = try? await request(["@type": "getStory", "story_poster_chat_id": Self.number(chatID),
                                            "story_id": .number(Double(id)), "only_local": false])
            let kind = story?["content"]?["@type"]?.stringValue == "storyContentVideo" ? "vídeo" : "foto"
            out.append(TGStory(id: id, date: Date(timeIntervalSince1970: info["date"]?.doubleValue ?? 0),
                               caption: story?["caption"]?["text"]?.stringValue ?? "", kind: kind))
        }
        return out
    }

    // MARK: Stickers y carpetas

    public func stickerPacks() async throws -> [TGStickerPack] {
        try requireReady()
        let sets = try await request(["@type": "getInstalledStickerSets", "sticker_type": ["@type": "stickerTypeRegular"]])
        return (sets["sets"]?.arrayValue ?? []).compactMap { set in
            // Los int64 llegan como texto en el JSON de TDLib.
            guard let id = set["id"]?.stringValue ?? set["id"]?.intValue.map(String.init) else { return nil }
            return TGStickerPack(id: id, title: set["title"]?.stringValue ?? "", count: set["size"]?.intValue ?? 0)
        }
    }

    /// Envía el primer sticker del usuario que encaje con el emoji. Devuelve el emoji del sticker enviado.
    public func sendSticker(chatID: Int64, emoji: String, packID: String?) async throws -> String {
        try requireReady()
        var candidates: [JSONValue]
        if let packID {
            let set = try await request(["@type": "getStickerSet", "set_id": .string(packID)])
            let all = set["stickers"]?.arrayValue ?? []
            let matching = all.filter { ($0["emoji"]?.stringValue ?? "").contains(emoji) }
            candidates = matching.isEmpty ? all : matching
        } else {
            let found = try await request(["@type": "getStickers", "sticker_type": ["@type": "stickerTypeRegular"],
                                           "query": .string(emoji), "limit": 20, "chat_id": Self.number(chatID)])
            candidates = found["stickers"]?.arrayValue ?? []
        }
        guard let sticker = candidates.first, let remote = sticker["sticker"]?["remote"]?["id"]?.stringValue, !remote.isEmpty else {
            throw ToolInputError("No tienes ningún sticker para \(emoji) en tus packs.")
        }
        let message = try await request([
            "@type": "sendMessage", "chat_id": Self.number(chatID),
            "input_message_content": [
                "@type": "inputMessageSticker",
                "sticker": ["@type": "inputSticker", "sticker": ["@type": "inputFileRemote", "id": .string(remote)],
                            "width": .number(sticker["width"]?.doubleValue ?? 512),
                            "height": .number(sticker["height"]?.doubleValue ?? 512)],
                "emoji": .string(sticker["emoji"]?.stringValue ?? emoji),
            ],
        ])
        if let id = message["id"]?.intValue { try await waitForDelivery(messageID: Int64(id), timeout: 30) }
        return sticker["emoji"]?.stringValue ?? emoji
    }

    public func folders() async throws -> [TGFolder] {
        try requireReady()
        return chatFolders
    }

    public func folderChats(folderID: Int, limit: Int) async throws -> [TGUserChat] {
        try requireReady()
        let list: JSONValue = ["@type": "chatListFolder", "chat_folder_id": .number(Double(folderID))]
        // Hasta que no se cargan, getChats solo devuelve lo que TDLib ya tiene en memoria.
        _ = try? await request(["@type": "loadChats", "chat_list": list, "limit": .number(Double(limit))])
        let found = try await request(["@type": "getChats", "chat_list": list, "limit": .number(Double(limit))])
        var chats: [TGUserChat] = []
        for id in (found["chat_ids"]?.arrayValue ?? []).compactMap(\.intValue) {
            if let chat = try? await chat(id: Int64(id)) { chats.append(chat) }
        }
        return chats
    }

    public func setInFolder(chatID: Int64, folderID: Int, included: Bool) async throws {
        try requireReady()
        if included {
            _ = try await request(["@type": "addChatToList", "chat_id": Self.number(chatID),
                                   "chat_list": ["@type": "chatListFolder", "chat_folder_id": .number(Double(folderID))]])
            return
        }
        var folder = try await request(["@type": "getChatFolder", "chat_folder_id": .number(Double(folderID))]).objectValue ?? [:]
        func without(_ key: String) -> JSONValue {
            .array((folder[key]?.arrayValue ?? []).filter { $0.intValue.map(Int64.init) != chatID })
        }
        let listed = ["included_chat_ids", "pinned_chat_ids"].contains { key in
            (folder[key]?.arrayValue ?? []).contains { $0.intValue.map(Int64.init) == chatID }
        }
        folder["included_chat_ids"] = without("included_chat_ids")
        folder["pinned_chat_ids"] = without("pinned_chat_ids")
        // Si no estaba puesto a mano, entra por una categoría (contactos, grupos…): se excluye.
        if !listed {
            var excluded = folder["excluded_chat_ids"]?.arrayValue ?? []
            if !excluded.contains(where: { $0.intValue.map(Int64.init) == chatID }) { excluded.append(Self.number(chatID)) }
            folder["excluded_chat_ids"] = .array(excluded)
        }
        folder["@type"] = "chatFolder"
        folder.removeValue(forKey: "@extra")
        folder.removeValue(forKey: "@client_id")
        do {
            _ = try await request(["@type": "editChatFolder", "chat_folder_id": .number(Double(folderID)), "folder": .object(folder)])
        } catch let error as TDError where error.message.contains("at least 1 chat") {
            throw ToolInputError("Telegram no deja una carpeta vacía: es el último chat que tiene. Para quitarla entera, hazlo desde Telegram.")
        }
    }

    /// Solo para la prueba de desarrollo: borra una carpeta sin salir de sus chats.
    public func deleteFolder(id: Int) async throws {
        try requireReady()
        _ = try await request(["@type": "deleteChatFolder", "chat_folder_id": .number(Double(id)), "leave_chat_ids": []])
        chatFolders.removeAll { $0.id == id }
    }

    public func createFolder(name: String, chatIDs: [Int64]) async throws -> TGFolder {
        try requireReady()
        let created = try await request([
            "@type": "createChatFolder",
            "folder": [
                "@type": "chatFolder",
                "name": ["@type": "chatFolderName", "text": Self.formatted(name), "animate_custom_emoji": false],
                "included_chat_ids": .array(chatIDs.map(Self.number)),
                "pinned_chat_ids": [], "excluded_chat_ids": [],
            ],
        ])
        guard let id = created["id"]?.intValue else { throw ToolInputError("Telegram no ha devuelto la carpeta creada.") }
        let folder = TGFolder(id: id, name: created["name"]?["text"]?["text"]?.stringValue ?? name)
        if !chatFolders.contains(where: { $0.id == id }) { chatFolders.append(folder) }
        return folder
    }
}
