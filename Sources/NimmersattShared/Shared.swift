import Darwin
import Foundation

public let helperService = "local.nimmersatt.helper"
public let helperPlist = "local.nimmersatt.helper.plist"

/// What the root helper offers the app: cumulative disk bytes per process, which libproc
/// only hands out for processes the caller owns.
@objc public protocol HelperProtocol {
    func diskBytes(reply: @escaping ([NSNumber: NSNumber]) -> Void)
}

/// Cumulative bytes read + written, per pid. Complete when run as root, own processes otherwise.
public func collectDiskBytes() -> [pid_t: UInt64] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var out: [pid_t: UInt64] = [:]
    for pid in pids.prefix(max(count, 0)) where pid > 0 {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        } == 0
        if ok { out[pid] = info.ri_diskio_bytesread + info.ri_diskio_byteswritten }
    }
    return out
}
