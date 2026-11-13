// STRADA Trim Tool
// Reads timeline exports (CMX EDL, Final Cut Pro 7 XML, FCPX .fcpxml/.fcpxmld,
// OpenTimelineIO .otio), finds the matching camera originals, audio and other
// media on one or more source drives, groups them by file type, and copies only
// the selected types/files to a destination organized into camera-roll folders.
//
// Build: bash build.sh

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

// MARK: - File types

let audioExtensions: Set<String> = ["wav", "bwf", "aif", "aiff", "aifc", "mp3", "m4a", "flac", "caf"]
let frameExtensions: Set<String> = ["ari", "arx", "dng", "exr", "dpx"]
let sidecarExtensions: Set<String> = ["rmd"]
let videoExtensions: Set<String> = ["mxf", "mov", "mp4", "m4v", "r3d", "braw", "crm", "nev", "cine", "avi", "mts", "mkv"]
let scanExtensions: Set<String> = audioExtensions.union(frameExtensions).union(sidecarExtensions).union(videoExtensions)
let ignoredNames: Set<String> = ["bl", "blk", "black", "ax", "aux", "slug", "gap"]
let timelineExtensions: Set<String> = ["edl", "xml", "fcpxml", "fcpxmld", "otio"]

enum Family: Int {
    case camera = 0, video, audio, sidecar, avid
}

struct FileType {
    let category: String   // shown as the group name
    let folder: String     // folder name used by the "By file type" layout
    let family: Family
    let reason: String
}

// MARK: - Models

struct FoundFile: Identifiable {
    let id = UUID()
    let url: URL
    let rootName: String
    let relativePath: String
    let size: Int64
    let matchedName: String
    let partialMatch: Bool
    let type: FileType
    var selected: Bool
    var isDuplicate = false
    var state: String = ""
}

struct TimelineRef: Hashable {
    let label: String
    let names: [String]    // match keys (lowercased)
    let display: String
    let isVideo: Bool
    let isAudio: Bool
}

struct Candidate {
    let url: URL
    let rootName: String
    let rel: String
    let size: Int64
}

struct CategoryTotal {
    let name: String
    let count: Int
    let bytes: Int64
}

struct GroupStats {
    var count = 0
    var selectable = 0
    var selected = 0
    var bytes: Int64 = 0
    var selectedBytes: Int64 = 0
    var icon: String {
        if selected == 0 { return "square" }
        if selected >= max(selectable, 1) { return "checkmark.square.fill" }
        return "minus.square.fill"
    }
}

enum Layout: String, CaseIterable, Identifiable {
    case byRoll = "Camera roll folders + AUDIO / OTHER"
    case byType = "File type folders, then camera rolls"
    case source = "Keep source folder structure"
    case flat = "Everything in one folder"
    var id: String { rawValue }
}

enum CopyPhase: String {
    case copying = "Copying"
    case verifying = "Verifying"
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Formatting helpers

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

/// Decimal terabytes, same units Finder uses (1 TB = 1,000,000,000,000 bytes).
func formatTB(_ b: Int64) -> String {
    String(format: "%.2f TB", Double(b) / 1_000_000_000_000)
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "—" }
    let t = Int(seconds)
    if t >= 3600 { return String(format: "%dh %02dm", t / 3600, (t % 3600) / 60) }
    return String(format: "%dm %02ds", t / 60, t % 60)
}

func fileSize(_ url: URL) -> Int64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let n = attrs[.size] as? NSNumber else { return nil }
    return n.int64Value
}

func freeSpace(_ url: URL) -> Int64? {
    let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    if let i = v?.volumeAvailableCapacityForImportantUsage, i > 0 { return i }
    if let c = v?.volumeAvailableCapacity { return Int64(c) }
    return nil
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    return f.string(from: Date())
}

func isSameOrInside(_ a: URL, _ b: URL) -> Bool {
    let pa = a.standardizedFileURL.path + "/"
    let pb = b.standardizedFileURL.path + "/"
    return pa.hasPrefix(pb) || pb.hasPrefix(pa)
}

func safeFolderName(_ s: String) -> String {
    let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    return cleaned.isEmpty ? "Untitled" : cleaned
}

// MARK: - Name keys (how timeline names and file names are compared)

enum NameKeys {
    static let seqBracket = try! NSRegularExpression(pattern: "\\[[0-9]+-[0-9]+\\]")
    static let seqPrintf = try! NSRegularExpression(pattern: "%0[0-9]+d")
    static let seqHash = try! NSRegularExpression(pattern: "#+")
    static let r3dSegment = try! NSRegularExpression(pattern: "_[0-9]{3}$")
    static let frameNumber = try! NSRegularExpression(pattern: "[._][0-9]{4,8}$")

