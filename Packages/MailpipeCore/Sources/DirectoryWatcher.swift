import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Watches a local directory for additions, renames, or removals so the host can react
/// immediately without high-frequency polling.
public final class DirectoryWatcher: @unchecked Sendable {
#if canImport(Darwin)
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
#endif

    public init?(directory: URL, label: String, onChange: @escaping @Sendable () -> Void) {
#if canImport(Darwin)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let queue = DispatchQueue(label: label, qos: .utility)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        self.queue = queue
        self.fileDescriptor = fd
        self.source = source
        source.resume()
#else
        return nil
#endif
    }

    public func stop() {
#if canImport(Darwin)
        source?.cancel()
        source = nil
        fileDescriptor = -1
#endif
    }

    deinit {
        stop()
    }
}
