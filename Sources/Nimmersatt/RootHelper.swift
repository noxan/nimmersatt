import Foundation
import NimmersattShared
import ServiceManagement

/// The optional root helper: the user opts in, macOS asks for approval in Login Items.
enum RootHelper {
    private static var service: SMAppService { .daemon(plistName: helperPlist) }
    static var status: SMAppService.Status { service.status }
    static var enabled: Bool { status == .enabled }

    static func enable() {
        do { try service.register() } catch { NSLog("root helper: \(error.localizedDescription)") }
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    static func disable() {
        connection?.invalidate()
        connection = nil
        try? service.unregister()
    }

    private static var connection: NSXPCConnection?

    /// Cumulative disk bytes for every process, nil when the helper is off or does not answer.
    static func diskBytes() -> [pid_t: UInt64]? {
        guard enabled else { return nil }
        let conn = connection ?? {
            let c = NSXPCConnection(machServiceName: helperService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            c.invalidationHandler = { connection = nil }
            c.resume()
            connection = c
            return c
        }()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply: [NSNumber: NSNumber]?
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? HelperProtocol
        proxy?.diskBytes { reply = $0; done.signal() }
        guard proxy != nil, done.wait(timeout: .now() + 0.5) == .success, let reply else { return nil }
        return Dictionary(uniqueKeysWithValues: reply.map { ($0.key.int32Value, $0.value.uint64Value) })
    }
}