    static func replace(_ re: NSRegularExpression, in s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func stripped(_ re: NSRegularExpression, _ s: String) -> String? {
        let r = replace(re, in: s)
        return (r != s && !r.isEmpty) ? r : nil
    }

    static func lastComponent(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? s
    }

    /// File name from a URL string (file://localhost/Volumes/My%20Drive/A001.mov -> A001.mov)
    static func fileName(fromURL s: String) -> String {
        let cleaned = replace(seqPrintf, in: s)
        if let u = URL(string: cleaned), u.scheme != nil, !u.lastPathComponent.isEmpty {
            return u.lastPathComponent
        }
        return lastComponent(cleaned.removingPercentEncoding ?? cleaned)
    }

    static func normalize(_ raw: String) -> String {
        var s = lastComponent(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        s = replace(seqBracket, in: s)
        s = replace(seqPrintf, in: s)
        s = replace(seqHash, in: s)
        let ext = (s as NSString).pathExtension.lowercased()
        if scanExtensions.contains(ext) || ext == "rdc" { s = (s as NSString).deletingPathExtension }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        return s.lowercased()
    }

    /// A timeline name plus derived keys (RED segment and frame-number suffixes removed).
    static func keys(_ raw: String) -> [String] {
        let n = normalize(raw)
        guard !n.isEmpty else { return [] }
        var out = [n]
        if let s = stripped(r3dSegment, n), !out.contains(s) { out.append(s) }
        if let s = stripped(frameNumber, n), !out.contains(s) { out.append(s) }
        return out
    }

    /// The clip name of a file on disk, original case, without extension,
    /// RED segment number (_001) or frame number (.0000123).
    static func clipBase(fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        var b = (fileName as NSString).deletingPathExtension
        if ext == "r3d" { b = replace(r3dSegment, in: b) }
        if frameExtensions.contains(ext) { b = replace(frameNumber, in: b) }
        return b
    }
}

func makeRef(label: String, raws: [String], isVideo: Bool, isAudio: Bool) -> TimelineRef? {
    var names: [String] = []
    var shown: [String] = []
    for r in raws {
        let ks = NameKeys.keys(r)
        guard let first = ks.first, !ignoredNames.contains(first) else { continue }
        for k in ks where !names.contains(k) { names.append(k) }
        let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shown.contains(t) { shown.append(t) }
    }
    guard !names.isEmpty else { return nil }
    return TimelineRef(label: label, names: names, display: shown.joined(separator: "  /  "),
                       isVideo: isVideo, isAudio: isAudio)
}

// MARK: - Camera roll folder naming

private let fullRollRegex = try! NSRegularExpression(
    pattern: "^([A-Za-z][0-9]{3})C[0-9]{3,4}_[0-9]{6}_([A-Za-z0-9]{4})$")
private let looseRollRegex = try! NSRegularExpression(
    pattern: "^([A-Za-z]_?[0-9]{3,4})_?C[0-9]{3,4}")
private let brawRollRegex = try! NSRegularExpression(
    pattern: "^([A-Za-z][0-9]{3})_[0-9]{8}_C[0-9]{3}")

/// A001C001_240219_R32E -> "A001R32E" (ARRI).  Other camera-style names fall back
/// to the roll prefix: A001_C001_0219AB (RED) -> "A001", A001C002_190528MQ (Sony) -> "A001".
func rollFolder(for name: String) -> String? {
    let base = name
    let range = NSRange(base.startIndex..., in: base)
    if let m = fullRollRegex.firstMatch(in: base, range: range),
       let r1 = Range(m.range(at: 1), in: base),
       let r2 = Range(m.range(at: 2), in: base) {
        return (String(base[r1]) + String(base[r2])).uppercased()
    }
    for re in [looseRollRegex, brawRollRegex] {
        if let m = re.firstMatch(in: base, range: range), let r1 = Range(m.range(at: 1), in: base) {
            return String(base[r1]).uppercased()
        }
    }
    return nil
}

/// Path (relative to the destination folder) where a file will be copied.
func destinationRelPath(_ f: FoundFile, layout: Layout) -> String {
    let name = f.url.lastPathComponent
    let parentURL = f.url.deletingLastPathComponent()
    let parentName = f.relativePath.contains("/") ? parentURL.lastPathComponent : f.rootName
    // RED .RDC clip folders and frame sequences must stay together in their own folder.
    let keepParent = parentURL.pathExtension.lowercased() == "rdc"
        || frameExtensions.contains(f.url.pathExtension.lowercased())

    func rollPath() -> String {
        if f.type.family == .audio { return "AUDIO/" + safeFolderName(parentName) + "/" + name }
        let base = NameKeys.clipBase(fileName: name)
        let parentBase = (parentName as NSString).deletingPathExtension
        if let roll = rollFolder(for: base) ?? (keepParent ? rollFolder(for: parentBase) : nil) {
            return roll + "/" + (keepParent ? safeFolderName(parentName) + "/" : "") + name
        }
        return "OTHER/" + safeFolderName(parentName) + "/" + name
    }

    switch layout {
    case .flat:
        return name
    case .source:
        return safeFolderName(f.rootName) + "/" + f.relativePath
    case .byRoll:
        return rollPath()
    case .byType:
        var r = rollPath()
        for p in ["AUDIO/", "OTHER/"] where r.hasPrefix(p) { r = String(r.dropFirst(p.count)) }
        return f.type.folder + "/" + r
    }
}

// MARK: - Timeline parsers

enum EDLParser {
    static let commentKeys = ["FROM CLIP NAME:", "TO CLIP NAME:", "CLIP NAME:", "SOURCE FILE:", "FROM FILE:", "TO FILE:"]

    static func parse(text: String, label: String) -> [TimelineRef] {
        var refs: [TimelineRef] = []
        var number: String? = nil
        var track = ""
        var raws: [String] = []

        func flush() {
            if let n = number {
                let isVideo = track.contains("V") || track == "B"
                let isAudio = track.contains("A") || track == "B"
                if let r = makeRef(label: "\(label) #\(n) (\(track))", raws: raws, isVideo: isVideo, isAudio: isAudio) {
                    refs.append(r)
                }
            }
            raws = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("*") {
                guard number != nil else { continue }
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let upper = body.uppercased()
                for key in commentKeys where upper.hasPrefix(key) {
                    raws.append(String(body.dropFirst(key.count)))
                    break
                }
                continue
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if tokens.count >= 4, tokens[0].allSatisfy({ $0.isNumber }) {
                flush()
                number = tokens[0]
                track = tokens[2].uppercased()
                raws.append(tokens[1])
            }
        }
        flush()
        return refs
    }
}

enum FCP7Parser {
    static func parse(_ doc: XMLDocument, label: String) -> [TimelineRef] {
        // Full <file> definitions appear once; later uses are <file id="x"/>.
        var fileInfo: [String: (name: String?, path: String?)] = [:]
        for node in (try? doc.nodes(forXPath: "//file[@id]")) ?? [] {
            guard let e = node as? XMLElement, let id = e.attribute(forName: "id")?.stringValue else { continue }
            let name = e.elements(forName: "name").first?.stringValue
            let path = e.elements(forName: "pathurl").first?.stringValue
            if (name != nil || path != nil) && fileInfo[id] == nil { fileInfo[id] = (name, path) }
        }

        var refs: [TimelineRef] = []
        var n = 0
        for node in (try? doc.nodes(forXPath: "//clipitem")) ?? [] {
            guard let ci = node as? XMLElement, let file = ci.elements(forName: "file").first else { continue }
            var isAudio = false
            var p = ci.parent
            while let q = p {
                if q.name == "audio" { isAudio = true; break }
                if q.name == "video" { break }
                p = q.parent
            }
            let fileID = file.attribute(forName: "id")?.stringValue
            let info: (name: String?, path: String?)? = fileID.flatMap { fileInfo[$0] }
            var raws: [String] = []
            if let s = ci.elements(forName: "name").first?.stringValue { raws.append(s) }
            if let s = file.elements(forName: "name").first?.stringValue ?? info?.name { raws.append(s) }
            if let s = file.elements(forName: "pathurl").first?.stringValue ?? info?.path {
                raws.append(NameKeys.fileName(fromURL: s))
            }
            n += 1
            if let r = makeRef(label: "\(label) #\(n) (\(isAudio ? "A" : "V"))", raws: raws,
                               isVideo: !isAudio, isAudio: isAudio) {
                refs.append(r)
            }
        }
        return refs
    }
}

/// Walks an FCPX timeline, following compound clips and only the active multicam angles.
final class FCPXWalker {
    let byID: [String: XMLElement]
    var used: [String] = []
    private var usedSet = Set<String>()
    private var visited = Set<String>()

    init(byID: [String: XMLElement]) { self.byID = byID }

    func walkChildren(_ e: XMLElement) {
        for case let c as XMLElement in e.children ?? [] { visit(c) }
    }

    func visit(_ c: XMLElement) {
        if let ref = c.attribute(forName: "ref")?.stringValue, let target = byID[ref] {
            if target.name == "asset" {
                if usedSet.insert(ref).inserted { used.append(ref) }
            } else if target.name == "media" {
                if c.name == "mc-clip", let mc = target.elements(forName: "multicam").first {
                    let angles = Set(c.elements(forName: "mc-source")
                        .filter { ($0.attribute(forName: "srcEnable")?.stringValue ?? "all") != "none" }
                        .compactMap { $0.attribute(forName: "angleID")?.stringValue })
                    let key = ref + "|" + angles.sorted().joined(separator: ",")
                    if visited.insert(key).inserted {
                        for angle in mc.elements(forName: "mc-angle") {
                            let id = angle.attribute(forName: "angleID")?.stringValue ?? ""
                            if angles.isEmpty || angles.contains(id) { walkChildren(angle) }
                        }
                    }
                } else if visited.insert(ref).inserted {
                    walkChildren(target)
                }
            }
        }
        walkChildren(c)
    }
}

enum FCPXParser {
    static func parse(_ doc: XMLDocument, label: String) -> [TimelineRef] {
        guard let root = doc.rootElement() else { return [] }
        var byID: [String: XMLElement] = [:]
        for res in root.elements(forName: "resources") {
            for case let e as XMLElement in res.children ?? [] {
                if let id = e.attribute(forName: "id")?.stringValue { byID[id] = e }
            }
        }

        let walker = FCPXWalker(byID: byID)
        let sequences = ((try? root.nodes(forXPath: "//project/sequence")) ?? []).compactMap { $0 as? XMLElement }
        if !sequences.isEmpty {
            for s in sequences { walker.walkChildren(s) }
        } else {
            // Export of clips/events without a project.
            for e in ((try? root.nodes(forXPath: "//event")) ?? []).compactMap({ $0 as? XMLElement }) {
                walker.walkChildren(e)
            }
        }
        var assetIDs = walker.used
        if assetIDs.isEmpty {
            assetIDs = byID.filter { $0.value.name == "asset" }.map { $0.key }.sorted()
        }

        var refs: [TimelineRef] = []
        for id in assetIDs {
            guard let a = byID[id] else { continue }
            var raws: [String] = []
            let name = a.attribute(forName: "name")?.stringValue ?? id
            raws.append(name)
            if let src = a.attribute(forName: "src")?.stringValue { raws.append(NameKeys.fileName(fromURL: src)) }
            for rep in a.elements(forName: "media-rep")
            where (rep.attribute(forName: "kind")?.stringValue ?? "original-media") == "original-media" {
                if let src = rep.attribute(forName: "src")?.stringValue { raws.append(NameKeys.fileName(fromURL: src)) }
            }
            let hasVideo = a.attribute(forName: "hasVideo")?.stringValue == "1"
            let hasAudio = a.attribute(forName: "hasAudio")?.stringValue == "1"
            let video = hasVideo || !hasAudio
            if let r = makeRef(label: "\(label) · \(name)", raws: raws, isVideo: video, isAudio: !video) {
                refs.append(r)
            }
        }
        return refs
    }
}

enum OTIOParser {
    static func parse(data: Data, label: String) throws -> [TimelineRef] {
        let json = try JSONSerialization.jsonObject(with: data)
        var refs: [TimelineRef] = []
        var n = 0

        func visit(_ obj: Any, kind: String) {
            if let arr = obj as? [Any] {
                for x in arr { visit(x, kind: kind) }
                return
            }
            guard let d = obj as? [String: Any] else { return }
            let schema = (d["OTIO_SCHEMA"] as? String) ?? ""
            var k = kind
            if schema.hasPrefix("Track.") { k = (d["kind"] as? String) ?? kind }

            if schema.hasPrefix("Clip.") {
                var raws: [String] = []
                if let name = d["name"] as? String { raws.append(name) }
                var mediaRefs: [[String: Any]] = []
                if let mr = d["media_reference"] as? [String: Any] { mediaRefs.append(mr) }
                if let mrs = d["media_references"] as? [String: Any] {
                    for v in mrs.values { if let m = v as? [String: Any] { mediaRefs.append(m) } }
                }
                for m in mediaRefs {
                    if let t = m["target_url"] as? String { raws.append(NameKeys.fileName(fromURL: t)) }
                    if let p = m["name_prefix"] as? String { raws.append(p) }
                    if let nm = m["name"] as? String, !nm.isEmpty { raws.append(nm) }
                }
                n += 1
                let isAudio = k.lowercased() == "audio"
                if let r = makeRef(label: "\(label) #\(n) (\(isAudio ? "A" : "V"))", raws: raws,
                                   isVideo: !isAudio, isAudio: isAudio) {
                    refs.append(r)
                }
                return
            }
            for (key, v) in d where key != "metadata" { visit(v, kind: k) }
        }

        visit(json, kind: "Video")
        return refs
    }
}

enum TimelineLoader {
    static func load(_ url: URL) throws -> [TimelineRef] {
        let ext = url.pathExtension.lowercased()
        let label = url.lastPathComponent
        switch ext {
        case "edl":
            let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            return EDLParser.parse(text: text, label: label)
        case "otio":
            return try OTIOParser.parse(data: Data(contentsOf: url), label: label)
        case "xml", "fcpxml", "fcpxmld":
            var fileURL = url
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                fileURL = url.appendingPathComponent("Info.fcpxml")
            }
            let doc = try XMLDocument(contentsOf: fileURL, options: [])
            switch doc.rootElement()?.name {
            case "xmeml": return FCP7Parser.parse(doc, label: label)
            case "fcpxml": return FCPXParser.parse(doc, label: label)
            default: throw SimpleError("Not a Final Cut Pro 7 or Final Cut Pro X XML file.")
            }
        case "aaf":
            throw SimpleError("AAF isn’t supported. Export an EDL, FCP7 XML or OTIO from the timeline instead.")
        default:
            throw SimpleError("Unsupported file type .\(ext).")
        }
    }
}

// MARK: - Drive scanning

enum DriveScanner {
    static let skipFolders: Set<String> = ["avid mediafiles", "omfi mediafiles"]
    static let skipPackages: Set<String> = ["fcpbundle", "photoslibrary", "app", "fcpxmld", "logicx", "band"]

    static func relative(_ url: URL, _ rootPath: String) -> String {
        let p = url.standardizedFileURL.path
        if p.hasPrefix(rootPath) {
            return String(p.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    static func listMedia(root: URL, token: CancelToken, report: (Int, Int, String) -> Void) -> [Candidate] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles],
                                     errorHandler: { _, _ in true }) else { return [] }
        let rootPath = root.standardizedFileURL.path
        let rootName = root.lastPathComponent.isEmpty ? "Source" : root.lastPathComponent
        var out: [Candidate] = []
        var visited = 0
        var lastReport = Date.distantPast

        while let obj = en.nextObject() {
            if token.isCancelled { break }
            guard let url = obj as? URL else { continue }
            visited += 1
            let vals = try? url.resourceValues(forKeys: Set(keys))

            if vals?.isDirectory == true {
                if skipFolders.contains(url.lastPathComponent.lowercased())
                    || skipPackages.contains(url.pathExtension.lowercased()) {
                    en.skipDescendants()
                }
                if Date().timeIntervalSince(lastReport) > 0.3 {
                    lastReport = Date()
                    report(out.count, visited, relative(url, rootPath))
                }
                continue
            }
            guard vals?.isRegularFile == true,
                  scanExtensions.contains(url.pathExtension.lowercased()) else { continue }
            out.append(Candidate(url: url, rootName: rootName, rel: relative(url, rootPath),
                                 size: Int64(vals?.fileSize ?? 0)))
        }
        report(out.count, visited, "")
        return out
    }
}

// MARK: - File classification

enum MXFInspector {
    static func has(_ data: Data, _ bytes: [UInt8]) -> Bool {
        data.range(of: Data(bytes)) != nil
    }

    static func hasText(_ data: Data, _ s: String) -> Bool {
        has(data, Array(s.utf8)) || has(data, s.utf8.flatMap { [UInt8(0), $0] })
    }

    static func isOPAtom(_ data: Data) -> Bool {
        let pattern = Data([0x0d, 0x01, 0x02, 0x01, 0x10])
        let prefix: [UInt8] = [0x06, 0x0e, 0x2b, 0x34, 0x04, 0x01, 0x01]
        var start = data.startIndex
        while start < data.endIndex, let r = data.range(of: pattern, in: start..<data.endIndex) {
            let s = r.lowerBound - 8
            if s >= data.startIndex, data[s..<(s + 7)].elementsEqual(prefix) { return true }
            start = r.upperBound
        }
        return false
    }

    static func classify(url: URL) -> FileType {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return FileType(category: "MXF · Other", folder: "MXF_Other", family: .video, reason: "Could not read header")
        }
        defer { try? fh.close() }
        let data = Data((try? fh.read(upToCount: 512 * 1024)) ?? Data())

        if hasText(data, "Avid") || isOPAtom(data) {
            return FileType(category: "MXF · Avid media (not camera original)", folder: "MXF_Avid", family: .avid,
                            reason: "Avid / OP-Atom MXF")
        }
        if hasText(data, "ARRI") {
            return FileType(category: "MXF · ARRI", folder: "MXF_ARRI", family: .camera, reason: "ARRI camera original")
        }
        if hasText(data, "Sony") {
            return FileType(category: "MXF · Sony", folder: "MXF_Sony", family: .camera, reason: "Sony camera original")
        }
        if hasText(data, "Canon") {
            return FileType(category: "MXF · Canon", folder: "MXF_Canon", family: .camera, reason: "Canon camera original")
        }
        if hasText(data, "Panasonic") {
            return FileType(category: "MXF · Panasonic", folder: "MXF_Panasonic", family: .camera, reason: "Panasonic camera original")
        }
        return FileType(category: "MXF · Other", folder: "MXF_Other", family: .video, reason: "MXF from an unidentified source")
    }
}

enum Classifier {
    static func classify(url: URL, relativePath: String) -> FileType {
        let lowerPath = relativePath.lowercased()
        if lowerPath.contains("avid mediafiles") || lowerPath.contains("omfi mediafiles") {
            return FileType(category: "MXF · Avid media (not camera original)", folder: "MXF_Avid", family: .avid,
                            reason: "Inside an Avid MediaFiles folder")
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mxf": return MXFInspector.classify(url: url)
        case "r3d": return FileType(category: "R3D · RED RAW", folder: "R3D", family: .camera, reason: "RED camera original")
        case "rmd": return FileType(category: "RMD · RED metadata", folder: "R3D", family: .sidecar, reason: "RED metadata sidecar")
        case "braw": return FileType(category: "BRAW · Blackmagic RAW", folder: "BRAW", family: .camera, reason: "Blackmagic RAW")
        case "crm": return FileType(category: "CRM · Canon Cinema RAW Light", folder: "CRM", family: .camera, reason: "Canon RAW")
        case "nev": return FileType(category: "NEV · Nikon N-RAW", folder: "NEV", family: .camera, reason: "Nikon RAW")
        case "cine": return FileType(category: "CINE · Phantom", folder: "CINE", family: .camera, reason: "Phantom RAW")
        case "ari", "arx": return FileType(category: "ARI · ARRIRAW frames", folder: "ARI", family: .camera, reason: "ARRIRAW frame sequence")
        case "dng": return FileType(category: "DNG · RAW frames", folder: "DNG", family: .camera, reason: "DNG frame sequence")
        case "exr": return FileType(category: "EXR · Frames", folder: "EXR", family: .video, reason: "EXR frame sequence")
        case "dpx": return FileType(category: "DPX · Frames", folder: "DPX", family: .video, reason: "DPX frame sequence")
        case "mov": return FileType(category: "MOV · QuickTime (incl. ProRes RAW)", folder: "MOV", family: .camera, reason: "QuickTime movie")
        case "mp4", "m4v": return FileType(category: "MP4 · Video", folder: "MP4", family: .video, reason: "MP4 video")
        case "wav", "bwf": return FileType(category: "WAV · Audio", folder: "WAV", family: .audio, reason: "WAV / Broadcast WAV")
        case "aif", "aiff", "aifc": return FileType(category: "AIFF · Audio", folder: "AIFF", family: .audio, reason: "AIFF audio")
        default:
            let isAudio = audioExtensions.contains(ext)
            return FileType(category: "\(ext.uppercased()) · \(isAudio ? "Audio" : "Video")", folder: ext.uppercased(),
                            family: isAudio ? .audio : .video, reason: ".\(ext) file")
        }
    }
}

enum Matcher {
    /// Exact match on the clip name, or (optionally) a truncated 6–8 character
    /// reel name such as A001C003 from a strict CMX3600 EDL.
    static func match(key: String, base: String, wanted: Set<String>, shortWanted: Set<String>,
                      allowPartial: Bool) -> (name: String, partial: Bool)? {
        if wanted.contains(key) { return (key, false) }
        if wanted.contains(base) { return (base, false) }
        guard allowPartial else { return nil }
        for len in stride(from: 8, through: 6, by: -1) where key.count > len {
            let p = String(key.prefix(len))
            if shortWanted.contains(p) { return (p, true) }
        }
        return nil
    }
}

// MARK: - Copy engine

enum Copier {
    static let chunk = 8 * 1024 * 1024

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5(of url: URL, token: CancelToken, onProgress: (Int64) -> Void) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        _ = fcntl(fh.fileDescriptor, F_NOCACHE, 1)
        var hasher = Insecure.MD5()
        var total: Int64 = 0
        while true {
            if token.isCancelled { throw CancellationError() }
            let d = try autoreleasepool { try fh.read(upToCount: chunk) ?? Data() }
            if d.isEmpty { break }
            hasher.update(data: d)
            total += Int64(d.count)
            onProgress(total)
        }
        return hex(hasher.finalize())
    }

