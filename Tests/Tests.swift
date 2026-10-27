import Foundation
import PDFKit
import AppKit

@main struct Tests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else { throw SyncFailure("TEST FAILED: " + name) }
        checks += 1; print("PASS \(name)")
    }
    static func expectFailure(_ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; print("PASS \(name)"); return }
        throw SyncFailure("TEST FAILED (expected error): " + name)
    }
    static func main() throws {
        try check(Settings().locations.isEmpty, "fresh install has no documents or destinations")
        try check(Settings().jobs().isEmpty, "fresh install cannot sync any remote document")
        let legacyDocument = DocumentEntry(url: "https://example.feishu.cn/docx/legacy", title: "原文档", status: "已备份", lastSuccess: Date(), lastPath: "/old/path.md")
        let legacy: JSONObject = ["destination": "/old/backup folder", "documents": try JSONSerialization.jsonObject(with: JSONEncoder().encode([legacyDocument])), "intervalMinutes": 60, "paused": true, "cliPath": "/custom/cli"]
        var migrated = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(migrated.locations.count == 1 && migrated.locations[0].destination == "/old/backup folder", "legacy destination migrates")
        try check(migrated.locations[0].documents[0] == legacyDocument && migrated.paused && migrated.intervalMinutes == 30 && migrated.cliPath == "/custom/cli", "migration preserves document ID, status and preferences")
        migrated.locations.append(BackupLocation(destination: "/second backup", documents: [legacyDocument]))
        let jobs = migrated.jobs()
        try check(jobs.count == 2 && Set(jobs.map { $0.destination }).count == 2, "same document routes to two destinations")
        let groupJobs = migrated.jobs(locationID: migrated.locations[1].id, documentID: legacyDocument.id)
        try check(groupJobs.count == 1 && groupJobs[0].destination == "/second backup", "single document scoped to its location")
        migrated.locations[1].documents[0].enabled = false
        try check(migrated.jobs().count == 1, "disabled document excluded per location")
        let roundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(migrated))
        try check(roundTrip.locations.count == 2 && roundTrip.locations[1].id == migrated.locations[1].id && !roundTrip.locations[1].documents[0].enabled, "multi-location settings round trip")
        var empty = Settings(); empty.locations = []
        let decodedEmpty = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(empty))
        try check(decodedEmpty.locations.isEmpty && decodedEmpty.jobs().isEmpty, "empty groups remain empty after restart")
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("FeishuSyncTests-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try check(!SyncEngine.requiresPDF([["block_type": 14, "code": ["elements": [["text_run": ["content": "<img src='x'> 图片 image"]]]]]]), "code strings do not trigger images")
        try check(SyncEngine.requiresPDF([["block_type": 27, "image": [:]]]), "image → PDF")
        for type in [16, 18, 21, 23, 26, 28, 29, 30, 43, 999] {
            try check(SyncEngine.requiresPDF([["block_type": type]]), "graphics/unknown \(type) → PDF")
        }
        try check(SyncEngine.requiresPDF([["block_type": 2, "text": ["elements": [["equation": ["content": "x"]]]]]]), "inline equation → PDF")
        try expectFailure("invalid URL") { try validateURL("https://evil.example/docx/abc") }
        try expectFailure("suffix spoofed URL") { try validateURL("https://feishu.cn.evil.example/docx/abc") }
        var pages = 0
        let paginated = SyncEngine(run: { args in
            pages += 1
            if pages == 1 { return ["items": [["block_id": "root", "block_type": 1, "children": ["nested"]]], "has_more": true, "page_token": "second"] }
            return ["items": [["block_id": "nested", "block_type": 27]], "has_more": false]
        }, pause: { _ in })
        let blocks = try paginated.allBlocks("token", revision: 1)
        try check(pages == 2 && blocks.count == 2 && SyncEngine.requiresPDF(blocks), "nested image on second page")
        try expectFailure("missing nested blocks") {
            _ = try SyncEngine(run: { _ in ["items": [["block_id": "root", "children": ["missing"]]], "has_more": false] }).allBlocks("x", revision: 1)
        }
        try expectFailure("incomplete pagination") {
            _ = try SyncEngine(run: { _ in ["items": [["block_id": "root"]], "has_more": true] }).allBlocks("x", revision: 1)
        }
        try expectFailure("repeated cursor") {
            _ = try SyncEngine(run: { _ in ["items": [["block_id": UUID().uuidString]], "has_more": true, "page_token": "same"] }).allBlocks("x", revision: 1)
        }
        try expectFailure("missing pagination completion flag") {
            _ = try SyncEngine(run: { _ in ["items": [["block_id": "root"]]] }).allBlocks("x", revision: 1)
        }
        var title = "标题 with spaces", token = "documentA", content = "# Backup\n", failExport = false, pending = false, polls = 0, badPDF = false, changeRevision = false, revReads = 0
        let engine = SyncEngine(stateRoot: temp.appendingPathComponent("app-state"), run: { args in
            if args.contains("+inspect") { return ["type": "docx", "token": token, "title": title] }
            if args.first == "api" {
                if args[2].hasSuffix("/blocks") { return ["items": [["block_type": 1, "block_id": "root"]], "has_more": false] }
                revReads += 1
                return ["document": ["revision_id": changeRevision ? revReads : 1]]
            }
            if args.contains("+task_result") {
                polls += 1
                return ["ready": polls >= 2, "failed": false, "file_token": "exported"]
            }
            if failExport { throw SyncFailure("network failed") }
            if pending && args.contains("+export") { return ["ready": false, "timed_out": true, "ticket": "task"] }
            let dir = URL(fileURLWithPath: args[args.firstIndex(of: "--output-dir")! + 1])
            let file = dir.appendingPathComponent("remote title.tmp")
            let isPDF = pending || args.contains("pdf")
            if isPDF && !badPDF {
                let pdf = PDFDocument(); let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 50, height: 50), for: .mediaBox); pdf.insert(page, at: 0)
                try pdf.dataRepresentation()!.write(to: file)
            } else { try Data(content.utf8).write(to: file) }
            return ["saved_path": file.path]
        }, pause: { _ in })
        var entry = DocumentEntry(url: "https://example.feishu.cn/docx/documentA")
        let first = try engine.sync(entry, destination: temp.path)
        try check(fm.fileExists(atPath: first.path) && first.path.hasSuffix("标题 with spaces.md"), "publish named Markdown with spaces")
        try check(URL(fileURLWithPath: first.path).deletingLastPathComponent().resolvingSymlinksInPath() == temp.resolvingSymlinksInPath(), "document directly in destination")
        let unchanged = try engine.sync(entry, destination: temp.path)
        try check(unchanged.path == first.path, "unchanged content deduplicated")
        failExport = true
        try expectFailure("failed export not success") { _ = try engine.sync(entry, destination: temp.path) }
        try check(fm.fileExists(atPath: first.path), "failure preserves previous backup")
        failExport = false; title = "renamed"; content = "new content"
        let renamed = try engine.sync(entry, destination: temp.path)
        try check(renamed.path != first.path && !fm.fileExists(atPath: first.path), "rename removes previous visible name")
        let historyFiles = fm.enumerator(atPath: temp.appendingPathComponent("app-state").path)!.allObjects.compactMap { $0 as? String }
        try check(historyFiles.contains { $0.contains("history/") && $0.hasSuffix(".md") }, "history stored outside visible document layout")
        token = "documentB"
        let other = try engine.sync(entry, destination: temp.path)
        try check(other.path != renamed.path, "same title different IDs isolated")
        let preservedBytes = try Data(contentsOf: URL(fileURLWithPath: renamed.path))
        try check(preservedBytes == Data(content.utf8), "same title does not overwrite other document")
        pending = true; entry.mode = .pdf
        let pdf = try engine.sync(entry, destination: temp.path)
        try check(polls == 2 && pdf.path.hasSuffix(".pdf"), "pending export polls then downloads")
        pending = false; badPDF = true
        try expectFailure("invalid PDF rejected") { _ = try engine.sync(entry, destination: temp.path) }
        try check(fm.fileExists(atPath: pdf.path), "invalid PDF preserves previous version")
        badPDF = false; changeRevision = true
        try expectFailure("concurrent remote edit rejected") { _ = try engine.sync(entry, destination: temp.path) }
        let staged = temp.appendingPathComponent("stage"); try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try expectFailure("ready=false never publishes") { _ = try engine.exportedFile(["ready": false, "saved_path": first.path], stage: staged, ext: "markdown") }
        try expectFailure("external path rejected") { _ = try engine.exportedFile(["saved_path": first.path], stage: staged, ext: "markdown") }
        print("\(checks) checks passed")
    }
}
