import Darwin
import Foundation

/// Keeps one runtime per app identity for the current user, including simultaneous launches.
final class ApplicationInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    /// Keep the lock file in place so contenders always open the same inode.
    /// The kernel releases ownership when the descriptor closes or the process exits.
    static func acquire(at file: URL) throws -> ApplicationInstanceLock? {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return ApplicationInstanceLock(descriptor: descriptor)
        }
        let code = errno
        close(descriptor)
        if code == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
