import XCTest
@testable import Claude会话管理

final class SafetyTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testSameNamedProjectsHaveDifferentProjectIDs() throws {
        let first = makeSession(
            id: "one",
            cwd: temporaryRoot.appendingPathComponent("client-a/demo").path
        )
        let second = makeSession(
            id: "two",
            cwd: temporaryRoot.appendingPathComponent("client-b/demo").path
        )

        XCTAssertEqual(first.projectName, second.projectName)
        XCTAssertNotEqual(first.projectID, second.projectID)
    }

    func testRecentlyActiveSessionIsDetected() {
        var session = makeSession(id: "active", cwd: temporaryRoot.path)
        session.lastActivityAt = Date().addingTimeInterval(-30)
        XCTAssertTrue(session.isRecentlyActive)

        session.lastActivityAt = Date().addingTimeInterval(-121)
        XCTAssertFalse(session.isRecentlyActive)
    }

    func testTrashMoveAndRestorePreservesFiles() throws {
        let source = try makeSourceFiles(id: "roundtrip")
        let service = TrashService(root: temporaryRoot.appendingPathComponent("Trash"))
        let session = makeSession(
            id: "roundtrip",
            cwd: temporaryRoot.path,
            metaURL: source.meta,
            transcriptURL: source.transcript
        )

        _ = try service.moveToTrash(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.meta.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.transcript.path))
        XCTAssertEqual(service.list().count, 1)

        try service.restore(session.id)
        XCTAssertEqual(try String(contentsOf: source.meta, encoding: .utf8), "{\"title\":\"test\"}")
        XCTAssertEqual(try String(contentsOf: source.transcript, encoding: .utf8), "{\"type\":\"user\"}\n")
        XCTAssertTrue(service.list().isEmpty)
    }

    func testRestoreRefusesToOverwriteNewFile() throws {
        let source = try makeSourceFiles(id: "conflict")
        let service = TrashService(root: temporaryRoot.appendingPathComponent("Trash"))
        let session = makeSession(
            id: "conflict",
            cwd: temporaryRoot.path,
            metaURL: source.meta,
            transcriptURL: source.transcript
        )

        _ = try service.moveToTrash(session)
        try "new live metadata".write(to: source.meta, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.restore(session.id)) { error in
            guard case TrashError.restoreConflict = error else {
                return XCTFail("Expected restoreConflict, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: source.meta, encoding: .utf8), "new live metadata")
        XCTAssertEqual(service.list().count, 1)
    }

    private func makeSourceFiles(id: String) throws -> (meta: URL, transcript: URL) {
        let sourceDir = temporaryRoot.appendingPathComponent("Sources/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let meta = sourceDir.appendingPathComponent("local_\(id).json")
        let transcript = sourceDir.appendingPathComponent("\(id).jsonl")
        try "{\"title\":\"test\"}".write(to: meta, atomically: true, encoding: .utf8)
        try "{\"type\":\"user\"}\n".write(to: transcript, atomically: true, encoding: .utf8)
        return (meta, transcript)
    }

    private func makeSession(
        id: String,
        cwd: String,
        metaURL: URL? = nil,
        transcriptURL: URL? = nil
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            source: .merged,
            title: "Test",
            cwd: cwd,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            model: nil,
            effort: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivityAt: Date(timeIntervalSince1970: 1),
            byteSize: 1,
            messageCount: 1,
            completedTurns: nil,
            isArchived: false,
            isFavorite: false,
            tags: [],
            gitBranch: nil,
            desktopSessionId: id,
            cliSessionId: id,
            metaURL: metaURL,
            transcriptURL: transcriptURL,
            parseError: nil,
            titleSource: nil
        )
    }
}
