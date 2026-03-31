import Foundation

struct ProcessResponse: Decodable {
    let id: String?
    let transcription: String
    let result: String
    let audio_duration_seconds: Double?
    let processing_time_ms: Int?
    let created_at: String?
}