    static func copy(from src: URL, to dst: URL, verify: Bool, token: CancelToken,
                     onProgress: (Int64, CopyPhase) -> Void) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = dst.appendingPathExtension("partial")
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw SimpleError("Cannot create file on destination")
        }

        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: partial)
        _ = fcntl(output.fileDescriptor, F_NOCACHE, 1)

        var hasher = Insecure.MD5()
        var written: Int64 = 0
        do {
            while true {
                if token.isCancelled { throw CancellationError() }
                let data = try autoreleasepool { try input.read(upToCount: chunk) ?? Data() }
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                hasher.update(data: data)
                written += Int64(data.count)
                onProgress(written, .copying)
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? fm.removeItem(at: partial)
            throw error
        }

        let srcHash = hex(hasher.finalize())
        guard let srcSize = fileSize(src), let dstSize = fileSize(partial), srcSize == dstSize else {
            try? fm.removeItem(at: partial)
            throw SimpleError("Size mismatch after copy")
        }

        if verify {
            do {
                let dstHash = try md5(of: partial, token: token) { n in onProgress(n, .verifying) }
                if dstHash != srcHash {
                    try? fm.removeItem(at: partial)
                    throw SimpleError("Checksum mismatch — copy deleted")
                }
            } catch {
                try? fm.removeItem(at: partial)
                throw error
            }
        }

        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: partial, to: dst)

        if let attrs = try? fm.attributesOfItem(atPath: src.path), let mod = attrs[.modificationDate] {
            let created = attrs[.creationDate] ?? mod
            try? fm.setAttributes([.modificationDate: mod, .creationDate: created], ofItemAtPath: dst.path)
        }
        return srcHash
    }
}

