import CoreServices
import Foundation
import NetFS

/// Verbindet eine NAS-Freigabe (z. B. smb://CAWServer/Daten), falls sie nicht gemountet ist.
/// Zugangsdaten kommen aus dem Schlüsselbund; fehlen sie, fragt macOS nach.
enum NASMounter {
    @discardableResult
    static func mount(_ remote: String) -> Bool {
        guard let url = URL(string: remote) else { return false }
        var mountPoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &mountPoints)
        mountPoints?.release()
        return status == 0
    }
}

/// Erkennt anhand des Pfads, um welche Art von Quelle es sich handelt.
enum SourceDetector {
    static func detect(_ url: URL) -> (kind: SourceKind, remoteURL: String?) {
        if url.path.contains("/Library/CloudStorage/GoogleDrive") {
            return (.googleDrive, nil)
        }
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeURLForRemountingKey])
        if values?.volumeIsLocal == false {
            return (.nas, values?.volumeURLForRemounting?.absoluteString)
        }
        return (.local, nil)
    }
}

/// Beobachtet Ordner auf dem Mac mit FSEvents und meldet geänderte Pfade.
/// Für das NAS wird stattdessen regelmäßig neu gescannt, weil Netzwerk-Ereignisse unzuverlässig sind.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(paths: [String], latency: TimeInterval = 3, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            watcher.handler(Array(paths.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
