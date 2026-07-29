import Foundation

/// One `KEY=VALUE` pair set on the VM host at creation time.
struct EnvVar: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""

    init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }

    /// `id` is generated when absent so the config file can be hand-edited with
    /// just `{"key": ..., "value": ...}` entries.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    /// Combine several sources of variables, later lists winning on a shared
    /// key. Nameless rows are dropped, since they can't be set on the VM.
    ///
    /// Order is the point: the model configuration has to be able to blank a
    /// token the environment sets, and passing the same key to exe.dev twice
    /// leaves which one wins up to exe.dev.
    static func merged(_ lists: [[EnvVar]]) -> [EnvVar] {
        var merged: [EnvVar] = []
        for variable in lists.flatMap({ $0 }) where !variable.key.isEmpty {
            if let index = merged.firstIndex(where: { $0.key == variable.key }) {
                merged[index].value = variable.value
            } else {
                merged.append(variable)
            }
        }
        return merged
    }
}
