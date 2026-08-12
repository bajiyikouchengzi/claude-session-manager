import Foundation

/// Overlay metadata owned by this app (tags, favorites, title overrides).
struct SessionOverlay: Codable, Hashable {
    var titleOverride: String?
    var isArchivedOverride: Bool?
    var isFavorite: Bool
    var tags: [String]
    var notes: String?

    static let empty = SessionOverlay(titleOverride: nil, isArchivedOverride: nil, isFavorite: false, tags: [], notes: nil)
}

final class OverlayStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "csm.overlay")
    private var map: [String: SessionOverlay] = [:]
    private let url: URL

    init(url: URL = AppPaths.overlaysURL) {
        self.url = url
        load()
    }

    func overlay(for id: String) -> SessionOverlay {
        queue.sync { map[id] ?? .empty }
    }

    func update(_ id: String, mutate: (inout SessionOverlay) -> Void) {
        queue.sync {
            var value = map[id] ?? .empty
            mutate(&value)
            map[id] = value
            saveLocked()
        }
    }

    func remove(_ id: String) {
        queue.sync {
            map.removeValue(forKey: id)
            saveLocked()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: SessionOverlay].self, from: data) else {
            return
        }
        map = decoded
    }

    private func saveLocked() {
        do {
            let data = try JSONEncoder().encode(map)
            try data.write(to: url, options: .atomic)
        } catch {
            // ignore
        }
    }
}