// MARK: - Space audit

struct SpaceAudit {
    static let margin: Int64 = 512 * 1024 * 1024   // headroom kept free on the destination

    var fileCount = 0
    var total: Int64 = 0
    var byCategory: [CategoryTotal] = []
    var hasDest = false
    var free: Int64? = nil
    var alreadyCount = 0
    var already: Int64 = 0

    var toCopy: Int64 { total - already }
    var leftAfter: Int64? { free.map { $0 - toCopy } }
    var fits: Bool? { free.map { toCopy + SpaceAudit.margin <= $0 } }
    var shortfall: Int64 { max(0, toCopy + SpaceAudit.margin - (free ?? 0)) }

    var summaryLines: [String] {
        var l: [String] = []
        l.append("Pull list total:        \(formatTB(total))  (\(formatBytes(total)), \(fileCount) files)")
        for c in byCategory {
            l.append("   \(c.name): \(formatTB(c.bytes))  (\(formatBytes(c.bytes)), \(c.count) files)")
        }
        if hasDest {
            l.append("Already on destination: \(formatTB(already))  (\(alreadyCount) files, skipped)")
            l.append("Still to transfer:      \(formatTB(toCopy))  (\(formatBytes(toCopy)))")
            if let f = free {
                l.append("Destination free:       \(formatTB(f))  (\(formatBytes(f)))")
                if fits == true, let left = leftAfter {
                    l.append("Result:                 FITS — \(formatTB(left)) left after transfer")
                } else {
                    l.append("Result:                 DOES NOT FIT — short by \(formatTB(shortfall))")
                }
            }
        }
        return l
    }
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    @Published var timelineURLs: [URL] = []
    @Published var timelineInfo: [String] = []
    @Published var refs: [TimelineRef] = []
    @Published var sourceRoots: [URL] = []
    @Published var destRoot: URL?
    @Published var destFree: Int64?
    @Published var files: [FoundFile] = []
    @Published var groupOrder: [String] = []
    @Published var groupMembers: [String: [Int]] = [:]
    @Published var expanded: Set<String> = []
    @Published var alreadyPresent: Set<Int> = []
    @Published var unmatched: [TimelineRef] = []
    @Published var includeVideo = true
    @Published var includeAudio = true
    @Published var allowPartial = true
    @Published var layout: Layout = .byRoll
    @Published var verify = true
    @Published var isBusy = false
    @Published var hasScanned = false
    @Published var progress: Double? = nil
    @Published var status = "Add a timeline export (EDL, XML, FCPXML or OTIO) to begin — or drop it on this window."
    @Published var detail = ""
    @Published var showUnmatched = false
    @Published var audit = SpaceAudit()

