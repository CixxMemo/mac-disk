import Foundation

public enum ReportCodec {
    public static func decode(_ data: Data) throws -> Report {
        try JSONDecoder().decode(Report.self, from: data)
    }

    public static func encode(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
