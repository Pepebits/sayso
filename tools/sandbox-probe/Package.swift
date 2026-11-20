// swift-tools-version: 5.9
import PackageDescription

// App de prueba, aparte de SaySo: comprueba qué funciones de SaySo siguen funcionando dentro del
// App Sandbox que exige la Mac App Store. No forma parte de la app.
let package = Package(
    name: "SandboxProbe",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "SandboxProbe", path: "Sources/SandboxProbe")]
)
