import Foundation
import SaySoCore
import XCTest
@testable import SaySoVM

final class GuestProtocolTests: XCTestCase {
    func testFrameCarriesBigEndianLength() throws {
        let frame = try GuestFraming.encode(GuestRequest.exec("ls", cwd: "repo", timeout: 30))
        let length = try GuestFraming.bodyLength(header: frame.prefix(4))
        XCTAssertEqual(length, frame.count - 4)
        let decoded = try JSONDecoder().decode(GuestRequest.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded, .exec("ls", cwd: "repo", timeout: 30))
    }

    func testRejectsOversizedAndShortHeaders() {
        XCTAssertThrowsError(try GuestFraming.bodyLength(header: Data([0xFF, 0xFF, 0xFF, 0xFF])))
        XCTAssertThrowsError(try GuestFraming.bodyLength(header: Data([0, 1])))
    }

    func testDecodesExecAndStatsResponses() throws {
        let exec = try JSONDecoder().decode(GuestResponse.self, from: Data(
            #"{"ok":true,"exit":2,"stdout":"a","stderr":"b","timed_out":true}"#.utf8))
        XCTAssertEqual(exec.commandResult?.exitCode, 2)
        XCTAssertEqual(exec.commandResult?.timedOut, true)
        XCTAssertNil(exec.stats)

        let stats = try JSONDecoder().decode(GuestResponse.self, from: Data(
            #"{"ok":true,"cpu":12.5,"cpus":2,"mem_total":4000,"mem_used":1000,"disk_total":16000,"disk_used":2000}"#.utf8))
        XCTAssertEqual(stats.stats?.cpuCount, 2)
        XCTAssertEqual(stats.stats?.memoryUsed, 1000)
        XCTAssertNil(stats.commandResult)
    }

    func testRoundTripOverSocketPair() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let server = Thread {
            guard let header = try? GuestFraming.readExactly(4, from: fds[1]),
                  let length = try? GuestFraming.bodyLength(header: header),
                  let body = try? GuestFraming.readExactly(length, from: fds[1]),
                  let request = try? JSONDecoder().decode(GuestRequest.self, from: body) else { return }
            let reply = GuestResponse(ok: true, exit: 0, stdout: request.command)
            try? GuestFraming.writeAll(try! GuestFraming.encode(reply), to: fds[1])
        }
        server.start()
        let response = try GuestFraming.roundTrip(.exec("echo hola", timeout: 5), fd: fds[0])
        XCTAssertEqual(response.stdout, "echo hola")
    }

    func testClosedConnectionThrows() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        close(fds[1])
        defer { close(fds[0]) }
        XCTAssertThrowsError(try GuestFraming.readExactly(4, from: fds[0]))
    }

    func testCloudInitSeedInstallsTheGuestAgent() {
        let userData = GuestAgent.userData
        XCTAssertTrue(userData.hasPrefix("#cloud-config\n"))
        XCTAssertTrue(userData.contains("/usr/local/bin/sayso-guest"))
        XCTAssertTrue(userData.contains(Data(GuestAgent.script.utf8).base64EncodedString()))
        XCTAssertTrue(GuestAgent.script.contains("PORT = \(guestAgentPort)"))
        XCTAssertTrue(GuestAgent.metaData.hasPrefix("instance-id: sayso-"))
        // La carpeta de trabajo es ~/sayso y lo que hubiera en la antigua ~/work se migra.
        XCTAssertTrue(GuestAgent.script.contains(#"WORK = os.path.join(HOME, "sayso")"#))
        XCTAssertTrue(GuestAgent.script.contains("os.rename(OLD_WORK, WORK)"))
        XCTAssertTrue(userData.contains("/home/agent/sayso"))
        // La red no puede depender de la MAC del primer arranque.
        XCTAssertTrue(GuestAgent.networkConfig.contains("name: \"en*\""))
        XCTAssertFalse(GuestAgent.networkConfig.contains("macaddress"))
    }

    /// El agente invitado es Python: al menos debe compilar con el intérprete del Mac.
    func testGuestScriptIsValidPython() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sayso-guest-\(UUID().uuidString).py")
        try Data(GuestAgent.script.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())", file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testSpawnAndEnvironmentAreEncoded() throws {
        let spawn = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GuestRequest.spawn("srv", env: ["A": "1"]))) as? [String: Any]
        XCTAssertEqual(spawn?["op"] as? String, "spawn")
        XCTAssertEqual(spawn?["env"] as? [String: String], ["A": "1"])
        let exec = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GuestRequest.exec("ls", timeout: 5))) as? [String: Any]
        XCTAssertNil(exec?["env"])
        XCTAssertTrue(GuestAgent.script.contains("def do_spawn"))
    }

    func testReadSomeReturnsAvailableBytesAndEmptyOnClose() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        try GuestFraming.writeAll(Data("hola\n".utf8), to: fds[1])
        XCTAssertEqual(try GuestFraming.readSome(from: fds[0]), Data("hola\n".utf8))
        close(fds[1])
        XCTAssertTrue(try GuestFraming.readSome(from: fds[0]).isEmpty)
        close(fds[0])
    }

    /// El instalador del escritorio es bash: debe pasar la comprobación de sintaxis y dejar la
    /// sesión del agente con inicio automático.
    func testDesktopInstallScriptIsValidBash() throws {
        let script = DesktopSetup.installScript
        XCTAssertTrue(script.contains("autologin-user=agent"))
        XCTAssertTrue(script.contains("--no-install-recommends"))
        XCTAssertTrue(script.contains("desktop-ok"))
        // El escritorio no queda encendido de fondo: arranca con su ventana.
        XCTAssertTrue(script.contains("set-default multi-user.target"))
        XCTAssertFalse(script.contains("systemctl restart lightdm"))
        XCTAssertTrue(DesktopSetup.startScript.contains("systemctl start lightdm"))
        XCTAssertTrue(GuestAgent.userData.contains("systemctl set-default multi-user.target"))
        XCTAssertTrue(GuestAgent.userData.contains("disable --now ssh.service"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", "-c", script]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
