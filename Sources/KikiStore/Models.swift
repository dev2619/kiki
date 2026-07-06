import Foundation

public struct Snippet: Codable, Equatable {
    public let trigger: String
    public let template: String

    public init(trigger: String, template: String) {
        self.trigger = trigger
        self.template = template
    }
}

public struct HistoryEntry: Codable, Equatable {
    public let date: Date
    public let rawText: String
    public let finalText: String
    public let profile: String
    public let audioSeconds: Double

    public init(date: Date, rawText: String, finalText: String, profile: String, audioSeconds: Double) {
        self.date = date
        self.rawText = rawText
        self.finalText = finalText
        self.profile = profile
        self.audioSeconds = audioSeconds
    }
}
