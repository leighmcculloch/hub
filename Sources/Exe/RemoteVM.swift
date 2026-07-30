import Foundation

/// What a VM says about itself, asked over the session's own SSH connection.
///
/// Needed because a VM can rename itself — see `AutoName` — and a rename leaves
/// the account listing with nothing to match the old name against: `ls` returns
/// the new name, and no field ties it to the one the app remembers. The machine
/// is the only party that knows it is both.
enum RemoteVM {
    /// How often the app asks. A rename happens once, seconds after the agent's
    /// first prompt, so this is about noticing it soon rather than instantly.
    static let pollInterval: Duration = .seconds(10)

    /// The reflection integration — attached to every VM on an account by
    /// default — publishes the VM's current name at the top level of its index.
    static let nameCommand = "curl -fsS --max-time 5 https://reflection.int.exe.xyz/"

    static func parseName(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    /// The VM's current name, or nil if it couldn't be asked.
    ///
    /// Runs over the multiplexed connection the terminal already holds (see
    /// `RemoteGit`), which is also why it keeps answering after a rename: the
    /// old hostname has stopped resolving, but the open connection hasn't.
    static func name(destination: String) async -> String? {
        guard let output = await RemoteGit.run(
            destination: destination, remoteCommand: nameCommand)
        else { return nil }
        return parseName(output)
    }

    /// A VM's SSH host follows its name, so a rename moves the destination.
    static func destination(forName name: String) -> String {
        "\(name).exe.xyz"
    }
}
