import SaySoCore
import SwiftUI

/// Inicio de sesión con la cuenta del usuario (TDLib) para que el agente pueda leer y escribir
/// en sus chats (ADR-0006). Es opcional; el bot funciona sin esto.
struct TelegramUserSection: View {
    let model: AppModel
    /// Con la sesión iniciada, se pinta como un panel suelto para ir al lado del bot.
    var asPanel = false
    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirmingLogout = false

    var body: some View {
        Group {
            if asPanel, case let .ready(name) = model.telegramUser {
                readyPanel(name)
            } else {
                section
            }
        }
        .confirmationDialog("¿Cerrar la sesión de Telegram en SaySo?", isPresented: $confirmingLogout) {
            Button("Cerrar sesión", role: .destructive) { model.actions?.disconnectTelegramUser() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borran los datos de tus chats guardados en este Mac. El bot sigue funcionando.")
        }
    }

    private func readyPanel(_ name: String) -> some View {
        Panel(fill: true) {
            HStack(alignment: .top) {
                PanelLabel("Tu cuenta")
                Spacer(minLength: 4)
                StatusTag("Conectado", kind: .active)
            }
            HStack(spacing: Theme.Space.m) {
                AccountPhoto(url: model.telegramUserPhoto, size: 36)
                Text(verbatim: name.isEmpty ? tr("Sesión iniciada") : name)
                    .font(Theme.display(17))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            Text(tr("El agente puede leer y escribir en tus chats según las reglas de abajo. Los chats secretos y los códigos de acceso quedan siempre fuera."))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            CardDivider()
            HStack {
                MonoTag(text: tr("opcional"))
                Spacer(minLength: 0)
                BlockButton("Cerrar sesión", kind: .destructive, compact: true) { confirmingLogout = true }
                    .accessibilityLabel(tr("Cerrar la sesión de tu cuenta de Telegram"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var section: some View {
        SettingsSection("Tus chats",
                        footer: "Opcional. Con tu cuenta, el agente puede resumir lo que te has perdido y preparar respuestas. Los chats secretos y los códigos de acceso quedan siempre fuera, y enviar o borrar pide confirmación.") {
            SettingsCard {
                switch model.telegramUser {
                case .off:
                    credentials
                case .connecting:
                    SettingRow(icon: "person.crop.circle", title: "Conectando con Telegram") {
                        ProgressView().controlSize(.small)
                    }
                case .waitingPhone:
                    step(title: "Tu número de teléfono",
                         detail: "Con prefijo internacional. Telegram te enviará un código.") {
                        BlockField("+34 600 000 000", text: $phone, mono: true, label: "Número de teléfono")
                            .onSubmit(sendPhone)
                        BlockButton("Continuar", kind: .primary, action: sendPhone)
                            .disabled(phone.trimmingCharacters(in: .whitespaces).count < 6)
                    }
                case let .waitingCode(hint):
                    step(title: "Código de inicio de sesión", detail: hint) {
                        BlockField("12345", text: $code, mono: true, label: "Código de inicio de sesión")
                            .onSubmit(sendCode)
                        BlockButton("Continuar", kind: .primary, action: sendCode)
                            .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
                    }
                case let .waitingPassword(hint):
                    step(title: "Verificación en dos pasos",
                         detail: hint.isEmpty ? tr("Escribe la contraseña de tu cuenta de Telegram.") : tr("Pista: %@", hint)) {
                        BlockField("Contraseña", text: $password, secure: true, label: "Contraseña de verificación en dos pasos")
                            .onSubmit(sendPassword)
                        BlockButton("Entrar", kind: .primary, action: sendPassword)
                            .disabled(password.isEmpty)
                    }
                case let .ready(name):
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        AccountPhoto(url: model.telegramUserPhoto, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: name.isEmpty ? tr("Sesión iniciada") : name)
                                .font(Theme.bodyStrong)
                                .foregroundStyle(Theme.ink)
                            Text(tr("El agente puede usar tus chats según las reglas de permisos de Telegram."))
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        StatusTag("Conectado", kind: .active)
                        BlockButton("Cerrar sesión", kind: .destructive, compact: true) { confirmingLogout = true }
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                    .accessibilityElement(children: .contain)
                case let .failed(message):
                    SettingRow(icon: "exclamationmark.triangle", title: "No se pudo iniciar sesión", detail: message) {
                        BlockButton("Empezar de nuevo", compact: true) { model.actions?.disconnectTelegramUser() }
                    }
                }
            }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Iniciar sesión con tu cuenta")
                .font(Theme.bodyStrong)
                .foregroundStyle(Theme.ink)
            Text("Telegram exige que cada app tenga sus propias credenciales. Entra en my.telegram.org, abre «API development tools», crea una app y copia aquí su api_id y su api_hash.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Theme.Space.m) {
                LabeledField("api_id", placeholder: "1234567", text: $apiID, mono: true)
                    .frame(maxWidth: 160)
                LabeledField("api_hash", placeholder: "0123456789abcdef…", text: $apiHash, secure: true, mono: true)
            }
            HStack {
                InlineNote("El api_hash se guarda en el Llavero. Automatizar una cuenta personal puede hacer que Telegram la limite.",
                           systemImage: "exclamationmark.triangle")
                BlockButton("Continuar", kind: .primary) {
                    model.actions?.connectTelegramUser(apiID: apiID, apiHash: apiHash)
                    apiHash = ""
                }
                .disabled(Int(apiID.trimmingCharacters(in: .whitespaces)) == nil || apiHash.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.l)
    }

    private func step<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(title)).font(Theme.bodyStrong).foregroundStyle(Theme.ink)
                Text(tr(detail))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.s) {
                content()
                BlockButton("Cancelar") { model.actions?.disconnectTelegramUser() }
            }
        }
        .padding(Theme.Space.l)
    }

    private func sendPhone() {
        model.actions?.submitTelegramUserPhone(phone)
    }

    private func sendCode() {
        model.actions?.submitTelegramUserCode(code)
        code = ""
    }

    private func sendPassword() {
        model.actions?.submitTelegramUserPassword(password)
        password = ""
    }
}

/// Foto de la cuenta en un cuadrado de esquinas casi rectas, como el resto de bloques. Sin foto,
/// el icono genérico.
struct AccountPhoto: View {
    var url: URL?
    var size: CGFloat = 36

    var body: some View {
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
                .accessibilityLabel(tr("Foto de la cuenta"))
        } else {
            IconTile("person.crop.circle", size: size)
        }
    }
}

