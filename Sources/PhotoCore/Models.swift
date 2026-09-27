import Foundation
import CryptoKit
import Darwin

public enum PhotoError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
public struct CaptureTime: Codable, Equatable, Sendable {
    public var value: String // EXIF wall-clock time; never assume a timezone.
    public var offset: String?
    public var subseconds: String?
    public init(_ value: String, offset: String? = nil, subseconds: String? = nil) { self.value = value; self.offset = offset; self.subseconds = subseconds }
    public static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    public static func formatter() -> DateFormatter { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.isLenient = false; return f }
    public var date: Date? { Self.formatter().date(from: value) }
    public var display: String { value + (offset.map { " \($0)" } ?? "（时区未知）") }
    public func shifted(seconds: Int) throws -> CaptureTime {
        guard let d = date, let result = Self.calendar.date(byAdding: .second, value: seconds, to: d), (1...9999).contains(Self.calendar.component(.year, from: result)) else { throw PhotoError.message("拍摄时间无效或超出范围") }
        return CaptureTime(Self.formatter().string(from: result), offset: offset, subseconds: subseconds)
    }
    public static func parse(_ text: String?, offset: String? = nil, subseconds: String? = nil) -> CaptureTime? {
        guard let text, text.count >= 19 else { return nil }
        let base = String(text.prefix(19)).replacingOccurrences(of: "T", with: " ")
        let normalized = String(base.prefix(10)).replacingOccurrences(of: "-", with: ":") + String(base.dropFirst(10))
        let suffix = String(text.dropFirst(19))
        let pattern = #"([+-]\d{2}:\d{2}|Z)$"#
        let range = suffix.range(of: pattern, options: .regularExpression)
        let zone = offset ?? range.map { String(suffix[$0]) == "Z" ? "+00:00" : String(suffix[$0]) }
        let fraction = suffix.hasPrefix(".") ? String(suffix.dropFirst().prefix(while: { $0.isNumber })) : nil
        let result = CaptureTime(normalized, offset: zone, subseconds: subseconds ?? fraction)
        return result.date == nil ? nil : result
    }
}
public enum TimeEdit: Sendable {
    case shift(Int), set(String), dateOnly(String)
    public func apply(to original: CaptureTime?) throws -> CaptureTime {
        switch self {
        case .shift(let seconds): guard let original else { throw PhotoError.message("缺少拍摄时间，无法偏移") }; return try original.shifted(seconds: seconds)
        case .set(let value): guard let parsed = CaptureTime.parse(value, offset: original?.offset) else { throw PhotoError.message("请输入有效日期时间") }; return parsed
        case .dateOnly(let day):
            guard let original else { throw PhotoError.message("缺少原时间，无法保留时分秒") }
            guard let parsed = CaptureTime.parse(day + " " + String(original.value.suffix(8)), offset: original.offset, subseconds: original.subseconds) else { throw PhotoError.message("请输入有效日期") }; return parsed
        }
    }
}
public struct PhotoMember: Codable, Equatable, Sendable {
    public var path: String
    public var bytes: Int64
    public var capture: CaptureTime?
    public var format: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
    public var isRAW: Bool { Photo.raw.contains(format) }
    public init(path: String, bytes: Int64 = 0, capture: CaptureTime? = nil) {
        self.path = path; self.bytes = bytes; self.capture = capture
    }
}
public struct Photo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var path: String
    public var source: String
    public var capture: CaptureTime?
    public var latitude: Double?
    public var longitude: Double?
    public var place: String?
    public var manualPlace: Bool = false
    public var sidecar: String?
    public var problem: String?
    public var bytes: Int64 = 0
    // Optional storage keeps pre-grouping indexes and history snapshots decodable.
    public var members: [PhotoMember]?
    public var sidecarCapture: CaptureTime?
    public var sidecarBytes: Int64?
    public var captureSource: String?
    public var notice: String?
    public var files: [PhotoMember] { members ?? [PhotoMember(path: path, bytes: bytes, capture: capture)] }
    public var isPair: Bool { files.count == 2 && files.contains { $0.format == "cr2" } && files.contains { ["jpg", "jpeg"].contains($0.format) } }
    public var hasRAW: Bool { files.contains { $0.isRAW } }
    public var allPaths: [String] { files.map(\.path) + (sidecar.map { [$0] } ?? []) }
    public var previewPaths: [String] { files.sorted { !$0.isRAW && $1.isRAW }.map(\.path) }
    public var formatLabel: String { isPair ? "JPG + CR2" : URL(fileURLWithPath: path).pathExtension.uppercased() }
    public var timeDiffers: Bool { Set(files.compactMap { $0.capture.map { $0.display + ($0.subseconds ?? "") } }).count > 1 }
    public var isRAW: Bool { Self.raw.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var year: String { capture.map { String($0.value.prefix(4)) } ?? "未知时间" }
    public static let raw: Set<String> = ["cr2", "cr3", "nef", "nrw", "arw", "sr2", "srf", "raf", "rw2", "orf", "pef", "dng", "3fr", "fff", "iiq", "rwl", "srw", "raw", "kdc", "mos", "mrw", "x3f"]
    public static let supported = raw.union(["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"])
    public init(path: String, source: String = "") { self.id = UUID().uuidString; self.path = path; self.source = source }
    public static func ==(l: Photo, r: Photo) -> Bool { l.id == r.id && l.path == r.path && l.capture == r.capture && l.place == r.place && l.problem == r.problem && l.members == r.members && l.sidecar == r.sidecar && l.sidecarCapture == r.sidecarCapture && l.sidecarBytes == r.sidecarBytes && l.captureSource == r.captureSource && l.notice == r.notice && l.bytes == r.bytes && l.latitude == r.latitude && l.longitude == r.longitude && l.manualPlace == r.manualPlace && l.source == r.source }
    public func hash(into h: inout Hasher) { h.combine(id) }
}
/// File identity and change state; rename changes ctime even when content is unchanged.
public struct FileSnapshot: Codable, Equatable, Sendable {
    public var size: Int64
    public var device: Int32
    public var inode: UInt64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var changedSeconds: Int64
    public var changedNanoseconds: Int64
    public static func read(_ path: String) throws -> FileSnapshot {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw PhotoError.message("文件不可访问或不是普通文件：" + path) }
        return from(info)
    }
    static func read(descriptor: Int32) throws -> FileSnapshot {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw PhotoError.message("文件句柄不可访问或不是普通文件")
        }
        return from(info)
    }
    private static func from(_ info: stat) -> FileSnapshot {
        FileSnapshot(size: info.st_size, device: info.st_dev, inode: info.st_ino,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}
public struct Fingerprint: Codable, Equatable, Sendable {
    public var size: UInt64
    public var digest: String
    public static func read(_ path: String, cancellation: CancellationFlag? = nil, progress: (UInt64) -> Void = { _ in }) throws -> Fingerprint {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        var hash = SHA256(); var size: UInt64 = 0
        while true {
            if cancellation?.isCancelled == true { throw CancellationError() }
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data); size += UInt64(data.count); progress(size)
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        return Fingerprint(size: size, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
public struct FileStep: Codable, Equatable, Sendable {
    public var source: String
    public var destination: String
    public var timeEdit: TimeEditJournal?
    public var transfer: ArchiveTransfer?
    public var undoTransfer: ArchiveTransfer?
    public var previewSnapshot: FileSnapshot?
    public var before: Fingerprint?
    public var after: Fingerprint?
    public var backup: String?
    public var staged: String?
    public var state: String = "pending"
    public init(source: String, destination: String, before: Fingerprint?) { self.source = source; self.destination = destination; self.before = before }
}
public struct OperationItem: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var photo: Photo
    public var files: [FileStep]
    public var newCapture: CaptureTime?
    public var error: String?
    public var status: String = "pending"
}
public struct OperationBatch: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var created = Date()
    public var kind: String
    public var items: [OperationItem]
    public var status: String = "preview"
    public var title: String { kind == "archive" ? "移动归档" : "调整拍摄时间" }
    public var done: Int { items.filter { $0.status == "done" }.count }
}
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Versioned archive journal. Missing journals retain the legacy fingerprint workflow.
public struct ArchiveTransfer: Codable, Equatable, Sendable {
    public var source: String
    public var destination: String
    public var original: FileSnapshot
    public var strategy: String = "automatic"
    public var phase: String = "pending"
    public var staged: String?
    public var stagedSnapshot: FileSnapshot?
    public var result: FileSnapshot?
    public var fingerprint: Fingerprint?
    public init(source: String, destination: String, original: FileSnapshot) {
        self.source = source; self.destination = destination; self.original = original
    }
}

/// New time-edit records distinguish deferred fingerprints from planned creation.
public struct TimeEditJournal: Codable, Equatable, Sendable {
    public var role: String // existing, new, readonly
    public var original: FileSnapshot?
    public var backupSnapshot: FileSnapshot?
    public var result: FileSnapshot?
    public var workspace: TimeWorkspace?
    public var preparedSnapshot: FileSnapshot?
    public init(role: String, original: FileSnapshot?) { self.role = role; self.original = original }
}
public struct TimeWorkspace: Codable, Equatable, Sendable {
    public var path: String
    public var device: Int32
    public var inode: UInt64
}
