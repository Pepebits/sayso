import Foundation
import SaySoCore

/// Crea el proveedor de una cuenta leyendo su clave del Llavero.
public enum ProviderFactory {
    public static func make(account: ProviderAccount, vault: SecretVault,
                            transport: HTTPTransport = URLSessionTransport()) throws -> ModelProvider {
        var key: String?
        if let name = account.keychainKey {
            key = try vault.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if key?.isEmpty ?? true { throw ProviderError.missingKey(account.name) }
        }
        switch account.kind {
        case .anthropic:
            guard let key else { throw ProviderError.missingKey(account.name) }
            return AnthropicProvider(apiKey: key, baseURL: account.baseURL, fullModel: account.fullModel,
                                     fastModel: account.fastModel, transport: transport)
        case .openAICompatible:
            return OpenAICompatibleProvider(baseURL: account.baseURL, apiKey: key, fullModel: account.fullModel,
                                            fastModel: account.fastModel, transport: transport,
                                            supportsImages: account.seesImages)
        }
    }
}
