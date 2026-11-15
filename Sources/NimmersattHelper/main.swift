import Foundation
import NimmersattShared

// Root helper, registered by the app through SMAppService once the user opts in.
// Read-only: it only reports per-process disk counters, and only to the signed app.
final class Handler: NSObject, HelperProtocol, NSXPCListenerDelegate {
    func diskBytes(reply: @escaping ([NSNumber: NSNumber]) -> Void) {
        reply(Dictionary(uniqueKeysWithValues: collectDiskBytes().map { (NSNumber(value: $0.key), NSNumber(value: $0.value)) }))
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

let handler = Handler()
let listener = NSXPCListener(machServiceName: helperService)
// ponytail: the app is ad-hoc signed, so this pins the identifier, not a certificate.
listener.setConnectionCodeSigningRequirement(#"identifier "local.nimmersatt""#)
listener.delegate = handler
listener.resume()
RunLoop.main.run()
