import Foundation

/// Development aid: with FOCUSSPRINT_TIMING=<file> set, records how long startup and the hot paths take.
/// Does nothing otherwise.
enum Timing {
    private static let file = ProcessInfo.processInfo.environment["FOCUSSPRINT_TIMING"]
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }()
    private static var samples: [String: (count: Int, total: Double, worst: Double)] = [:]

    static var enabled: Bool { file != nil }

    /// A point in time since the process started.
    static func mark(_ label: String) {
        guard let file else { return }
        append(String(format: "%@ at %.0f ms\n", label, Date().timeIntervalSince(processStart) * 1000), to: file)
    }

    /// Runs `work`, and every 20 calls writes the average and worst duration.
    static func measure<T>(_ label: String, _ work: () -> T) -> T {
        guard let file else { return work() }
        let begin = DispatchTime.now().uptimeNanoseconds
        let result = work()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000
        var s = samples[label] ?? (0, 0, 0)
        s = (s.count + 1, s.total + ms, max(s.worst, ms))
        samples[label] = s
        if s.count % 20 == 0 || ms > 100 {
            append(String(format: "%@: avg %.1f ms, worst %.1f ms over %d calls (last %.1f)\n", label, s.total / Double(s.count), s.worst, s.count, ms), to: file)
        }
        return result
    }

    /// Records a duration measured elsewhere.
    static func record(_ label: String, ms: Double) {
        guard file != nil else { return }
        _ = measureValue(label, ms)
    }

    private static func measureValue(_ label: String, _ ms: Double) -> Double {
        guard let file else { return ms }
        var s = samples[label] ?? (0, 0, 0)
        s = (s.count + 1, s.total + ms, max(s.worst, ms))
        samples[label] = s
        if s.count % 20 == 0 || ms > 150 {
            append(String(format: "%@: avg %.1f ms, worst %.1f ms over %d (last %.1f)\n", label, s.total / Double(s.count), s.worst, s.count, ms), to: file)
        }
        return ms
    }

    private static func append(_ line: String, to path: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
