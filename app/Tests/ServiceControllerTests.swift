import Foundation
import Darwin

@main
struct ServiceControllerTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = directory.appendingPathComponent("gate")
        precondition(mkfifo(gate.path, 0o600) == 0)
        let script = directory.appendingPathComponent("helper.py")
        try """
        import os, signal
        from pathlib import Path
        def terminate(*_):
            with open(os.environ['TEST_RESTART_GATE'], 'rb') as stream:
                stream.read(1)
            raise SystemExit(0)
        signal.signal(signal.SIGTERM, terminate)
        Path(os.environ['TEST_RESTART_READY']).touch()
        while True:
            signal.pause()
        """.write(to: script, atomically: true, encoding: .utf8)
        let ready = directory.appendingPathComponent("ready")
        let controller = ServiceController(serviceURL: script, configURL: directory.appendingPathComponent("config"),
            logURL: directory.appendingPathComponent("log"), servicePort: 0,
            onFailure: { _ in preconditionFailure("Helper unexpectedly failed") }, onStaleHelperStopped: { _ in })
        controller.environment = ["TEST_RESTART_GATE": gate.path, "TEST_RESTART_READY": ready.path]
        let descriptor = open(directory.path, O_EVTONLY)
        precondition(descriptor >= 0)
        let changes = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        changes.setCancelHandler { close(descriptor) }
        defer { changes.cancel() }
        var started = 0
        var restarted = false
        var first: Process?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.onStarted = {
                started += 1
                if started == 1 { first = controller.process }
                if started == 2 {
                    precondition(first?.isRunning == false)
                    precondition(controller.process !== first)
                    continuation.resume()
                }
            }
            changes.setEventHandler {
                guard !restarted, FileManager.default.fileExists(atPath: ready.path) else { return }
                restarted = true
                controller.restart()
                // The old process is blocked in cleanup until the test releases its FIFO.
                precondition(controller.process === first)
                precondition(started == 1)
                DispatchQueue.global().async {
                    let writer = try! FileHandle(forWritingTo: gate)
                    try! writer.write(contentsOf: Data([1]))
                    try! writer.close()
                }
            }
            changes.resume()
            controller.start()
        }
        controller.process?.interrupt()
        controller.process?.waitUntilExit()
        controller.stop()
        print("ServiceControllerTests: PASS")
    }
}
