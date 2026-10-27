import Foundation
import CryptoKit
import PDFKit

struct SyncFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
enum ExportMode: String, Codable, CaseIterable {
    case auto, markdown, pdf
    var label: String { switch self { case .auto: return "自动"; case .markdown: return "固定 Markdown"; case .pdf: return "固定 PDF" } }
}
struct DocumentEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var enabled = true
    var mode: ExportMode = .auto
    var title = "尚未读取标题"
    var status = "尚未同步"
    var lastSuccess: Date?
    var lastPath: String?
}
struct BackupLocation: Codable, Identifiable {
    var id = UUID()
    var destination: String
    var documents: [DocumentEntry] = []
    var label: String { URL(fileURLWithPath: destination).lastPathComponent }
}
struct SyncJob {
    let locationID: UUID
    let destination: String
    let entry: DocumentEntry
}
struct Settings: Codable {
    var locations: [BackupLocation] = []
    var intervalMinutes = 30
    var paused = false
    var cliPath = "/opt/homebrew/bin/lark-cli"
    init() {}
    enum CodingKeys: String, CodingKey { case locations, destination, documents, intervalMinutes, paused, cliPath }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedInterval = try values.decode(Int.self, forKey: .intervalMinutes)
        intervalMinutes = savedInterval == 5 ? 5 : 30
        paused = try values.decode(Bool.self, forKey: .paused)
        cliPath = try values.decode(String.self, forKey: .cliPath)
        if values.contains(.locations) {
            locations = try values.decode([BackupLocation].self, forKey: .locations)
        } else {
            locations = [BackupLocation(destination: try values.decode(String.self, forKey: .destination), documents: try values.decode([DocumentEntry].self, forKey: .documents))]
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(locations, forKey: .locations)
        try values.encode(intervalMinutes, forKey: .intervalMinutes)
        try values.encode(paused, forKey: .paused)
        try values.encode(cliPath, forKey: .cliPath)
    }
    func jobs(locationID: UUID? = nil, documentID: UUID? = nil) -> [SyncJob] {
        locations.filter { locationID == nil || $0.id == locationID }.flatMap { location in
            location.documents.filter { $0.enabled && (documentID == nil || $0.id == documentID) }.map {
                SyncJob(locationID: location.id, destination: location.destination, entry: $0)
            }
        }
    }
}
typealias JSONObject = [String: Any]
typealias CommandRunner = ([String]) throws -> JSONObject