    private var token = CancelToken()
    private var activity: NSObjectProtocol?

    var activeRefs: [TimelineRef] {
        refs.filter { (includeVideo && $0.isVideo) || (includeAudio && $0.isAudio) }
    }
    var videoRefCount: Int { refs.filter { $0.isVideo }.count }
    var audioRefCount: Int { refs.filter { $0.isAudio }.count }
    var selectedCount: Int { files.filter { $0.selected }.count }

    // MARK: Selection & groups

    func toggleFile(_ i: Int) {
        guard files.indices.contains(i) else { return }
        files[i].selected.toggle()
        refreshAudit()
    }

    func groupStats(_ cat: String) -> GroupStats {
        var s = GroupStats()
        for i in groupMembers[cat] ?? [] where files.indices.contains(i) {
            let f = files[i]
            s.count += 1
            s.bytes += f.size
            if !f.isDuplicate { s.selectable += 1 }
            if f.selected { s.selected += 1; s.selectedBytes += f.size }
        }
        return s
    }

    func toggleGroup(_ cat: String) {
        let members = (groupMembers[cat] ?? []).filter { files.indices.contains($0) }
        let selectable = members.filter { !files[$0].isDuplicate }
        let pool = selectable.isEmpty ? members : selectable
        let full = !pool.isEmpty && pool.allSatisfy { files[$0].selected }
        for i in members {
            files[i].selected = full ? false : (selectable.isEmpty || !files[i].isDuplicate)
        }
        refreshAudit()
    }

    func toggleExpanded(_ cat: String) {
        if expanded.contains(cat) { expanded.remove(cat) } else { expanded.insert(cat) }
    }
    func expandAll() { expanded = Set(groupOrder) }
    func collapseAll() { expanded = [] }

    func selectAll() {
        for i in files.indices { files[i].selected = !files[i].isDuplicate && files[i].type.family != .avid }
        refreshAudit()
    }
    func selectNone() {
        for i in files.indices { files[i].selected = false }
        refreshAudit()
    }

    func setState(_ i: Int, _ s: String) {
        if files.indices.contains(i) { files[i].state = s }
    }

    func cancel() {
        token.cancel()
        status = "Cancelling…"
    }

    // MARK: Audit

    /// Checks which files are already on the destination (same path and size).
    func recheckDestination() {
        guard let d = destRoot else { alreadyPresent = []; return }
        var s = Set<Int>()
        for i in files.indices
        where fileSize(d.appendingPathComponent(destinationRelPath(files[i], layout: layout))) == files[i].size {
            s.insert(i)
        }
        alreadyPresent = s
    }

    func refreshAudit() {
        var a = SpaceAudit()
        if let d = destRoot {
            a.hasDest = true
            a.free = freeSpace(d)
            destFree = a.free
        }
        var cats: [String: (Int, Int64)] = [:]
        for (i, f) in files.enumerated() where f.selected {
            a.fileCount += 1
            a.total += f.size
            let c = cats[f.type.category] ?? (0, 0)
            cats[f.type.category] = (c.0 + 1, c.1 + f.size)
            if alreadyPresent.contains(i) {
                a.already += f.size
                a.alreadyCount += 1
            }
        }
        a.byCategory = groupOrder.compactMap { name in
            cats[name].map { CategoryTotal(name: name, count: $0.0, bytes: $0.1) }
        }
        audit = a
    }

    // MARK: Timelines

    func addTimelines(_ urls: [URL]) {
        var problems: [String] = []
        for u in urls {
            let ext = u.pathExtension.lowercased()
            if !timelineExtensions.contains(ext) && ext != "aaf" {
                problems.append("\(u.lastPathComponent): not a supported timeline file")
                continue
            }
            if timelineURLs.contains(u) { continue }
            do {
                let r = try TimelineLoader.load(u)
                if r.isEmpty {
                    problems.append("\(u.lastPathComponent): no clips found in this file")
                    continue
                }
                timelineURLs.append(u)
                refs += r
                let v = r.filter { $0.isVideo }.count
                let a = r.filter { $0.isAudio }.count
                timelineInfo.append("\(u.lastPathComponent) — \(v) video, \(a) audio")
            } catch {
                problems.append("\(u.lastPathComponent): \(error.localizedDescription)")
            }
        }
        resetResults()
        status = "\(timelineURLs.count) timeline file(s) loaded: \(videoRefCount) video and \(audioRefCount) audio references."
        if !problems.isEmpty {
            showAlert("Some files could not be read", problems.joined(separator: "\n"))
        }
    }

    func clearTimelines() {
        timelineURLs = []
        timelineInfo = []
        refs = []
        resetResults()
        status = "Add a timeline export (EDL, XML, FCPXML or OTIO) to begin — or drop it on this window."
    }

    func resetResults() {
        groupOrder = []
        groupMembers = [:]
        expanded = []
        alreadyPresent = []
        files = []
        unmatched = []
        hasScanned = false
        detail = ""
        audit = SpaceAudit()
    }

    // MARK: Sources / destination

    func addSource(_ u: URL) {
        if !sourceRoots.contains(u) { sourceRoots.append(u) }
        resetResults()
    }
    func clearSources() {
        sourceRoots = []
        resetResults()
    }
    func setDestination(_ u: URL) {
        destRoot = u
        recheckDestination()
        refreshAudit()
    }
    func layoutChanged() {
        recheckDestination()
        refreshAudit()
    }

    // MARK: Scan

