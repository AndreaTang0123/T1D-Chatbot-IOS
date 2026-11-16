import Foundation

/// A submitted recording owns one stable bubble. Late/canceled results cannot send a second turn.
public struct VoiceMessageDelivery: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case recognizing
        case recognized(String)
        case failed(String)
        case cancelled
    }
    public let id: UUID
    public private(set) var state: State = .recognizing
    public init(id: UUID) { self.id = id }
    public var isPending: Bool { state == .recognizing }
    public var recognizedText: String? { if case let .recognized(text) = state { text } else { nil } }
    @discardableResult public mutating func recognize(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPending, !text.isEmpty else { return false }
        state = .recognized(text); return true
    }
    @discardableResult public mutating func fail(_ message: String) -> Bool {
        guard isPending else { return false }; state = .failed(message); return true
    }
    @discardableResult public mutating func cancel() -> Bool {
        guard isPending else { return false }; state = .cancelled; return true
    }
}
