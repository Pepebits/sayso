// swift-tools-version: 6.0
import PackageDescription

// SaySo — agente de IA para el Mac con dictado global.
// Estructura de módulos: ver docs/PLAN.md y docs/adr/.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SaySo",
    defaultLocalization: "es",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SaySo", targets: ["SaySoApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
        // Binario oficial de TDLib empaquetado como xcframework. Versión fijada: cada etiqueta es una
        // compilación concreta de TDLib.
        .package(url: "https://github.com/Swiftgram/TDLibFramework.git", exact: "1.8.70-fe61d641"),
    ],
    targets: [
        // Contratos y modelos compartidos. Sin dependencias.
        .target(name: "SaySoCore", swiftSettings: swift5),
        // SQLite: reglas, registro, memoria, ajustes, conversaciones (ADR-0010).
        .target(
            name: "SaySoStore",
            dependencies: ["SaySoCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: swift5
        ),
        // Motor de permisos, scripts del Mac, Llavero y redacción (ADR-0007, ADR-0008).
        .target(name: "SaySoPermissions", dependencies: ["SaySoCore"], swiftSettings: swift5),
        // Proveedores de IA, bucle del agente y bot de Telegram (ADR-0005, ADR-0006).
        .target(name: "SaySoAgent", dependencies: ["SaySoCore"], swiftSettings: swift5),
        // Atajo global, audio, transcripción e inserción de texto (ADR-0003).
        .target(
            name: "SaySoDictation",
            dependencies: ["SaySoCore", .product(name: "WhisperKit", package: "WhisperKit")],
            swiftSettings: swift5
        ),
        // Máquina Linux del agente con Virtualization.framework (ADR-0004).
        .target(name: "SaySoVM", dependencies: ["SaySoCore"], swiftSettings: swift5),
        // Sesión de usuario de Telegram con TDLib, opcional (ADR-0006).
        .target(
            name: "SaySoTDLib",
            dependencies: ["SaySoCore", "SaySoAgent", .product(name: "TDLibFramework", package: "TDLibFramework")],
            swiftSettings: swift5
        ),
        // Sistema de diseño y pantallas de ajustes. Solo depende de Core.
        .target(name: "SaySoUI", dependencies: ["SaySoCore"], swiftSettings: swift5),
        // Ejecutable: une todos los módulos.
        .executableTarget(
            name: "SaySoApp",
            dependencies: [
                "SaySoCore", "SaySoStore", "SaySoPermissions", "SaySoAgent", "SaySoDictation", "SaySoVM", "SaySoTDLib",
                "SaySoUI",
            ],
            swiftSettings: swift5
        ),
        .testTarget(name: "SaySoStoreTests", dependencies: ["SaySoStore"], swiftSettings: swift5),
        .testTarget(name: "SaySoPermissionsTests", dependencies: ["SaySoPermissions"], swiftSettings: swift5),
        .testTarget(name: "SaySoAgentTests", dependencies: ["SaySoAgent"], swiftSettings: swift5),
        .testTarget(name: "SaySoVMTests", dependencies: ["SaySoVM"], swiftSettings: swift5),
        .testTarget(name: "SaySoTDLibTests", dependencies: ["SaySoTDLib"], swiftSettings: swift5),
        .testTarget(name: "SaySoUITests", dependencies: ["SaySoUI"], swiftSettings: swift5),
        .testTarget(name: "SaySoDictationTests", dependencies: ["SaySoDictation"], swiftSettings: swift5),
    ]
)
