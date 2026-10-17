import AppKit
import Darwin
import BoggartCore
import BoggartPlatform

struct MaintenanceOffer: Identifiable {
    enum Kind { case update(URL, String), removal }
    let id = UUID()
    let kind: Kind
    var title: String {
        switch kind { case .update(_, let version): return "Обновить Боггарт до \(version)?"; case .removal: return "Удалить Боггарт?" }
    }
    var actionTitle: String {
        switch kind { case .update: return "Обновить и перезапустить"; case .removal: return "Удалить" }
    }
    var explanation: String {
        switch kind {
        case .update:
            return "Текущая сессия завершится. Боггарт проверит новую поставку, снимет удержание и обновит помощник. Выбранная длительность и настройки сохранятся. Удержание после перезапуска не включится."
        case .removal:
            return "Боггарт снимет удержание, отключит автозапуск и системный помощник, затем переместит приложение в Корзину. Если снятие удержания не подтверждено, удаление отменится. Локальная история и настройки останутся на Mac."
        }
    }
}

/// Только операции с собственной поставкой, без повышенных прав и shell-команд
/// в помощнике. Невозможность записи в /Applications оставляет прежнюю версию.
final class StagedUpdate {
    let root: URL
    let app: URL
    let backupRoot: URL
    private let fm = FileManager.default
    private var committed = false
    init(source: URL) throws {
        root = URL(fileURLWithPath: "/Applications/.Boggart-staging-\(UUID().uuidString)", isDirectory: true)
        app = root.appendingPathComponent("Boggart.app", isDirectory: true)
        backupRoot = URL(fileURLWithPath: "/Applications/.Boggart-backup-\(UUID().uuidString)", isDirectory: true)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        _ = try BundleValidation.inspect(source, requireNewer: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: source, to: app)
            // Повторная проверка именно скопированного пакета закрывает подмену источника.
            _ = try BundleValidation.inspect(app, requireNewer: true)
            try Self.validateTargetMachine(app)
        } catch {
            try? fm.removeItem(at: root)
            throw BoggartError.message("Не удалось подготовить обновление. Старая версия и её сессия не изменены. \(error.localizedDescription)")
        }
    }
    private static func validateTargetMachine(_ app: URL) throws {
        let process = Process(), done = DispatchSemaphore(value: 0)
        process.executableURL = app.appendingPathComponent("Contents/MacOS/Boggart")
        process.arguments = ["--validate-current-machine"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 8) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            throw BoggartError.message("Новая версия не подтвердила совместимость. Текущая версия не заменена.")
        }
        guard process.terminationStatus == 0 else {
            throw BoggartError.message("Новая версия не допускает работу на этом Mac. Обновление отменено до остановки сессии.")
        }
    }
    func commit() throws {
        guard Bundle.main.bundleURL.standardizedFileURL == BundleValidation.installedURL else {
            throw BoggartError.message("Обновление доступно из установленного Боггарта в папке «Программы».")
        }
        _ = try BundleValidation.inspect(app, requireNewer: true)
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let backup = backupRoot.appendingPathComponent("Boggart.app", isDirectory: true)
        try fm.moveItem(at: BundleValidation.installedURL, to: backup)
        do {
            try fm.moveItem(at: app, to: BundleValidation.installedURL)
            committed = true
        } catch {
            do { try fm.moveItem(at: backup, to: BundleValidation.installedURL) }
            catch { throw BoggartError.message("Не удалось вернуть старую версию в «Программы». Она сохранена в \(backup.path). Помощник отключён, удержание снято.") }
            throw error
        }
    }
    func rollback() throws {
        guard committed else { return }
        let backup = backupRoot.appendingPathComponent("Boggart.app", isDirectory: true)
        try fm.moveItem(at: BundleValidation.installedURL, to: app)
        do { try fm.moveItem(at: backup, to: BundleValidation.installedURL); committed = false }
        catch {
            try? fm.moveItem(at: app, to: BundleValidation.installedURL)
            throw error
        }
    }
    func discard() { try? fm.removeItem(at: root) }
    deinit { discard() }
}

enum BundleMaintenance {
    static func stage(_ source: URL, completion: @escaping (Result<StagedUpdate, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try StagedUpdate(source: source) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    static func relaunchAfterExit() throws {
        // Единственная фиксированная непривилегированная команда: дождаться
        // завершения нашего PID и открыть наш известный пакет. Не XPC и не root.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            count=0
            while /bin/kill -0 "$1" 2>/dev/null; do
                count=$((count + 1))
                [ "$count" -lt 150 ] || exit 1
                /bin/sleep 0.2
            done
            exec /usr/bin/open "$2"
            """, "Boggart-relaunch", String(ProcessInfo.processInfo.processIdentifier), BundleValidation.installedURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    static func recycleCurrentApp(completion: @escaping (Error?) -> Void) {
        let url = Bundle.main.bundleURL.standardizedFileURL
        guard url == BundleValidation.installedURL else {
            completion(BoggartError.message("Удаление доступно из Боггарта в папке «Программы».")); return
        }
        NSWorkspace.shared.recycle([url]) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
    static func removeVerifiedBackup(_ path: String) throws {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.deletingLastPathComponent().path == "/Applications",
              root.lastPathComponent.hasPrefix(".Boggart-backup-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(".Boggart-backup-".count))) != nil else {
            throw BoggartError.message("Неверный путь резервной копии.")
        }
        let properties = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard properties.isSymbolicLink != true, properties.isDirectory == true else {
            throw BoggartError.message("Резервная копия имеет неверный тип.")
        }
        _ = try BundleValidation.inspect(root.appendingPathComponent("Boggart.app"))
        try FileManager.default.removeItem(at: root)
    }
}
