import Foundation
import Darwin

@main struct SessionChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func spin(seconds: Double, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--fixture") {
            require(getenv("LSFGM_TEST_POLLUTION") == nil, "engine env must be isolated")
            let output = FileHandle.standardOutput
            try output.write(contentsOf: Data("noise\nWI_EV".utf8))
            try output.write(contentsOf: Data("ENT {\"event\":\"ready\"}\nWI_EVENT {\"event\":\"second\"}\n".utf8))
            if CommandLine.arguments.contains("--stubborn") {
                signal(SIGTERM, SIG_IGN)
            } else {
                readWorkerCommands { command in
                    if command["command"] as? String == "stop" { exit(0) }
                    emitWorkerEvent(["event": "ack", "value": command["value"] ?? ""])
                }
            }
            RunLoop.main.run()
            return
        }
        setenv("LSFGM_TEST_POLLUTION", "must-not-leak", 1)
        let session = EngineSession()
        var events: [[String: Any]] = []
        var exitCode: Int32?
        session.onEvent = { events.append($0) }
        session.onExit = { exitCode = $0 }
        try session.start(executable: CommandLine.arguments[0], arguments: ["--fixture"])
        spin(seconds: 3) { events.count == 2 }
        require(events.map { $0["event"] as? String } == ["ready", "second"], "fragmented/batched framing")
        session.send(["command": "echo", "value": "中文 + \\ \n"])
        spin(seconds: 3) { events.count == 3 }
        require(events.last?["value"] as? String == "中文 + \\ \n", "JSON command round trip")
        session.stop(); session.stop()
        spin(seconds: 3) { exitCode != nil }
        require(exitCode == 0, "graceful idempotent shutdown")
        print("PASS framing, environment isolation, JSON round trip, graceful stop")
        let stubborn = EngineSession()
        var killed: Int32?
        var ready = false
        stubborn.onEvent = { _ in ready = true }
        stubborn.onExit = { killed = $0 }
        try stubborn.start(executable: CommandLine.arguments[0], arguments: ["--fixture", "--stubborn"])
        spin(seconds: 3) { ready }
        require(ready, "stubborn worker startup")
        // Fill a pipe whose reader is hung. Sending settings must never freeze the UI/runloop.
        let sentAt = Date()
        stubborn.send(["command": "quality", "value": String(repeating: "x", count: 512 * 1024)])
        require(Date().timeIntervalSince(sentAt) < 0.5, "full worker pipe blocked the main thread")
        stubborn.stop()
        spin(seconds: 6) { killed != nil }
        require(killed == SIGKILL, "bounded shutdown of hung engine")
        print("PASS full pipe stays responsive; hung engine reaped without blocking main thread")
    }
}
