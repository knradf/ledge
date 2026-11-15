import Darwin
import Foundation
import SystemConfiguration

enum NetUtil {
    private static let store = SCDynamicStoreCreate(nil, "Ledge" as CFString, nil, nil)

    /// The interface carrying the default route right now ("en0", "en5", ...),
    /// the same one `route get default` reports.
    static func primaryInterface() -> String? {
        guard let store,
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString),
              let dict = value as? [String: Any]
        else { return nil }
        return dict["PrimaryInterface"] as? String
    }

    /// IPv4 address of an interface, e.g. "en0".
    static func ipv4(for name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            if String(cString: entry.ifa_name) == name,
               let addr = entry.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            cursor = entry.ifa_next
        }
        return nil
    }

    /// Total bytes received / sent on an interface, as 64-bit counters.
    /// Same source netstat uses (sysctl NET_RT_IFLIST2).
    static func byteCounters(for name: String) -> (rx: UInt64, tx: UInt64)? {
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        let headerSize = MemoryLayout<if_msghdr>.size
        let header2Size = MemoryLayout<if_msghdr2>.size

        return buffer.withUnsafeBytes { raw -> (rx: UInt64, tx: UInt64)? in
            var offset = 0
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                if messageLength <= 0 { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + header2Size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(info.ifm_index) == index {
                        return (info.ifm_data.ifi_ibytes, info.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
            return nil
        }
    }
}
