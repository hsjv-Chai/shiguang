import Foundation
import CSQLite

public final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var lastBatch: OperationBatch?
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(directory.appendingPathComponent("library.sqlite").path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw PhotoError.message("无法打开照片索引") }
        try sql("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS photos (id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS batches (id TEXT PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS batch_items (id TEXT PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS places (id TEXT PRIMARY KEY, payload BLOB NOT NULL);")
    }
    deinit { sqlite3_close(db) }
    private func sql(_ query: String) throws { guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func failure() -> Error { PhotoError.message("索引保存失败：" + String(cString: sqlite3_errmsg(db))) }
    private func put<T: Encodable>(_ table: String, id: String, path: String? = nil, value: T) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(value)
        var stmt: OpaquePointer?
        let query = path == nil ? "INSERT OR REPLACE INTO \(table)(id,payload) VALUES (?,?)" : "INSERT OR REPLACE INTO \(table)(id,path,payload) VALUES (?,?,?)"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        if let path { sqlite3_bind_text(stmt, 2, path, -1, transient) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, path == nil ? 2 : 3, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    private func all<T: Decodable>(_ table: String, as type: T.Type) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }; var items: [T] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw failure() }
            items.append(try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))))
        }
        return items
    }
    public func save(_ photo: Photo) throws { try put("photos", id: photo.id, path: photo.path, value: photo) }
    public func save(_ photos: [Photo]) throws {
        lock.lock(); defer { lock.unlock() }; try sql("BEGIN IMMEDIATE")
        do { for photo in photos { try save(photo) }; try sql("COMMIT") } catch { try? sql("ROLLBACK"); throw error }
    }
    /// Replace absorbed single-file records and publish their logical groups atomically.
    public func replace(_ photos: [Photo], removing ids: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }; try sql("BEGIN IMMEDIATE")
        do {
            for id in ids {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM photos WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            }
            for photo in photos { try save(photo) }
            try sql("COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
    }
    public func photo(id: String) throws -> Photo? { try get("photos", id: id, as: Photo.self) }
    private func get<T: Decodable>(_ table: String, id: String, as type: T.Type) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table) WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw failure() }
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
    }
    public func photos() throws -> [Photo] { try all("photos", as: Photo.self) }
    public func save(_ batch: OperationBatch, changedItem: Int? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try sql("BEGIN IMMEDIATE")
        do {
            var header = batch; header.items = []
            try put("batches", id: batch.id, value: header)
            let indices: [Int]
            if let changedItem, lastBatch?.id == batch.id, lastBatch?.items.count == batch.items.count {
                indices = [changedItem]
            } else { indices = Array(batch.items.indices) }
            for index in indices {
                let item = batch.items[index]
                if lastBatch?.id == batch.id, let previous = lastBatch?.items, previous.indices.contains(index), previous[index] == item { continue }
                try put("batch_items", id: batch.id + String(format: ":%08d", index), value: item)
            }
            try sql("COMMIT"); lastBatch = batch
        } catch { try? sql("ROLLBACK"); throw error }
    }
    public func batches() throws -> [OperationBatch] {
        lock.lock(); defer { lock.unlock() }
        var batches = try all("batches", as: OperationBatch.self)
        for index in batches.indices where batches[index].items.isEmpty {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM batch_items WHERE id >= ? AND id < ? ORDER BY id", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, batches[index].id + ":", -1, transient)
            sqlite3_bind_text(stmt, 2, batches[index].id + ";", -1, transient)
            while true {
                let status = sqlite3_step(stmt); if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw failure() }
                batches[index].items.append(try JSONDecoder().decode(OperationItem.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))))
            }
        }
        return batches.sorted { $0.created > $1.created }
    }
    private struct Place: Codable { var key: String; var name: String }
    public func place(_ key: String) throws -> String? { try get("places", id: key, as: Place.self)?.name }
    public func savePlace(key: String, name: String) throws { try put("places", id: key, value: Place(key: key, name: name)) }
}