    func scan() {
        guard !sourceRoots.isEmpty, !activeRefs.isEmpty, !isBusy else { return }
        let roots = sourceRoots
        let refs = activeRefs
        let wanted = Set(refs.flatMap { $0.names })
        let shortWanted = Set(wanted.filter { (6...8).contains($0.count) })
        let allowPartial = self.allowPartial
        let token = CancelToken()
        self.token = token
        resetResults()
        isBusy = true
        progress = nil
        status = "Scanning source drive(s)…"
        let model = self

        Task.detached(priority: .userInitiated) {
            var candidates: [Candidate] = []
            for (n, root) in roots.enumerated() {
                if token.isCancelled { break }
                let label = roots.count > 1 ? "Scanning source \(n + 1) of \(roots.count)…" : "Scanning…"
                candidates += DriveScanner.listMedia(root: root, token: token) { found, visited, path in
                    Task { @MainActor in
                        model.status = "\(label) \(visited) items checked, \(found) media files so far"
                        model.detail = path
                    }
                }
            }

            var matched: [FoundFile] = []
            var lastUI = Date.distantPast
            for (i, c) in candidates.enumerated() {
                if token.isCancelled { break }
                let fileName = c.url.lastPathComponent
                let key = NameKeys.clipBase(fileName: fileName).lowercased()
                let base = (fileName as NSString).deletingPathExtension.lowercased()
                guard let m = Matcher.match(key: key, base: base, wanted: wanted, shortWanted: shortWanted,
                                            allowPartial: allowPartial) else { continue }
                let type = Classifier.classify(url: c.url, relativePath: c.rel)
                matched.append(FoundFile(url: c.url, rootName: c.rootName, relativePath: c.rel, size: c.size,
                                         matchedName: m.name, partialMatch: m.partial, type: type,
                                         selected: type.family != .avid))
                if Date().timeIntervalSince(lastUI) > 0.25 {
                    lastUI = Date()
                    let frac = Double(i + 1) / Double(max(candidates.count, 1))
                    let count = matched.count
                    await MainActor.run {
                        model.progress = frac
                        model.status = "Checking matches… \(count) found"
                        model.detail = fileName
                    }
                }
            }

            // Sort: camera originals, video, audio, sidecars, Avid; then type; then name.
            matched.sort {
                if $0.type.family != $1.type.family { return $0.type.family.rawValue < $1.type.family.rawValue }
                if $0.type.category != $1.type.category { return $0.type.category < $1.type.category }
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }

            // Same name + size found twice (backups, several drives): keep one.
            var seen = Set<String>()
            for i in matched.indices {
                let key = matched[i].url.lastPathComponent.lowercased() + "|\(matched[i].size)"
                if seen.contains(key) {
                    matched[i].selected = false
                    matched[i].isDuplicate = true
                    matched[i].state = "Duplicate — not selected"
                } else {
                    seen.insert(key)
                }
            }

            var order: [String] = []
            var members: [String: [Int]] = [:]
            for (i, f) in matched.enumerated() {
                if members[f.type.category] == nil { order.append(f.type.category); members[f.type.category] = [] }
                members[f.type.category]?.append(i)
            }

            let matchedNames = Set(matched.filter { $0.type.family != .avid }.map { $0.matchedName })
            var keys = Set<String>()
            var matchedRefs = 0
            var unmatched: [TimelineRef] = []
            for r in refs {
                if r.names.contains(where: { matchedNames.contains($0) }) {
                    matchedRefs += 1
                } else if keys.insert(r.names.sorted().joined(separator: "|")).inserted {
                    unmatched.append(r)
                }
            }

            let cancelled = token.isCancelled
            let finalMatched = matched
            let finalOrder = order
            let finalMembers = members
            let finalUnmatched = unmatched
            let finalMatchedRefs = matchedRefs
            let total = refs.count
            let scanned = candidates.count
            await MainActor.run {
                model.groupOrder = finalOrder
                model.groupMembers = finalMembers
                model.files = finalMatched
                model.unmatched = finalUnmatched
                model.hasScanned = !cancelled
                model.isBusy = false
                model.progress = nil
                model.detail = ""
                model.recheckDestination()
                model.refreshAudit()
                model.status = cancelled
                    ? "Scan cancelled."
                    : "Checked \(scanned) media files. Matched \(finalMatchedRefs) of \(total) timeline references in \(finalOrder.count) file types. Pull list: \(formatTB(model.audit.total))."
            }
        }
    }

    // MARK: Export pull list

