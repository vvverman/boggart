import Foundation
import Darwin
import BoggartCore

/// Каталог root:wheel 0700, файлы 0600. Пути не поступают от XPC-клиента.
/// Запись: O_EXCL/O_NOFOLLOW -> запись -> F_FULLFSYNC -> rename -> fsync каталога.
final class DurableFiles {
    private let directory = BoggartConstants.dataDirectory
    init() throws {
        guard geteuid() == 0 else { throw BoggartError.message("Помощник должен быть запущен macOS от root.") }
        try ensureDirectory("/Library/Application Support/Boggart")
        try ensureDirectory(directory)
    }
    private func ensureDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw posix("Не удалось создать каталог восстановления") }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0, (info.st_mode & 0o077) == 0 else {
            throw BoggartError.message("Небезопасные права каталога \(path).")
        }
    }
    func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        let path = directory + "/" + name
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw posix("Не удалось открыть локальные данные")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0, (info.st_mode & 0o077) == 0, info.st_size >= 0, info.st_size <= 262144 else {
            throw BoggartError.message("Локальные данные имеют небезопасные права или неверный размер.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        return try JSONDecoder().decode(T.self, from: data)
    }
    func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 262144 else { throw BoggartError.message("Превышен размер локальных данных.") }
        let temp = directory + "/.\(UUID().uuidString).tmp"
        let destination = directory + "/" + name
        let descriptor = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posix("Не удалось создать запись восстановления") }
        defer { close(descriptor); unlink(temp) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else { throw posix("Не удалось синхронизировать запись восстановления") }
        guard rename(temp, destination) == 0 else { throw posix("Не удалось сохранить запись восстановления") }
        try syncDirectory()
    }
    func remove(_ name: String) throws {
        let path = directory + "/" + name
        guard unlink(path) == 0 || errno == ENOENT else { throw posix("Не удалось удалить запись восстановления") }
        try syncDirectory()
    }
    private func syncDirectory() throws {
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix("Не удалось открыть каталог") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posix("Не удалось синхронизировать каталог") }
    }
    private func posix(_ text: String) -> BoggartError { .message("\(text): \(String(cString: strerror(errno))).") }
}
final class JournalStore: RecoveryStore {
    private let files: DurableFiles
    init(_ files: DurableFiles) { self.files = files }
    func load() throws -> RecoveryRecord? {
        let value = try files.read("recovery.json", as: RecoveryRecord.self)
        try value?.validate()
        return value
    }
    func save(_ record: RecoveryRecord) throws { try record.validate(); try files.write(record, name: "recovery.json") }
    func clear() throws { try files.remove("recovery.json") }
}
final class LocalHistoryStore: HistoryStore {
    private let files: DurableFiles
    init(_ files: DurableFiles) { self.files = files }
    func records(for uid: UInt32) throws -> [SessionRecord] {
        Array((try files.read("history-\(uid).json", as: [SessionRecord].self) ?? []).prefix(5))
    }
    func append(_ record: SessionRecord) throws {
        let existing = try records(for: record.ownerUID)
        if existing.contains(where: { $0.id == record.id }) { return }
        try files.write(HistoryPolicy.appending(record, to: existing), name: "history-\(record.ownerUID).json")
    }
}
