import Foundation
import BoggartCore
import BoggartPlatform

/// Главная очередь; один запрос в полёте. Изменяющие команды не повторяются
/// после тайм-аута. Сначала читается подтверждённое состояние новой связи.
final class ServiceClient {
    private struct Job { let command: ServiceCommand; let completion: (ServiceReply?) -> Void }
    var onReply: ((ServiceReply) -> Void)?
    var onUnavailable: ((String) -> Void)?
    private var connection: NSXPCConnection?
    private var generation = UUID()
    private var jobs: [Job] = []
    private var running = false
    private var heartbeatQueued = false
    private var invalidated = false

    private func connected() throws -> NSXPCConnection {
        if let connection { return connection }
        let requirement = try ClientAuthentication.requirement(for: BoggartConstants.serviceID)
        let next = NSXPCConnection(machServiceName: BoggartConstants.serviceID, options: .privileged)
        next.setCodeSigningRequirement(requirement)
        next.remoteObjectInterface = NSXPCInterface(with: BoggartServiceProtocol.self)
        let currentGeneration = UUID(); generation = currentGeneration
        let lost = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration, !self.invalidated else { return }
                self.reset()
                self.onUnavailable?("Связь с помощником потеряна. Состояние удержания проверяется.")
            }
        }
        next.interruptionHandler = lost; next.invalidationHandler = lost
        connection = next; next.resume()
        return next
    }
    private func reset() { generation = UUID(); connection?.invalidate(); connection = nil }
    func send(_ command: ServiceCommand, completion: @escaping (ServiceReply?) -> Void) {
        guard !invalidated else { completion(nil); return }
        jobs.append(.init(command: command, completion: completion)); pump()
    }
    func heartbeat() {
        guard !heartbeatQueued, !invalidated else { return }
        heartbeatQueued = true
        send(.init(.heartbeat)) { [weak self] _ in self?.heartbeatQueued = false }
    }
    private func pump() {
        guard !running, !invalidated, !jobs.isEmpty else { return }
        running = true
        let job = jobs.removeFirst()
        let next: NSXPCConnection
        do { next = try connected() }
        catch {
            running = false; onUnavailable?(error.localizedDescription); job.completion(nil); pump(); return
        }
        let requestGeneration = generation
        var finished = false
        let finish: (Result<Data, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard !finished else { return }; finished = true
                guard let self else { job.completion(nil); return }
                defer { self.running = false; self.pump() }
                guard !self.invalidated, self.generation == requestGeneration else { job.completion(nil); return }
                do {
                    let data = try result.get()
                    guard data.count <= 65536 else { throw BoggartError.message("Превышен размер ответа помощника.") }
                    let reply = try JSONDecoder().decode(ServiceReply.self, from: data)
                    guard reply.status.protocolVersion == BoggartConstants.protocolVersion,
                          reply.status.helperVersion == BoggartConstants.version,
                          reply.status.capability.validationBuild == BoggartConstants.hardwareTesting else {
                        throw BoggartError.message("Версии приложения и помощника различаются. Завершите прежнюю сессию и обновите помощник.")
                    }
                    self.onReply?(reply); job.completion(reply)
                } catch {
                    self.reset(); self.onUnavailable?(error.localizedDescription); job.completion(nil)
                }
            }
        }
        guard let proxy = next.remoteObjectProxyWithErrorHandler({ finish(.failure($0)) }) as? BoggartServiceProtocol else {
            finish(.failure(BoggartError.message("Не удалось открыть канал XPC."))); return
        }
        do { proxy.perform(try JSONEncoder().encode(job.command)) { finish(.success($0)) } }
        catch { finish(.failure(error)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if !finished { finish(.failure(BoggartError.message("Помощник не подтвердил команду вовремя."))) }
        }
    }
    func invalidate() {
        invalidated = true; reset()
        let waiting = jobs; jobs.removeAll(); waiting.forEach { $0.completion(nil) }
    }
}
