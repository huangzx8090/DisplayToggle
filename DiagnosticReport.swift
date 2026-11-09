import Foundation

struct DisplayDiagnostic: Encodable {
    let index: Int
    let builtin: Bool
    let online: Bool
    let active: Bool
    let asleep: Bool
    let width: Int
    let height: Int
    let mirrored: Bool
    let exclusionReason: String?
}

struct DiagnosticReport: Encodable {
    let schemaVersion = 1
    let capturedAt: Date
    let appVersion: String
    let operatingSystem: String
    let displays: [DisplayDiagnostic]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
