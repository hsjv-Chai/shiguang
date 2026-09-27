import Foundation
import Darwin

public final class MetadataService: @unchecked Sendable {
    public let executable: URL
    public let script: URL
    public init(executable: URL, script: URL) { self.executable = executable; self.script = script }
    public static func locate() throws -> MetadataService {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundled = resources.appendingPathComponent("ExifTool/exiftool")
        if FileManager.default.fileExists(atPath: bundled.path) {
            let perl = resources.appendingPathComponent("Perl/bin/perl")
            guard FileManager.default.isExecutableFile(atPath: perl.path) else { throw PhotoError.message("应用内 Perl 运行时缺失，请重新构建应用") }
            return MetadataService(executable: perl, script: bundled)
        }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTOARCHIVE_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let script = root.appendingPathComponent("Vendor/ExifTool/exiftool")
        guard FileManager.default.fileExists(atPath: script.path) else { throw PhotoError.message("找不到内置 ExifTool，请运行 scripts/build-app.sh") }
        let perl = root.appendingPathComponent("Vendor/Perl/bin/perl")
        return MetadataService(executable: FileManager.default.isExecutableFile(atPath: perl.path) ? perl : URL(fileURLWithPath: "/usr/bin/perl"), script: script)
    }
    @discardableResult public func run(_ arguments: [String], cancellation: CancellationFlag? = nil, allowPartialJSON: Bool = false) throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let output = temp.appendingPathComponent("out"), errorURL = temp.appendingPathComponent("err")
        FileManager.default.createFile(atPath: output.path, contents: nil); FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errorURL)
        defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = executable
        process.arguments = [script.path, "-config", "", "-charset", "filename=UTF8"] + arguments
        var env = ProcessInfo.processInfo.environment
        for key in ["PERL5OPT", "PERL5LIB", "PERLLIB", "PERL_LOCAL_LIB_ROOT"] { env.removeValue(forKey: key) }
        process.environment = env; process.standardOutput = out; process.standardError = err
        if cancellation?.isCancelled == true { throw CancellationError() }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        while exited.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation?.isCancelled == true {
                if process.isRunning { process.terminate() }
                if exited.wait(timeout: .now() + 1) == .timedOut {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                }
                throw CancellationError()
            }
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        let data = try Data(contentsOf: output)
        guard process.terminationStatus == 0 || (allowPartialJSON && !data.isEmpty) else { let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""; throw PhotoError.message("元数据处理失败：\(detail.isEmpty ? String(decoding: data, as: UTF8.self) : detail)") }
        return data
    }
    public func read(_ paths: [String], cancellation: CancellationFlag? = nil, tolerateFileErrors: Bool = false) throws -> [String: [String: Any]] {
        guard !paths.isEmpty else { return [:] }
        let data = try run(["-j", "-G1", "-n", "-a", "-DateTimeOriginal", "-CreateDate", "-SubSecTimeOriginal", "-OffsetTimeOriginal", "-GPSLatitude", "-GPSLongitude", "-GPSLatitudeRef", "-GPSLongitudeRef", "-FileType", "-Error", "--"] + paths, cancellation: cancellation, allowPartialJSON: tolerateFileErrors)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw PhotoError.message("无法读取元数据响应") }
        var result: [String: [String: Any]] = [:]
        for row in rows { if let path = row["SourceFile"] as? String { result[path] = row } }
        return result
    }
    public func capture(_ row: [String: Any]) -> CaptureTime? {
        for key in ["ExifIFD:DateTimeOriginal", "XMP-exif:DateTimeOriginal", "XMP-photoshop:DateCreated", "ExifIFD:CreateDate", "XMP-xmp:CreateDate"] {
            if let value = CaptureTime.parse(row[key] as? String, offset: row["ExifIFD:OffsetTimeOriginal"] as? String, subseconds: (row["ExifIFD:SubSecTimeOriginal"]).map { String(describing: $0) }) { return value }
        }
        return nil
    }
    public func write(_ capture: CaptureTime, to path: String, xmpOnly: Bool, cancellation: CancellationFlag? = nil) throws {
        let fraction = capture.subseconds.map { "." + $0 } ?? ""
        let xmp = capture.value + fraction + (capture.offset ?? "")
        var args = ["-overwrite_original", "-P", "-XMP-exif:DateTimeOriginal=\(xmp)", "-XMP-xmp:CreateDate=\(xmp)", "-XMP-photoshop:DateCreated=\(xmp)"]
        if !xmpOnly {
            args += ["-EXIF:DateTimeOriginal=\(capture.value)", "-EXIF:CreateDate=\(capture.value)", "-EXIF:OffsetTimeOriginal=\(capture.offset ?? "")", "-EXIF:OffsetTimeDigitized=\(capture.offset ?? "")", "-EXIF:SubSecTimeOriginal=\(capture.subseconds ?? "")", "-EXIF:SubSecTimeDigitized=\(capture.subseconds ?? "")"]
        }
        try run(args + ["--", path], cancellation: cancellation)
        guard let row = try read([path], cancellation: cancellation)[path], let result = self.capture(row), result.value == capture.value, result.offset == capture.offset, result.subseconds == capture.subseconds else { throw PhotoError.message("写入后校验拍摄时间失败") }
    }
}
