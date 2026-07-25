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
}
