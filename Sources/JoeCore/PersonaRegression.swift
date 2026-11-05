import Foundation

public struct PersonaRegressionCase: Sendable, Identifiable {
    public let id: String
    public let text: String
    public let language: ReplyLanguage
    public static let version = "joe.persona-regression.v1"
    public static let all: [PersonaRegressionCase] = [
        .init(id: "zh-tired", text: "\u{6211}\u{4eca}\u{5929}\u{597d}\u{7d2f}", language: .chinese),
        .init(id: "zh-glucose", text: "\u{8840}\u{7cd6}\u{591a}\u{5c11}？", language: .chinese),
        .init(id: "zh-meal", text: "\u{4e3a}\u{4ec0}\u{4e48}\u{996d}\u{540e}\u{4e00}\u{76f4}\u{9ad8}？", language: .chinese),
        .init(id: "zh-dance", text: "\u{6211}\u{521a}\u{8df3}\u{5b8c}\u{821e}", language: .chinese),
        .init(id: "zh-class", text: "\u{6211}\u{4e00}\u{5c0f}\u{65f6}\u{540e}\u{8981}\u{4e0a}\u{8bfe}", language: .chinese),
        .init(id: "zh-burnout", text: "\u{6211}\u{89c9}\u{5f97}\u{6211}\u{4eca}\u{5929}\u{63a7}\u{5236}\u{5f97}\u{5f88}\u{5dee}", language: .chinese),
        .init(id: "en-burnout", text: "I feel like I messed up again", language: .english),
        .init(id: "en-glucose", text: "What is my glucose?", language: .english),
        .init(id: "en-ballet", text: "I just finished ballet", language: .english),
        .init(id: "en-overnight", text: "Why do I keep going low at night?", language: .english)
    ]
}
