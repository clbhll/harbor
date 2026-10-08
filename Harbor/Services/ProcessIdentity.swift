import Darwin
import Foundation

/// A PID alone is not an identity: the kernel can reuse it after a process exits.
/// Keep the kernel start time, effective user and executable with the scan row.
struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let userID: UInt32
    let executablePath: String

    func predates(_ date: Date) -> Bool {
        let started = Double(startedSeconds) + Double(startedMicroseconds) / 1_000_000
        return started <= date.timeIntervalSince1970
    }

    static func read(for pid: Int32) -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        var before = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, size) == size else { return nil }

        var path = [UInt8](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let length = path.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0,
              let executable = String(bytes: path.prefix(while: { $0 != 0 }), encoding: .utf8),
              !executable.isEmpty else { return nil }

        // A process may exit while its path is being read. Reject mixed records.
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              before.pbi_pid == UInt32(pid), after.pbi_pid == before.pbi_pid,
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec,
              before.pbi_uid == after.pbi_uid,
              before.pbi_start_tvsec > 0 else { return nil }

        return ProcessIdentity(
            pid: pid,
            startedSeconds: before.pbi_start_tvsec,
            startedMicroseconds: before.pbi_start_tvusec,
            userID: before.pbi_uid,
            executablePath: executable
        )
    }
}

/// Kernel argument-buffer parsing has no side effects and never reads beyond argc.
enum ProcessArguments {
    static func parse(_ buffer: [UInt8], count: Int? = nil) -> [String]? {
        let end = count ?? buffer.count
        let headerSize = MemoryLayout<Int32>.size
        guard end <= buffer.count, end > headerSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, Int(argc) <= end - headerSize else { return nil }

        // KERN_PROCARGS2: argc, executable path, NUL padding, argv, environment.
        var index = headerSize
        while index < end && buffer[index] != 0 { index += 1 }
        guard index < end else { return nil }
        index += 1  // executable path terminator
        // The public buffer format gives no argv-start offset. Additional NULs
        // could be alignment padding OR an empty argv[0]. Guessing by skipping
        // them could consume environment values to satisfy argc. Omit command
        // metadata for this ambiguous layout rather than risk displaying it.
        guard index < end, buffer[index] != 0 else { return nil }

        var arguments: [String] = []
        for _ in 0..<Int(argc) {
            guard index < end else { return nil }
            var terminator = index
            while terminator < end && buffer[terminator] != 0 { terminator += 1 }
            guard terminator < end,
                  let argument = String(bytes: buffer[index..<terminator], encoding: .utf8)
            else { return nil }
            arguments.append(argument)
            // Consume exactly one terminator. More NULs mean empty arguments,
            // not padding; skipping them would pull environment values into argv.
            index = terminator + 1
        }
        return arguments
    }

    static func display(_ arguments: [String]) -> String {
        arguments.map { $0.isEmpty ? "\"\"" : $0 }.joined(separator: " ")
    }
}
