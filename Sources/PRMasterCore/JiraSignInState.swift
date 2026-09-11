import Foundation

public enum JiraSignInState: Sendable, Equatable {
    case idle
    case testing
    case succeeded(name: String)
    case failed(message: String)

    public var isBusy: Bool { self == .testing }

    public var succeededName: String? {
        if case .succeeded(let name) = self { return name }
        return nil
    }

    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    public static func message(for error: PRMasterError) -> String {
        error.localizedDescription
    }
}

extension JiraSignInState: CaseIterable {
    public static var allCases: [JiraSignInState] {
        [.idle, .testing, .succeeded(name: ""), .failed(message: "")]
    }
}
