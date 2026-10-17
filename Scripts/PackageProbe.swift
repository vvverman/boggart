// Только сборочная проверка. Этот клиент не входит в пользовательский .app.
import Foundation
import ServiceManagement
import Darwin

@objc protocol ProbeProtocol {
    func perform(_ data: Data, withReply reply: @escaping (Data) -> Void)
}
DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
    fputs("Native probe exceeded 30 seconds; not counted as a pass\n", stderr)
    exit(124)
}
let mode = CommandLine.arguments.dropFirst().first ?? ""
let service = SMAppService.daemon(plistName: "local.boggart.helper.plist")
if mode == "register" {
    do {
        try service.register()
        let status = service.status
        print("SMAppService registration status: \(status.rawValue)")
        guard status == .enabled || status == .requiresApproval else { exit(1) }
        print(status == .enabled ? "REGISTERED_AND_ENABLED" : "REGISTERED_REQUIRES_USER_APPROVAL")
        exit(0)
    } catch {
        fputs("Registration failed: \(error)\n", stderr); exit(1)
    }
}
if mode == "unregister" {
    do { try service.unregister(); print("UNREGISTERED"); exit(0) }
    catch { fputs("Unregister failed: \(error)\n", stderr); exit(1) }
}
guard ["xpc", "reject"].contains(mode), CommandLine.arguments.count == 3 else { exit(64) }
let digest = CommandLine.arguments[2]
guard digest.count == 40, digest.allSatisfy({ $0.isHexDigit }) else { exit(64) }
let rejecting = mode == "reject"
let connection = NSXPCConnection(machServiceName: "local.boggart.helper", options: .privileged)
connection.setCodeSigningRequirement("identifier \"local.boggart.helper\" and certificate leaf = H\"\(digest)\"")
connection.remoteObjectInterface = NSXPCInterface(with: ProbeProtocol.self)
connection.resume()
let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    if rejecting { print("UNAUTHORIZED_CLIENT_REJECTED: \(error)"); exit(0) }
    fputs("XPC failed: \(error)\n", stderr); exit(1)
} as! ProbeProtocol
let request = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "kind": "heartbeat"])
proxy.perform(request) { data in
    if rejecting { fputs("Unauthorized client was accepted\n", stderr); exit(1) }
    do {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let status = value?["status"] as? [String: Any],
              status["phase"] as? String == "inactive",
              status["helperVersion"] as? String == "0.4.1",
              value?["error"] == nil else {
            fputs("Unexpected reply: \(String(decoding: data, as: UTF8.self))\n", stderr); exit(1)
        }
        print("AUTHENTICATED_XPC_OK")
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch { fputs("Invalid JSON: \(error)\n", stderr); exit(1) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
    fputs("XPC probe timed out; not counted as a pass\n", stderr); exit(1)
}
RunLoop.main.run()
