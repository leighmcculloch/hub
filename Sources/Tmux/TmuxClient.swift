import Foundation

/// Runs tmux's control-mode client for one VM: an `ssh` process whose remote
/// command is `tmux -C`, with the protocol on its standard streams.
///
/// It owns the process and the byte plumbing only — the parsing is
/// `TmuxControlParser`, and what the events *mean* is the session's business.
/// Events are delivered on the main queue, in batches, because a busy pane
/// produces thousands of tiny `%output` lines and one hop per line would swamp
/// the main queue with scheduling.
final class TmuxClient {
    /// Every event from one read, in order.
    private let onEvents: ([TmuxEvent]) -> Void
    /// The process ended. `message` is ssh's or tmux's complaint, when they made
    /// one — a VM that is gone, or a tmux that failed to install.
    private let onExit: (_ message: String?) -> Void

    private let destination: String
    private let remoteCommand: String

    private var process: Process?
    private var stdin: FileHandle?
    /// Held only so the read handlers can be detached on stop.
    private var readers: [FileHandle] = []
    private let writeQueue = DispatchQueue(label: "tmux.control.write")
    private var parser = TmuxControlParser()
    private var lineBuffer = TmuxLineBuffer()
    /// Everything ssh/tmux wrote to stderr, kept for the exit message.
    private var errorOutput = Data()

    init(
        destination: String,
        remoteCommand: String,
        onEvents: @escaping ([TmuxEvent]) -> Void,
        onExit: @escaping (String?) -> Void
    ) {
        self.destination = destination
        self.remoteCommand = remoteCommand
        self.onEvents = onEvents
        self.onExit = onExit
    }

    /// SSH arguments for the control-mode client.
    ///
    /// No `-t`: the protocol is a byte stream on stdout, and a remote tty would
    /// only translate it. (`tmux -CC`, the interactive spelling, insists on one
    /// — plain `-C` is the spelling for a program driving tmux.) The
    /// ControlMaster options are shared with `RemoteGit`, so the diff sidebar's
    /// git calls ride on this same connection.
    static func sshArguments(destination: String, remoteCommand: String) -> [String] {
        RemoteGit.sshControlArgs(for: destination) + [
            "-o", "ConnectTimeout=15",
            "-o", "ConnectionAttempts=10", // retry while the VM finishes booting
            "-o", "ServerAliveInterval=30",
            destination,
            remoteCommand,
        ]
    }

    func start() {
        stop()
        parser = TmuxControlParser()
        lineBuffer = TmuxLineBuffer()
        errorOutput = Data()

        // Writing to tmux after it has gone away must fail, not kill the app;
        // the process can exit between a keystroke and the write that carries
        // it. Foundation's throwing write still gets SIGPIPE'd without this.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.sshArguments(
            destination: destination, remoteCommand: remoteCommand)

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.read(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { [weak self] in self?.errorOutput.append(data) }
        }
        process.terminationHandler = { [weak self] process in
            let exitCode = process.terminationStatus
            DispatchQueue.main.async { [weak self] in self?.finish(exitCode: exitCode) }
        }

        do {
            try process.run()
        } catch {
            onExit("Couldn't run ssh: \(error.localizedDescription)")
            return
        }
        self.process = process
        stdin = input.fileHandleForWriting
        readers = [output.fileHandleForReading, errors.fileHandleForReading]
    }

    /// Send one tmux command. One per call: tmux replies with a block per
    /// command, and callers pair replies with commands by position.
    ///
    /// Written on a serial queue, which keeps the commands in the order they
    /// were made without a large paste — megabytes of `send-keys` — blocking the
    /// main thread on a pipe that tmux hasn't drained yet.
    func send(_ command: String) {
        guard let stdin, process?.isRunning == true else { return }
        writeQueue.async {
            try? stdin.write(contentsOf: Data((command + "\n").utf8))
        }
    }

    func stop() {
        stdin = nil
        for reader in readers { reader.readabilityHandler = nil }
        readers = []
        guard let process else { return }
        self.process = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Parse what was read. Runs on the reader's queue; only the delivery of the
    /// events hops to main.
    private func read(_ data: Data) {
        let events = lineBuffer.lines(from: data).compactMap { parser.consume(line: $0) }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onEvents(events) }
    }

    private func finish(exitCode: Int32) {
        guard process != nil else { return } // already stopped deliberately
        process = nil
        stdin = nil
        let stderr = String(data: errorOutput, encoding: .utf8) ?? ""
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : RemoteGit.summarize(stderr: stderr, exitCode: exitCode)
        onExit(message)
    }
}
