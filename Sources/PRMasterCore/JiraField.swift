import Foundation

/// A field on a transition's screen that the app knows how to ask for.
///
/// Every one is treated as required: on ACME, Jira reports the Bug fields as
/// optional while a workflow validator refuses the transition without them.
public struct JiraField: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case option([String])
        case text
        case richText
    }

    public let id: String
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    private static let remarkPrefix = "PM:"

    /// Lansweeper's convention: every Remark opens with "PM:".
    private var takesRemarkPrefix: Bool {
        name.caseInsensitiveCompare("Remark") == .orderedSame
    }

    /// What `normalized` puts in front when the user leaves it out, if anything.
    public var addedPrefix: String? { takesRemarkPrefix ? Self.remarkPrefix : nil }

    public func problem(with value: String) -> String? {
        let sent = normalized(value)
        if case .option(let allowed) = kind {
            return allowed.contains(sent) ? nil : "Choose a \(name)."
        }
        let body = takesRemarkPrefix ? String(sent.dropFirst(Self.remarkPrefix.count)) : sent
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(name) is required." : nil
    }

    /// What is sent to Jira: trimmed, and a Remark given "PM: " unless it has it.
    public func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard takesRemarkPrefix else { return trimmed }
        guard trimmed.lowercased().hasPrefix(Self.remarkPrefix.lowercased()) else {
            return "\(Self.remarkPrefix) \(trimmed)"
        }
        return Self.remarkPrefix + trimmed.dropFirst(Self.remarkPrefix.count)
    }

    /// Jira's v3 API takes a multi-line text field only as a document.
    static func encode(_ value: String, as kind: Kind) -> Any {
        switch kind {
        case .option:
            return ["value": value]
        case .text:
            return value
        case .richText:
            let paragraphs: [[String: Any]] = value.components(separatedBy: "\n").map { line in
                let content: [[String: Any]] = line.isEmpty ? [] : [["type": "text", "text": line]]
                return ["type": "paragraph", "content": content]
            }
            return ["type": "doc", "version": 1, "content": paragraphs]
        }
    }
}

/// A hop that cannot be posted until the user fills its screen.
public struct JiraFieldRequest: Sendable, Equatable {
    public let key: String
    public let from: JiraStatus
    public let to: JiraStatus
    public let fields: [JiraField]

    public init(key: String, from: JiraStatus, to: JiraStatus, fields: [JiraField]) {
        self.key = key
        self.from = from
        self.to = to
        self.fields = fields
    }

    public func problems(in values: [String: String]) -> [String: String] {
        fields.reduce(into: [:]) { problems, field in
            if let problem = field.problem(with: values[field.id] ?? "") {
                problems[field.id] = problem
            }
        }
    }

    public func normalized(_ values: [String: String]) -> [String: String] {
        fields.reduce(into: [:]) { sent, field in
            sent[field.id] = field.normalized(values[field.id] ?? "")
        }
    }
}