final class CLI {
    let executable: String
    init(_ path: String) { executable = path }
    func run(_ arguments: [String]) throws -> JSONObject {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw SyncFailure("找不到飞书 CLI：\(executable)") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FeishuSync-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let out = temp.appendingPathComponent("out"), err = temp.appendingPathComponent("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let oh = try FileHandle(forWritingTo: out), eh = try FileHandle(forWritingTo: err)
        defer { try? oh.close(); try? eh.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["NO_COLOR"] = "1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = oh; process.standardError = eh
        try process.run()
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw SyncFailure("飞书 CLI 超时，旧备份已保留。请检查网络后重试。")
        }
        let data = try Data(contentsOf: out)
        let stderr = (try? Data(contentsOf: err)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
        if process.terminationStatus != 0 || object?["ok"] as? Bool == false {
            let error = object?["error"] as? JSONObject ?? ((try? JSONSerialization.jsonObject(with: stderr)) as? JSONObject)?["error"] as? JSONObject
            let message = error?["message"] as? String ?? "CLI 执行失败（\(process.terminationStatus)）"
            if message.contains("authorization") || message.contains("token") || message.contains("keychain") {
                throw SyncFailure("飞书登录失效或钥匙串不可用。请从菜单选择「飞书登录说明」。\n" + message)
            }
            throw SyncFailure(message)
        }
        guard let object else { throw SyncFailure("CLI 返回的不是有效 JSON，未发布备份。") }
        if let code = object["code"] as? Int, code != 0 { throw SyncFailure(object["msg"] as? String ?? "飞书 API 错误 \(code)") }
        return object["data"] as? JSONObject ?? object
    }
}

struct SyncResult { let title: String; let path: String; let message: String }
struct Manifest: Codable {
    var schema = 1
    let identity: String
    let title: String
    let format: String
    let relativePath: String
    let digest: String
    let updated: Date
}
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func safeTitle(_ title: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:\0\n\r").union(.controlCharacters)
    let text = title.components(separatedBy: forbidden).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
    return String((text.isEmpty || text == "." || text == ".." ? "未命名文档" : text).prefix(100))
}
func validateURL(_ text: String) throws {
    guard let url = URL(string: text), url.scheme == "https", let host = url.host,
          ["feishu.cn", "larksuite.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
          url.pathComponents.count >= 3,
          ["wiki", "docx", "docs", "doc", "slides"].contains(url.pathComponents[1]) else {
        throw SyncFailure("请输入飞书 / Lark 的单篇文档、Wiki 页面或幻灯片 HTTPS 链接。")
    }
}

final class SyncEngine {
    let run: CommandRunner
    let pause: (TimeInterval) -> Void
    let stateRoot: URL
    init(stateRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FeishuSync/SyncData"), run: @escaping CommandRunner, pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) { self.stateRoot = stateRoot; self.run = run; self.pause = pause }
    func call(_ args: [String]) throws -> JSONObject { try run(args + ["--as", "user"]) }
    func api(_ path: String, params: JSONObject = [:]) throws -> JSONObject {
        let value = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8)!
        return try call(["api", "GET", path, "--params", value])
    }
    func revision(_ token: String) throws -> Int {
        let result = try api("/open-apis/docx/v1/documents/\(token)")
        guard let doc = result["document"] as? JSONObject, let rev = doc["revision_id"] as? Int else { throw SyncFailure("无法确认文档版本，未导出。") }
        return rev
    }
    // The document-wide endpoint returns every nested block. Verify pagination AND child closure.
    func allBlocks(_ token: String, revision: Int) throws -> [JSONObject] {
        var blocks: [JSONObject] = [], cursor = "", seen = Set<String>()
        for _ in 0..<1000 {
            var params: JSONObject = ["page_size": 500, "document_revision_id": revision]
            if !cursor.isEmpty { params["page_token"] = cursor }
            let page = try api("/open-apis/docx/v1/documents/\(token)/blocks", params: params)
            guard let items = page["items"] as? [JSONObject], let more = page["has_more"] as? Bool else { throw SyncFailure("文档分页结构不完整，未导出。") }
            blocks += items
            if !more {
                let ids = Set(blocks.compactMap { $0["block_id"] as? String })
                guard !blocks.isEmpty, ids.count == blocks.count else { throw SyncFailure("文档块缺失或重复，未导出。") }
                for block in blocks {
                    if let children = block["children"] as? [String], !Set(children).isSubset(of: ids) { throw SyncFailure("嵌套内容不完整，未导出。") }
                }
                return blocks
            }
            guard let next = page["page_token"] as? String, !next.isEmpty, seen.insert(next).inserted else { throw SyncFailure("分页未完成或游标重复，未导出。") }
            cursor = next
        }
        throw SyncFailure("文档分页超过安全上限，未导出。")
    }
    static func requiresPDF(_ blocks: [JSONObject]) -> Bool {
        // Only documented plain text/structural blocks are allowlisted. Unknown types are conservative PDF.
        let plain = Set(Array(1...15) + [17, 19, 22, 24, 25, 31, 32, 34])
        for block in blocks {
            guard let type = block["block_type"] as? Int, plain.contains(type) else { return true }
            // Inline elements may contain equations/media or future extensions. Strings inside code/text never count as nodes.
            func unknownElement(_ value: Any) -> Bool {
                if let map = value as? JSONObject {
                    if let elements = map["elements"] as? [JSONObject] {
                        for element in elements {
                            if !Set(element.keys).isSubset(of: ["text_run", "mention_user", "mention_doc"]) { return true }
                        }
                    }
                    return map.values.contains(where: unknownElement)
                }
                if let array = value as? [Any] { return array.contains(where: unknownElement) }
                return false
            }
            if unknownElement(block) { return true }
        }
        return false
    }
    func exportedFile(_ response: JSONObject, stage: URL, ext: String) throws -> URL {
        guard response["ready"] as? Bool != false, response["timed_out"] as? Bool != true,
              let path = response["saved_path"] as? String else { throw SyncFailure("导出未完成或未返回下载路径。") }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.deletingLastPathComponent().resolvingSymlinksInPath() == stage.resolvingSymlinksInPath(),
              try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SyncFailure("导出文件路径不安全。") }
        let bytes = try Data(contentsOf: file)
        if ext == "pdf" {
            guard bytes.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: bytes), pdf.pageCount > 0 else { throw SyncFailure("PDF 文件不完整，旧备份已保留。") }
        } else {
            guard String(data: bytes, encoding: .utf8) != nil else { throw SyncFailure("Markdown 不是有效 UTF-8。") }
        }
        return file
    }
    func sync(_ entry: DocumentEntry, destination: String) throws -> SyncResult {
        try validateURL(entry.url)
        let info = try call(["drive", "+inspect", "--url", entry.url])
        guard let token = info["token"] as? String, token.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil,
              let type = info["type"] as? String, ["docx", "doc", "slides"].contains(type),
              let title = info["title"] as? String, !title.isEmpty else { throw SyncFailure("不支持此文档类型，或未取得远端标题。当前支持文档和幻灯片。") }
        var ext = entry.mode == .markdown ? "markdown" : "pdf"
        var initialRevision: Int?
        var reason = entry.mode.label
        if type == "docx" {
            initialRevision = try revision(token)
            if entry.mode != .pdf {
                let blocks = try allBlocks(token, revision: initialRevision!)
                let graphics = Self.requiresPDF(blocks)
                if entry.mode == .auto { ext = graphics ? "pdf" : "markdown"; reason = graphics ? "含图片、图形或非纯文字结构 → PDF" : "完整结构为文字内容 → Markdown" }
                else if graphics { reason = "固定 Markdown：图片或复杂结构可能丢失，请改用自动或 PDF" }
            }
        } else if entry.mode == .markdown { throw SyncFailure("旧版文档和幻灯片不支持 Markdown，请选择自动或 PDF。") }
        else { reason = "此类型使用 PDF" }
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("FeishuSync-export-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var response = try call(["drive", "+export", "--url", entry.url, "--file-extension", ext, "--output-dir", stage.path, "--overwrite"])
        if response["saved_path"] == nil {
            guard let ticket = response["ticket"] as? String, !ticket.isEmpty else { throw SyncFailure("导出未返回文件或任务编号。") }
            var ready = false
            for _ in 0..<60 {
                pause(5)
                let status = try call(["drive", "+task_result", "--scenario", "export", "--ticket", ticket, "--file-token", token])
                if status["failed"] as? Bool == true { throw SyncFailure(status["job_error_msg"] as? String ?? "导出任务失败") }
                if status["ready"] as? Bool == true {
                    guard let fileToken = status["file_token"] as? String, !fileToken.isEmpty else { throw SyncFailure("导出完成但缺少文件凭据。") }
                    response = try call(["drive", "+export-download", "--file-token", fileToken, "--output-dir", stage.path, "--overwrite"])
                    ready = true; break
                }
            }
            guard ready else { throw SyncFailure("导出任务在五分钟内未完成，下次同步可重试；旧备份已保留。") }
        }
        let file = try exportedFile(response, stage: stage, ext: ext)
        if let initialRevision, try revision(token) != initialRevision { throw SyncFailure("文档在导出过程中被修改，已保留旧备份，请稍后重试。") }
        return try publish(file: file, identity: type + ":" + token, title: title, ext: ext, destination: destination, reason: reason)
    }
    // Only finished document files live in the chosen folder. Ownership/history are private app data.
    func publish(file: URL, identity: String, title: String, ext: String, destination: String, reason: String) throws -> SyncResult {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let key = sha256(Data(identity.utf8))
        let docDir = stateRoot.appendingPathComponent(sha256(Data(root.path.utf8))).appendingPathComponent(key)
        try fm.createDirectory(at: docDir, withIntermediateDirectories: true)
        let manifestURL = docDir.appendingPathComponent("manifest.json")
        let bytes = try Data(contentsOf: file), digest = sha256(bytes)
        let old = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") }
        func owned(_ path: URL) -> Bool {
            guard let old, old.identity == identity, validName(old.relativePath), path.lastPathComponent == old.relativePath,
                  (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let existing = try? Data(contentsOf: path) else { return false }
            return sha256(existing) == old.digest
        }
        let suffix = ext == "markdown" ? ".md" : ".pdf"
        var target = root.appendingPathComponent(safeTitle(title) + suffix)
        if fm.fileExists(atPath: target.path) && !owned(target) {
            target = root.appendingPathComponent(safeTitle(title) + "-" + key.prefix(8) + suffix)
            if fm.fileExists(atPath: target.path) && !owned(target) {
                throw SyncFailure("目标目录存在同名且不属于本应用的文件，请保留或改名后重试。")
            }
        }
        if let old, owned(target), old.title == title, old.format == ext, old.digest == digest {
            return SyncResult(title: title, path: target.path, message: "内容未变 · " + reason)
        }
        var previous: URL?
        if let old, validName(old.relativePath) {
            let oldFile = root.appendingPathComponent(old.relativePath)
            if owned(oldFile) {
                let archive = docDir.appendingPathComponent("history/" + UUID().uuidString)
                try fm.createDirectory(at: archive, withIntermediateDirectories: true)
                try fm.copyItem(at: oldFile, to: archive.appendingPathComponent(oldFile.lastPathComponent))
                previous = oldFile
            }
        }
        // Atomic replacement leaves the old completed document intact on write failure.
        try bytes.write(to: target, options: .atomic)
        let manifest = Manifest(identity: identity, title: title, format: ext, relativePath: target.lastPathComponent, digest: digest, updated: Date())
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        if let previous, previous != target, owned(previous) { try fm.removeItem(at: previous) }
        return SyncResult(title: title, path: target.path, message: "已备份 · " + reason)
    }
}
