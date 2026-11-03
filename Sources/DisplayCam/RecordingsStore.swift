import AVFoundation
import AppKit
import Combine

struct Recording: Identifiable, Hashable {
    enum Kind { case practice, replay }

    let url: URL
    let date: Date
    let bytes: Int64

    var id: URL { url }
    var kind: Kind { url.lastPathComponent.hasPrefix(RecordingsStore.replayPrefix) ? .replay : .practice }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

/// The recordings folder (default ~/Movies/DisplayCam): listing, thumbnails, durations.
@MainActor
final class RecordingsStore: ObservableObject {
    nonisolated static let practicePrefix = "练习"
    nonisolated static let replayPrefix = "回放"

    @Published private(set) var items: [Recording] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var durations: [URL: Double] = [:]
    @Published var folder: URL {
        didSet {
            UserDefaults.standard.set(folder.path, forKey: "recordingsFolder")
            reload()
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "recordingsFolder")
        folder = saved.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DisplayCam", isDirectory: true)
    }

    func newFileURL(kind: Recording.Kind) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let prefix = kind == .replay ? Self.replayPrefix : Self.practicePrefix
        return folder.appendingPathComponent("\(prefix) \(formatter.string(from: Date())).mp4")
    }

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        items = files
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Recording(url: url, date: values?.creationDate ?? .distantPast,
                                 bytes: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
        for item in items where thumbnails[item.url] == nil { loadDetails(item.url) }
    }

    func open(_ item: Recording) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func moveToTrash(_ item: Recording) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        thumbnails[item.url] = nil
        durations[item.url] = nil
        reload()
    }

    private func loadDetails(_ url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                durations[url] = duration.seconds
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            if let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                thumbnails[url] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }
}
