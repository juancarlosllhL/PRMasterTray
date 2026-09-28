import Foundation

/// Turns the file lists of the compare and pull request files endpoints into
/// `DiffFile`s. Both return the same file object.
public enum DiffDecoder {

    public static func compareFiles(_ data: Data) throws -> [DiffFile] {
        try decode(ComparePayload.self, data).files.map(diffFile)
    }

    public static func pullFiles(_ data: Data) throws -> [DiffFile] {
        try decode([RESTFile].self, data).map(diffFile)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }
    }

    private static func diffFile(_ file: RESTFile) -> DiffFile {
        DiffFile(
            path: file.filename,
            previousPath: file.previousFilename,
            // Tolerant, like the GraphQL enums: a status GitHub adds later
            // must not cost the reader the whole diff.
            change: DiffFile.Change(rawValue: file.status) ?? .modified,
            additions: file.additions,
            deletions: file.deletions,
            content: content(of: file)
        )
    }

    private static func content(of file: RESTFile) -> DiffContent {
        guard let patch = file.patch else {
            return .omitted(file.changes > 0 ? .tooLarge : .noTextChanges)
        }
        guard let hunks = try? PatchParser.hunks(patch) else { return .omitted(.unparseable) }
        return .hunks(hunks)
    }

    private struct ComparePayload: Decodable {
        let files: [RESTFile]
    }

    private struct RESTFile: Decodable {
        let filename: String
        let previousFilename: String?
        let status: String
        let additions: Int
        let deletions: Int
        let changes: Int
        let patch: String?
    }
}
