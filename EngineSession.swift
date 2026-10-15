import Foundation
import Darwin

/// A private pipe per worker keeps commands scoped to this controller instance.
/// EOF also guarantees that a worker cannot outlive a crashed controller.
final class EngineSession {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let reader = DispatchQueue(label: "windowinterp.worker.events")
    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var stopping = false

    var pid: Int32 { process.processIdentifier }

    func start(executable: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("LSFGM_") || key == "DYLD_INSERT_LIBRARIES" || key == "WINDOW_INTERP_BOOT" {
            env.removeValue(forKey: key)
        }
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { [weak self] in self?.onExit?(process.terminationStatus) }
        }
        try process.run()
        // The parent must close its extra write end or the reader never sees EOF.
        try? output.fileHandleForWriting.close()
        reader.async { [weak self, handle = output.fileHandleForReading] in
            var pending = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let end = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: end)
                    pending.removeSubrange(...end)
                    guard line.starts(with: Data("WI_EVENT ".utf8)),
                          let event = try? JSONSerialization.jsonObject(with: line.dropFirst(9)) as? [String: Any] else {
                        if let text = String(data: line, encoding: .utf8) {
                            DispatchQueue.main.async { [weak self] in self?.onDiagnostic?(text) }
                        }
                        continue
                    }
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
                }
                // Non-protocol diagnostic output is bounded even if malformed.
                if pending.count > 64 * 1024 { pending.removeAll(keepingCapacity: true) }
            }
            try? handle.close()
        }
    }

    func send(_ command: [String: Any]) {
        guard !stopping, process.isRunning,
              var data = try? JSONSerialization.data(withJSONObject: command) else { return }
        data.append(10)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        guard !stopping else { return }
        send(["command": "stop"])
        stopping = true
        try? input.fileHandleForWriting.close()
        // Bound shutdown if an engine is blocked in present. Never block the UI.
        let process = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

func emitWorkerEvent(_ event: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: event),
          let text = String(data: data, encoding: .utf8) else { return }
    try? FileHandle.standardOutput.write(contentsOf: Data(("WI_EVENT " + text + "\n").utf8))
}

func readWorkerCommands(_ receive: @escaping ([String: Any]) -> Void) {
    DispatchQueue(label: "windowinterp.worker.commands").async {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            DispatchQueue.main.async { receive(command) }
        }
        DispatchQueue.main.async { receive(["command": "stop"]) }
    }
}
