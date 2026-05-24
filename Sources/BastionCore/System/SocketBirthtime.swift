import Foundation
import Darwin

/// Read the kernel-tracked birth time of a file (specifically a Unix
/// socket created by `ssh -fNM`). Uses `stat(2)`'s `st_birthtimespec`
/// (HFS+/APFS-tracked, monotonic, no privilege required for same-uid
/// files).
///
/// **Why this exists**: per dual-model consensus rubber-duck, the
/// previously-proposed `proc_pidinfo(PROC_PIDTBSDINFO).pbi_start_tvsec`
/// path requires the master process's PID, which `ssh -fNM` makes hard
/// to discover (the spawned parent daemonizes, the surviving child PID
/// is not what we ran). The socket file's birthtime is just as
/// authoritative, cheaper to read, and works for masters NOT spawned
/// by Bastion (e.g. user ran `ssh -fNM vault` manually from the CLI).
///
/// Falls back to nil on any stat error; caller treats that as
/// "use the in-memory first-observed-at fallback."
public enum SocketBirthtime {
    public static func lookup(path: String) -> Date? {
        var buf = stat()
        guard stat(path, &buf) == 0 else { return nil }
        // st_birthtimespec is `timespec` on Darwin; convert to Date.
        // Some volumes (e.g. SMB) report birthtime as 0; treat that as missing.
        let tv = buf.st_birthtimespec
        if tv.tv_sec == 0 { return nil }
        let seconds = TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds)
    }
}
