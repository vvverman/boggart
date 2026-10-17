import Foundation

/// Не входит в контур безопасности. Ошибка диска не удерживает компьютер,
/// не блокирует выход и не заставляет повторно снимать уже снятый запрет сна.
/// Выполняется на той же последовательной очереди, что SessionController.
final class BestEffortHistory {
    private let store: HistoryStore
    private var cache: [UInt32: [SessionRecord]] = [:]
    private var pending: [UInt32: [SessionRecord]] = [:] // Старые → новые для записи на диск.
    private var needsRead: Set<UInt32> = []
    private var nextAttempt: [UInt32: TimeInterval] = [:]
    private var warnings: [UInt32: String] = [:]
    init(store: HistoryStore) { self.store = store }

    func records(for uid: UInt32, at now: TimeInterval) -> [SessionRecord] {
        if cache[uid] == nil {
            cache[uid] = []
            load(uid, at: now)
        }
        return cache[uid] ?? []
    }
    func warning(for uid: UInt32) -> String? { warnings[uid] }

    func append(_ record: SessionRecord, at now: TimeInterval) {
        let old = records(for: record.ownerUID, at: now)
        guard !old.contains(where: { $0.id == record.id }) else { return }
        cache[record.ownerUID] = HistoryPolicy.appending(record, to: old)
        let queue = (pending[record.ownerUID] ?? []).filter { $0.id != record.id } + [record]
        pending[record.ownerUID] = Array(queue.suffix(5))
        flush(record.ownerUID, at: now)
    }
    func retry(at now: TimeInterval) {
        for uid in Array(nextAttempt.keys) where now >= (nextAttempt[uid] ?? .infinity) {
            if needsRead.contains(uid) { load(uid, at: now) }
            flush(uid, at: now)
        }
    }
    private func load(_ uid: UInt32, at now: TimeInterval) {
        do {
            let disk = try store.records(for: uid)
            let memory = cache[uid] ?? []
            let ids = Set(memory.map(\.id))
            // Не сортируем по календарным часам: они могли быть переведены назад.
            cache[uid] = Array((memory + disk.filter { !ids.contains($0.id) }).prefix(5))
            needsRead.remove(uid)
            clearWarningIfDone(uid)
        } catch {
            needsRead.insert(uid)
            failed(uid, at: now)
        }
    }
    private func flush(_ uid: UInt32, at now: TimeInterval) {
        while let record = pending[uid]?.first {
            do {
                try store.append(record)
                pending[uid]?.removeFirst()
            } catch { failed(uid, at: now); return }
        }
        clearWarningIfDone(uid)
    }
    private func clearWarningIfDone(_ uid: UInt32) {
        guard !needsRead.contains(uid), pending[uid]?.isEmpty != false else { return }
        warnings.removeValue(forKey: uid); nextAttempt.removeValue(forKey: uid)
    }
    private func failed(_ uid: UInt32, at now: TimeInterval) {
        warnings[uid] = "Историю не удалось сохранить или прочитать. На удержание и его завершение это не влияет."
        nextAttempt[uid] = now + 5
    }
}
