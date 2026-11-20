import SaySoCore
@testable import SaySoVM
import XCTest

/// Proceso falso que se comporta como el bash de la sesión: guarda lo escrito y devuelve las
/// líneas que el test le prepara.
final class ScriptedShell: ProcessStream, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data?] = []
    private(set) var written: [String] = []
    private(set) var closed = false
    /// Dado lo que se escribe, las líneas de salida (sin la marca final).
    var reply: (String) -> (lines: [String], exit: Int32, directory: String)? = { _ in ([], 0, "/home/agent/sayso") }

    func write(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        lock.lock(); defer { lock.unlock() }
        written.append(text)
        guard let marker = text.components(separatedBy: " ").first(where: { $0.hasPrefix("__SAYSO_FIN_") }) else { return }
        guard let answer = reply(text) else { queue.append(nil); return }
        for line in answer.lines { queue.append(Data(line.utf8)) }
        queue.append(Data())
        queue.append(Data("\(marker) \(answer.exit) \(answer.directory)".utf8))
    }

    func readLine(timeout: TimeInterval) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    func close() { lock.lock(); closed = true; lock.unlock() }
}

final class ShellComputer: AgentComputer, @unchecked Sendable {
    let shell = ScriptedShell()
    private(set) var opened = 0
    func run(_ command: String, cwd: String?, timeout: TimeInterval, env: [String: String], origin: String?) async throws -> CommandResult {
        CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
    func openProcess(_ command: String, env: [String: String], origin: String?) async throws -> ProcessStream {
        opened += 1
        return shell
    }
    func readFile(_ path: String, origin: String?) async throws -> String { "" }
    func writeFile(_ path: String, content: String, origin: String?) async throws {}
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class ConsoleSessionTests: XCTestCase {
    func testScriptKeepsTheShellAliveAndReportsExitAndDirectory() {
        let script = ConsoleSession.script(for: "cd /tmp", nonce: "abc")
        XCTAssertTrue(script.hasPrefix("{ cd /tmp\n} </dev/null\n"), "en el mismo shell y sin entrada de teclado")
        XCTAssertTrue(script.contains("__SAYSO_FIN_abc__"))
        XCTAssertEqual(ConsoleSession.parseEnd("__SAYSO_FIN_abc__ 2 /home/agent/sayso/app", nonce: "abc"),
                       ConsoleSession.Finished(exitCode: 2, directory: "~/sayso/app"))
        XCTAssertNil(ConsoleSession.parseEnd("__SAYSO_FIN_otro__ 0 /tmp", nonce: "abc"), "la salida no puede imitar la marca")
        XCTAssertNil(ConsoleSession.parseEnd("salida normal", nonce: "abc"))
    }

    func testOutputArrivesLineByLineAndDirectoryIsRemembered() async throws {
        let computer = ShellComputer()
        computer.shell.reply = { text in
            text.contains("npm test") ? (["✓ 42 tests", "", "hecho"], 0, "/home/agent/sayso/weather") : ([], 1, "/tmp")
        }
        let console = ConsoleSession(computer: computer)
        let lines = Lines()
        let first = try await console.run("npm test") { lines.add($0) }
        XCTAssertEqual(lines.all, ["✓ 42 tests", "", "hecho"], "las líneas en blanco del comando se conservan; la de la marca no")
        XCTAssertEqual(first, ConsoleSession.Finished(exitCode: 0, directory: "~/sayso/weather"))
        let second = try await console.run("false") { _ in }
        XCTAssertEqual(second.exitCode, 1)
        let directory = await console.directory
        XCTAssertEqual(directory, "/tmp")
        XCTAssertEqual(computer.opened, 1, "la misma sesión para los dos comandos")
    }

    func testClosedSessionReopensOnTheNextCommand() async throws {
        let computer = ShellComputer()
        let console = ConsoleSession(computer: computer)
        computer.shell.reply = { _ in nil } // el proceso muere
        do {
            _ = try await console.run("exit") { _ in }
            XCTFail("debía avisar de que se cerró")
        } catch { XCTAssertTrue(error is ConsoleSession.Failure) }
        XCTAssertTrue(computer.shell.closed)
        computer.shell.reply = { _ in (["hola"], 0, "/home/agent/sayso") }
        let again = try await console.run("echo hola") { _ in }
        XCTAssertEqual(again.directory, "~/sayso")
        XCTAssertEqual(computer.opened, 2)
    }

    func testConsoleTextCleaning() {
        XCTAssertEqual(ConsoleText.clean("\u{1B}[32m✓\u{1B}[0m ok"), "✓ ok")
        XCTAssertEqual(ConsoleText.clean("10%\r50%\r100% listo"), "100% listo")
        XCTAssertEqual(ConsoleText.shortDirectory("/home/agent"), "~")
        XCTAssertEqual(ConsoleText.shortDirectory("/home/agent/sayso/x"), "~/sayso/x")
        XCTAssertEqual(ConsoleText.shortDirectory("/tmp"), "/tmp")
    }
}
