import Foundation
import SystemConfiguration
import IOKit.ps
import BoggartCore
import BoggartPlatform

final class HelperRuntime {
    let queue = DispatchQueue(label: "local.boggart.helper.state", qos: .userInitiated)
    let controller: SessionController
    private var timer: DispatchSourceTimer?
    private var thermalObserver: NSObjectProtocol?
    private var powerSource: CFRunLoopSource?
    init() throws {
        let files = try DurableFiles()
        controller = SessionController(backend: PMSetAdapter(), recovery: JournalStore(files), history: LocalHistoryStore(files))
        queue.sync { controller.bootstrap() }
    }
    func launch() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.controller.tick() }
        timer.resume(); self.timer = timer
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil) { [weak self] _ in self?.requestTick() }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let ref = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            Unmanaged<HelperRuntime>.fromOpaque(pointer).takeUnretainedValue().requestTick()
        }, context) {
            let source = ref.takeRetainedValue()
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
    func requestTick() { queue.async { self.controller.tick() } }
}

private final class ServicePeer: NSObject, BoggartServiceProtocol {
    let identity: PeerIdentity
    let runtime: HelperRuntime
    init(uid: UInt32, runtime: HelperRuntime) { identity = .init(uid: uid); self.runtime = runtime }
    func perform(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        runtime.queue.async {
            let response: ServiceReply
            do {
                guard data.count <= 4096 else { throw BoggartError.message("Слишком большой запрос.") }
                let command = try JSONDecoder().decode(ServiceCommand.self, from: data)
                // Разрешение начать сессию проверяем заново, а не только при подключении.
                if (command.kind == .start || command.kind == .prepareMaintenance) && self.identity.uid != currentConsoleUID() {
                    throw BoggartError.message("Начать сессию может только текущий пользователь Mac.")
                }
                response = self.runtime.controller.execute(command, peer: self.identity)
            } catch {
                response = .init(status: self.runtime.controller.snapshot(for: self.identity.uid), error: error.localizedDescription)
            }
            // Поля формируются помощником из проверенных значений. Пустой ответ
            // при ошибке кодирования клиент трактует как неизвестное состояние.
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    let runtime: HelperRuntime
    init(runtime: HelperRuntime) { self.runtime = runtime }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier > 0 else { return false }
        // Подпись проверяет setConnectionCodeSigningRequirement у listener.
        // UID берётся из XPC, а не из JSON-запроса.
        let peer = ServicePeer(uid: connection.effectiveUserIdentifier, runtime: runtime)
        connection.exportedInterface = NSXPCInterface(with: BoggartServiceProtocol.self)
        connection.exportedObject = peer
        let ended: () -> Void = { [weak runtime] in
            runtime?.queue.async { [weak runtime] in runtime?.controller.disconnected(peer.identity) }
        }
        connection.interruptionHandler = ended
        connection.invalidationHandler = ended
        connection.resume()
        return true
    }
}
private func currentConsoleUID() -> UInt32? {
    var uid: uid_t = 0, gid: gid_t = 0
    guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil, uid > 0 else { return nil }
    return uid
}
