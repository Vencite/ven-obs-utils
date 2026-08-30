import Foundation

enum StaleHelperCleanup {
    static func terminateManagedHelperListening(on port: Int, configURL: URL) -> Int32? {
        guard let output = commandOutput(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]
        ) else {
            return nil
        }

        for line in output.split(whereSeparator: \.isNewline) {
            let pidText = String(line).trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidText) else { continue }
            guard let command = commandOutput(
                executable: "/bin/ps",
                arguments: ["-p", String(pid), "-o", "command="]
            ), isManagedHelper(command: command, configURL: configURL) else {
                continue
            }

            _ = commandOutput(executable: "/bin/kill", arguments: ["-TERM", String(pid)])
            for _ in 0..<10 where processExists(pid) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return pid
        }

        return nil
    }

    static func isManagedHelper(command: String, configURL: URL) -> Bool {
        guard command.contains("ontime_break_sync.py") else { return false }

        let path = configURL.path
        return [
            "--config \(path)",
            "--config '\(path)'",
            "--config \"\(path)\"",
        ].contains { command.contains($0) }
    }

    private static func processExists(_ pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-0", String(pid)]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func commandOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