    func exportCSV() {
        guard !files.isEmpty else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = "STRADA_Trim_Tool_Pull_List_\(timestamp()).csv"
        guard p.runModal() == .OK, let url = p.url else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Selected,File Type,File,Timeline Name,Size (bytes),Size,Source,Destination,Status"]
        for cat in groupOrder {
            for i in groupMembers[cat] ?? [] where files.indices.contains(i) {
                let f = files[i]
                lines.append([f.selected ? "yes" : "no", q(cat), q(f.url.lastPathComponent), q(f.matchedName),
                              String(f.size), q(formatBytes(f.size)), q(f.url.path),
                              q(destinationRelPath(f, layout: layout)), q(f.state)].joined(separator: ","))
            }
        }
        for r in unmatched {
            lines.append(["no", q("NOT FOUND"), "", q(r.display), "", "", "", "", q(r.label)].joined(separator: ","))
        }
        refreshAudit()
        lines.append("")
        lines.append(q("SPACE AUDIT"))
        for l in audit.summaryLines { lines.append(q(l.trimmingCharacters(in: .whitespaces))) }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            status = "Pull list saved to \(url.lastPathComponent)."
        } catch {
            showAlert("Could not save pull list", error.localizedDescription)
        }
    }

    // MARK: Transfer

    func transfer() {
        guard let dest = destRoot, !isBusy else { return }
        let plan: [(Int, FoundFile, URL, String)] = files.indices.compactMap { i in
            let f = files[i]
            guard f.selected else { return nil }
            let rel = destinationRelPath(f, layout: layout)
            return (i, f, dest.appendingPathComponent(rel), rel)
        }
        guard !plan.isEmpty else { return }

        for src in sourceRoots where isSameOrInside(dest, src) {
            showAlert("Destination overlaps a source",
                      "Pick a destination folder that is not inside a source folder (and vice versa).")
            return
        }

        let groups = Dictionary(grouping: plan, by: { $0.3.lowercased() })
        let clashes = groups.filter { $0.value.count > 1 }.map { $0.value[0].3 }.sorted()
        if !clashes.isEmpty {
            showAlert("Some files would overwrite each other",
                      "\(clashes.count) destination path(s) are used by more than one selected file:\n\n\(clashes.prefix(8).joined(separator: "\n"))\n\nDeselect the extras or choose “Keep source folder structure”.")
            return
        }

        recheckDestination()
        refreshAudit()
        let audit = self.audit
        if audit.fits == false {
            showAlert("Not enough space on destination",
                      audit.summaryLines.joined(separator: "\n") + "\n\nDeselect some files or file types, or choose a larger drive.")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Transfer \(formatTB(audit.toCopy)) to the destination?"
        confirm.informativeText = audit.summaryLines.joined(separator: "\n")
        confirm.addButton(withTitle: "Transfer")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let layout = self.layout
        let verify = self.verify
        let timelineNames = timelineURLs.map { $0.lastPathComponent }
        let unmatched = self.unmatched
        let sourcePaths = sourceRoots.map { $0.path }
        let total = plan.reduce(Int64(0)) { $0 + $1.1.size }
        let token = CancelToken()
        self.token = token
        isBusy = true
        progress = 0
        for (i, _, _, _) in plan { setState(i, "Queued") }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "STRADA Trim Tool is copying media")
        let model = self

        Task.detached(priority: .userInitiated) {
            let start = Date()
            var done: Int64 = 0
            var copied: Int64 = 0
            var lastUI = Date.distantPast
            var manifest: [String] = []
            var copiedList: [String] = []
            var failures: [String] = []
            var copiedCount = 0
            var skippedCount = 0
            var cancelled = false

            for (n, item) in plan.enumerated() {
                let (index, job, target, rel) = item
                if token.isCancelled { cancelled = true; break }
                let name = job.url.lastPathComponent

                if fileSize(target) == job.size {
                    done += job.size
                    skippedCount += 1
                    await MainActor.run { model.setState(index, "Already on destination — skipped") }
                    continue
                }

                let header = "File \(n + 1) of \(plan.count): \(name)"
                await MainActor.run {
                    model.setState(index, "Copying…")
                    model.status = header
                }

                let base = done
                let copiedBase = copied
                do {
                    let hash = try Copier.copy(from: job.url, to: target, verify: verify, token: token) { b, phase in
                        let now = Date()
                        guard now.timeIntervalSince(lastUI) > 0.25 else { return }
                        lastUI = now
                        let overall = phase == .copying ? base + b : base + job.size
                        let copiedSoFar = copiedBase + (phase == .copying ? b : job.size)
                        let elapsed = now.timeIntervalSince(start)
                        let speed = elapsed > 0 ? Double(copiedSoFar) / elapsed : 0
                        let eta = speed > 0 ? Double(total - overall) / speed : 0
                        let frac = total > 0 ? Double(overall) / Double(total) : 0
                        let text = "\(phase.rawValue) \(formatBytes(b)) of \(formatBytes(job.size)) · \(formatBytes(Int64(speed)))/s avg · about \(formatDuration(eta)) left"
                        let rowState = phase == .copying
                            ? "Copying \(Int(Double(b) / Double(max(job.size, 1)) * 100))%"
                            : "Verifying…"
                        Task { @MainActor in
                            model.progress = frac
                            model.detail = text
                            model.setState(index, rowState)
                        }
                    }
                    done += job.size
                    copied += job.size
                    copiedCount += 1
                    manifest.append("\(hash)  \(rel)")
                    copiedList.append(rel)
                    await MainActor.run { model.setState(index, verify ? "✓ Copied & verified" : "✓ Copied") }
                } catch is CancellationError {
                    cancelled = true
                    await MainActor.run { model.setState(index, "Cancelled") }
                    break
                } catch {
                    done += job.size
                    let msg = error.localizedDescription
                    failures.append("\(rel) — \(msg)")
                    await MainActor.run { model.setState(index, "✗ \(msg)") }
                }
            }

            let stamp = timestamp()
            if !manifest.isEmpty {
                try? (manifest.joined(separator: "\n") + "\n").write(
                    to: dest.appendingPathComponent("STRADA_Trim_Tool_\(stamp).md5"), atomically: true, encoding: .utf8)
            }
            var report = "STRADA Trim Tool transfer report — \(stamp)\n"
            report += "Timeline(s): \(timelineNames.joined(separator: ", "))\n"
            report += "Source(s):\n" + sourcePaths.map { "  \($0)" }.joined(separator: "\n") + "\n"
            report += "Destination: \(dest.path)\n"
            report += "Layout: \(layout.rawValue)\n"
            report += "Verification: \(verify ? "MD5, destination re-read" : "size only")\n\n"
            report += "--- Space audit (before transfer) ---\n" + audit.summaryLines.joined(separator: "\n") + "\n\n"
            report += "Copied: \(copiedCount) (\(formatBytes(copied)))\n"
            report += "Already present, skipped: \(skippedCount)\n"
            report += "Failed: \(failures.count)\n"
            if cancelled { report += "TRANSFER WAS CANCELLED before finishing.\n" }
            if !copiedList.isEmpty { report += "\n--- Copied ---\n" + copiedList.joined(separator: "\n") + "\n" }
            if !failures.isEmpty { report += "\n--- Failures ---\n" + failures.joined(separator: "\n") + "\n" }
            if !unmatched.isEmpty {
                report += "\n--- Timeline references not found on source(s) ---\n"
                report += unmatched.map { "\($0.label): \($0.display)" }.joined(separator: "\n") + "\n"
            }
            try? report.write(to: dest.appendingPathComponent("STRADA_Trim_Tool_\(stamp)_report.txt"),
                              atomically: true, encoding: .utf8)

            var summary = cancelled ? "Cancelled. " : "Done. "
            summary += "Copied \(copiedCount) file(s) (\(formatTB(copied)))"
            if skippedCount > 0 { summary += ", skipped \(skippedCount) already present" }
            if !failures.isEmpty { summary += ", \(failures.count) FAILED" }
            summary += ". Report and MD5 manifest saved to the destination."
            let finalSummary = summary
            let failed = !failures.isEmpty
            await MainActor.run { model.finishTransfer(finalSummary, failed: failed) }
        }
    }

    private func finishTransfer(_ summary: String, failed: Bool) {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        isBusy = false
        progress = 1
        detail = ""
        status = summary
        recheckDestination()
        refreshAudit()
        if failed { showAlert("Some files failed", summary) }
    }
}

@MainActor
func showAlert(_ title: String, _ message: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.runModal()
}

@MainActor
enum Panels {
    static func pickFolder(_ prompt: String, message: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        p.prompt = prompt
        p.message = message
        return p.runModal() == .OK ? p.url : nil
    }

