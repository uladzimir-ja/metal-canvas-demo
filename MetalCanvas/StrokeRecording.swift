import Foundation

/// Strokes as recorded input, enough to reproduce the same stamps on any device.
struct StrokeRecording: Codable {
    var version = 1
    var canvasSize: Int
    var strokes: [RecordedStroke]
}

struct RecordedStroke: Codable {
    var brush: Brush                // snapshot: the preset may change later
    var color: SIMD3<Float>
    var canvasPixelsPerPoint: Float // brush size (points) -> canvas pixels at stroke start; differs per screen
    var samples: [InputSample]      // real samples only, no predictions
}

/// JSON files in the app's Documents folder (visible in the Files app and Finder).
enum RecordingStore {
    static func save(_ recording: StrokeRecording) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let url = documents.appendingPathComponent("Strokes \(formatter.string(from: Date())).json")
        try JSONEncoder().encode(recording).write(to: url, options: .atomic)
        return url
    }

    /// Most recently modified recording, if any.
    static func latest() throws -> StrokeRecording? {
        let files = try FileManager.default.contentsOfDirectory(at: documents,
                                                                includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
        let newest = files.max { modificationDate($0) < modificationDate($1) }
        return try newest.map { try JSONDecoder().decode(StrokeRecording.self, from: Data(contentsOf: $0)) }
    }

    private static var documents: URL {
        URL.documentsDirectory
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
