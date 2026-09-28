import Foundation

/// The move half of `JiraClient`, so the walk can be tested without a network stack.
public protocol JiraIssueMoving: Sendable {
    func transitions(for key: String) async throws -> (JiraStatus, [JiraTransition])
    func perform(_ transition: JiraTransition, on key: String, values: [String: String]) async throws
}

extension JiraClient: JiraIssueMoving {}

public enum JiraMoveOutcome: Sendable, Equatable {
    case moved(to: JiraStatus)
    /// Earlier hops already happened in Jira.
    case stopped(at: JiraStatus, target: JiraLane)
    /// `leftAt` is where the last hop that went through put the issue, if any did.
    case failed(String, leftAt: JiraStatus?)
    /// The user closed a hop's form.
    case cancelled(leftAt: JiraStatus?)
}

/// Re-reads the status before every hop, in case the browser moved it meanwhile.
public struct JiraMove: Sendable {
    static let maxHops = 6

    private let client: JiraIssueMoving
    private let askFor: @Sendable (JiraFieldRequest) async -> [String: String]?

    public init(
        client: JiraIssueMoving,
        askFor: @escaping @Sendable (JiraFieldRequest) async -> [String: String]? = { _ in nil }
    ) {
        self.client = client
        self.askFor = askFor
    }

    public func run(_ key: String, to target: JiraLane) async -> JiraMoveOutcome {
        var visited: Set<String> = []
        var leftAt: JiraStatus?
        do {
            for _ in 0..<Self.maxHops {
                let (status, offered) = try await client.transitions(for: key)
                if status.lane == target { return .moved(to: status) }
                visited.insert(status.name)
                guard let hop = JiraRoute.nextHop(
                    from: status, toward: target, offered: offered, visited: visited
                ) else {
                    return .stopped(at: status, target: target)
                }
                var values: [String: String] = [:]
                if !hop.fields.isEmpty {
                    let request = JiraFieldRequest(key: key, from: status, to: hop.to, fields: hop.fields)
                    guard let answer = await askFor(request) else { return .cancelled(leftAt: leftAt) }
                    values = answer
                }
                try await client.perform(hop, on: key, values: values)
                leftAt = hop.to
            }
            let (status, _) = try await client.transitions(for: key)
            return status.lane == target ? .moved(to: status) : .stopped(at: status, target: target)
        } catch let error as PRMasterError {
            return .failed(error.errorDescription ?? "Jira refused the move.", leftAt: leftAt)
        } catch {
            return .failed(error.localizedDescription, leftAt: leftAt)
        }
    }
}