    static func pickTimelines() -> [URL] {
        let p = NSOpenPanel()
        p.canChooseDirectories = true      // .fcpxmld can appear as a folder
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.treatsFilePackagesAsDirectories = false
        p.prompt = "Add"
        p.message = "Choose timeline exports: EDL, FCP7 XML, FCPX .fcpxml / .fcpxmld, or OpenTimelineIO .otio"
        return p.runModal() == .OK ? p.urls : []
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(label: Label("1. Timeline", systemImage: "film.stack")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Add Timeline…") { model.addTimelines(Panels.pickTimelines()) }
                        Button("Clear") { model.clearTimelines() }.disabled(model.timelineURLs.isEmpty)
                        Text("EDL · FCP7 XML · FCPX (.fcpxml / .fcpxmld) · OTIO")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Video (\(model.videoRefCount))", isOn: $model.includeVideo)
                        Toggle("Audio — production sound & SFX (\(model.audioRefCount))", isOn: $model.includeAudio)
                    }
                    if model.timelineInfo.isEmpty {
                        Text("No timeline loaded — or drop files on this window").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.timelineInfo, id: \.self) { t in
                            Text(t).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .padding(6)
                .disabled(model.isBusy)
            }

            GroupBox(label: Label("2. Source drive(s)", systemImage: "externaldrive")) {
                HStack(alignment: .top) {
                    Button("Add Source…") {
                        if let u = Panels.pickFolder("Add Source", message: "Choose a drive or folder that holds media") {
                            model.addSource(u)
                        }
                    }
                    Button("Clear") { model.clearSources() }.disabled(model.sourceRoots.isEmpty)
                    VStack(alignment: .leading, spacing: 2) {
                        if model.sourceRoots.isEmpty {
                            Text("No source selected").foregroundStyle(.secondary)
                        }
                        ForEach(model.sourceRoots, id: \.self) { u in
                            Text(u.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("Allow partial name matches", isOn: $model.allowPartial)
                        .help("Lets an 8-character CMX reel name like A001C003 match A001C003_220101_R1AB.mxf")
                    Button("Find Media") { model.scan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.sourceRoots.isEmpty || model.activeRefs.isEmpty)
                }
                .padding(6)
                .disabled(model.isBusy)
            }

            ResultsView()

            AuditPanel(audit: model.audit, hasScanned: model.hasScanned)

            GroupBox(label: Label("3. Destination drive", systemImage: "externaldrive.badge.plus")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Choose…") {
                            if let u = Panels.pickFolder("Use as Destination", message: "Choose where the pulled media should go") {
                                model.setDestination(u)
                            }
                        }
                        .disabled(model.isBusy)
                        Text(model.destRoot?.path ?? "Not selected")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        if let free = model.destFree {
                            Text("Free: \(formatTB(free))")
                                .foregroundStyle(model.audit.fits == false ? Color.red : Color.secondary)
                        }
                    }
                    HStack {
                        Picker("Organize:", selection: $model.layout) {
                            ForEach(Layout.allCases) { l in Text(l.rawValue).tag(l) }
                        }
                        .frame(maxWidth: 400)
                        .disabled(model.isBusy)
                        Toggle("Verify with MD5 checksum", isOn: $model.verify)
                            .disabled(model.isBusy)
                        Spacer()
                        if model.isBusy {
                            Button("Cancel", role: .cancel) { model.cancel() }
                        }
                        Button("Transfer \(model.selectedCount) File\(model.selectedCount == 1 ? "" : "s")") {
                            model.transfer()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.destRoot == nil || model.selectedCount == 0)
                    }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 4) {
                if model.isBusy || model.progress != nil {
                    ProgressView(value: model.progress)
                }
                Text(model.status)
                Text(model.detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding()
        .frame(minWidth: 1180, minHeight: 900)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy else { return false }
            model.addTimelines(urls)
            return true
        }
        .onChange(of: model.layout) { _, _ in model.layoutChanged() }
        .onChange(of: model.includeVideo) { _, _ in model.resetResults() }
        .onChange(of: model.includeAudio) { _, _ in model.resetResults() }
        .sheet(isPresented: $model.showUnmatched) {
            UnmatchedView(refs: model.unmatched)
        }
    }
}

struct ResultsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Found media by file type").font(.headline)
                if model.hasScanned {
                    Text("\(model.files.count) files in \(model.groupOrder.count) types · \(model.selectedCount) selected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.unmatched.isEmpty {
                    Button("Not Found (\(model.unmatched.count))…") { model.showUnmatched = true }
                }
                Button("Expand All") { model.expandAll() }.disabled(model.groupOrder.isEmpty)
                Button("Collapse All") { model.collapseAll() }.disabled(model.groupOrder.isEmpty)
                Button("Select All") { model.selectAll() }.disabled(model.files.isEmpty || model.isBusy)
                Button("Select None") { model.selectNone() }.disabled(model.files.isEmpty || model.isBusy)
                Button("Export Pull List…") { model.exportCSV() }.disabled(model.files.isEmpty || model.isBusy)
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("File").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Timeline name").frame(width: 190, alignment: .leading)
                    Text("Size").frame(width: 80, alignment: .trailing)
                    Text("Copy to").frame(width: 300, alignment: .leading)
                    Text("Status").frame(width: 190, alignment: .leading)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 50).padding(.trailing, 16).padding(.vertical, 4)
                Divider()
                ScrollView {
                    if model.groupOrder.isEmpty {
                        Text(model.hasScanned ? "No matching media found." : "Run “Find Media” to list matching files by type.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(30)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.groupOrder, id: \.self) { cat in
                                GroupHeaderView(category: cat)
                                if model.expanded.contains(cat) {
                                    ForEach(model.groupMembers[cat] ?? [], id: \.self) { i in
                                        FileRowView(index: i)
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(minHeight: 260)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        }
    }
}

struct GroupHeaderView: View {
    @EnvironmentObject var model: AppModel
    let category: String

    var body: some View {
        let st = model.groupStats(category)
        let isOpen = model.expanded.contains(category)
        HStack(spacing: 8) {
            Button { model.toggleExpanded(category) } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Close" : "Open")

            Button { model.toggleGroup(category) } label: {
                Image(systemName: st.icon)
                    .font(.title3)
                    .foregroundStyle(st.selected > 0 ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .help("Select or deselect every file of this type")

            Button { model.toggleExpanded(category) } label: {
                HStack(spacing: 10) {
                    Text(category).bold()
                    Text("\(st.count) file\(st.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("\(st.selected) selected · \(formatBytes(st.selectedBytes)) of \(formatBytes(st.bytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
    }
}

struct FileRowView: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    var body: some View {
        if model.files.indices.contains(index) {
            let f = model.files[index]
            let onDest = model.alreadyPresent.contains(index)
            let dest = destinationRelPath(f, layout: model.layout)
            HStack(spacing: 8) {
                Button { model.toggleFile(index) } label: {
                    Image(systemName: f.selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(f.selected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)

                Text(f.url.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(f.url.path)\n\(f.type.reason)")
                Text(f.partialMatch ? "≈ \(f.matchedName)" : f.matchedName)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: 190, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .help(f.partialMatch ? "Partial (truncated reel name) match" : "Exact match")
                Text(formatBytes(f.size))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                Text(dest)
                    .lineLimit(1).truncationMode(.head)
                    .frame(width: 300, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .help(dest)
                Text(f.state.isEmpty && onDest ? "On destination" : f.state)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: 190, alignment: .leading)
            }
            .padding(.leading, 34)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
        }
    }
}

struct AuditItem: View {
    let title: String
    let value: String
    let note: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold().foregroundStyle(color)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AuditPanel: View {
    let audit: SpaceAudit
    let hasScanned: Bool

    var body: some View {
        GroupBox(label: Label("Space audit", systemImage: "chart.bar.doc.horizontal")) {
            if !hasScanned {
                Text("Run “Find Media” to calculate the total size of the pull list.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } else {
                HStack(alignment: .top, spacing: 32) {
                    AuditItem(title: "PULL LIST TOTAL", value: formatTB(audit.total),
                              note: "\(audit.fileCount) files · \(formatBytes(audit.total))")
                    AuditItem(title: "FILE TYPES SELECTED", value: "\(audit.byCategory.count)",
                              note: audit.byCategory.map { $0.name.components(separatedBy: " ·").first ?? $0.name }
                                .joined(separator: ", "))
                    if audit.hasDest {
                        AuditItem(title: "ALREADY ON DESTINATION", value: formatTB(audit.already),
                                  note: "\(audit.alreadyCount) files — will be skipped")
                        AuditItem(title: "TO TRANSFER", value: formatTB(audit.toCopy), note: formatBytes(audit.toCopy))
                        AuditItem(title: "DESTINATION FREE", value: audit.free.map { formatTB($0) } ?? "—",
                                  note: audit.free.map { formatBytes($0) } ?? "")
                        if audit.fits == true, let left = audit.leftAfter {
                            AuditItem(title: "RESULT", value: "Fits", note: "\(formatTB(left)) left after transfer",
                                      color: .green)
                        } else if audit.fits == false {
                            AuditItem(title: "RESULT", value: "Won’t fit", note: "Short by \(formatTB(audit.shortfall))",
                                      color: .red)
                        }
                    } else {
                        AuditItem(title: "DESTINATION", value: "—", note: "Choose a destination to check free space")
                    }
                    Spacer()
                }
                .padding(6)
            }
        }
    }
}

struct UnmatchedView: View {
    let refs: [TimelineRef]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline references not found on the source drive(s)").font(.headline)
            Text("Common reasons: titles or generated media, VFX, media on another drive, clips renamed during the edit, or audio that references a synced clip name instead of the WAV file name.")
                .font(.caption).foregroundStyle(.secondary)
            List(refs, id: \.self) { r in
                VStack(alignment: .leading) {
                    Text(r.display)
                    Text(r.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Copy List") {
                    let text = refs.map { "\($0.label)\t\($0.display)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 660, height: 520)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct StradaTrimToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("STRADA Trim Tool") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
    }
}
