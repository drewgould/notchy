import Foundation

/// Durable cross-Mac sync via plain files in the user's iCloud Drive.
///
/// Layout:
///   ~/Library/Mobile Documents/com~apple~CloudDocs/Notchy/
///     machines/<machineId>.json   — one manifest per Mac
///     requests/<requestId>.json   — queued remote-tab creation requests
///
/// Conflict handling: none needed, by construction. Every manifest has exactly
/// one writer (its own machine). A request file is created once by the viewer
/// and thereafter only deleted (or rewritten with status="failed") by the
/// single targeted worker — there are never two concurrent writers of the
/// same file, so iCloud conflict copies cannot arise.
///
/// Reads use directory polling rather than NSMetadataQuery — a deliberate
/// simplicity trade for a personal tool; 15s latency is fine because live
/// updates ride the local network anyway.
@Observable
final class CloudSyncManager {
    static let shared = CloudSyncManager()

    private static let cloudDocsPath = ("~/Library/Mobile Documents/com~apple~CloudDocs" as NSString).expandingTildeInPath
    private let rootURL = URL(fileURLWithPath: CloudSyncManager.cloudDocsPath).appendingPathComponent("Notchy")
    private var machinesURL: URL { rootURL.appendingPathComponent("machines") }
    private var requestsURL: URL { rootURL.appendingPathComponent("requests") }

    /// iCloud Drive exists on this Mac. When false every method is a no-op.
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.cloudDocsPath)
    }

    /// Last decoded manifest per remote machine — powers the "New Session on
    /// <machine>…" menu and offline placeholders.
    private(set) var knownMachines: [UUID: MachineManifest] = [:]

    /// Machines a remote tab can be created on, freshest first. Manifests
    /// silent for a week are presumed retired.
    var creationTargets: [MachineManifest] {
        knownMachines.values
            .filter { Date().timeIntervalSince($0.lastSeen) < 7 * 24 * 3600 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var publishDebounce: Timer?
    private var heartbeatTimer: Timer?
    private var pollTimer: Timer?
    private var isRunning = false

    /// Serialized file I/O off the main thread.
    private let ioQueue = DispatchQueue(label: "com.notchy.cloudsync", qos: .utility)

    private static let processedRequestsKey = "processedRemoteRequestIds"
    private var processedRequestIds: [UUID] = {
        let strings = UserDefaults.standard.stringArray(forKey: CloudSyncManager.processedRequestsKey) ?? []
        return strings.compactMap(UUID.init(uuidString:))
    }()

    private static let publishDebounceInterval: TimeInterval = 3
    private static let heartbeatInterval: TimeInterval = 60
    private static let pollInterval: TimeInterval = 15

    func start() {
        guard SettingsManager.shared.remoteTabsEnabled, isAvailable, !isRunning else { return }
        isRunning = true
        ioQueue.async { [rootURL, machinesURL, requestsURL] in
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: machinesURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: requestsURL, withIntermediateDirectories: true)
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.publishNow()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        publishNow()
        poll()
    }

    func stop() {
        isRunning = false
        publishDebounce?.invalidate()
        publishDebounce = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        knownMachines = [:]
    }

    // MARK: - Publish (this Mac's manifest)

    /// Coalesces bursts of session churn into one manifest write.
    func schedulePublish() {
        guard isRunning else { return }
        if publishDebounce != nil { return }
        publishDebounce = Timer.scheduledTimer(withTimeInterval: Self.publishDebounceInterval, repeats: false) { [weak self] _ in
            self?.publishDebounce = nil
            self?.publishNow()
        }
    }

    /// `waitUntilDone` is for applicationWillTerminate — an async write would
    /// race process exit.
    func publishNow(waitUntilDone: Bool = false) {
        guard isRunning else { return }
        let manifest = buildManifest()
        let url = machinesURL.appendingPathComponent("\(MachineIdentity.id.uuidString).json")
        let write = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(manifest) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if waitUntilDone {
            ioQueue.sync(execute: write)
        } else {
            ioQueue.async(execute: write)
        }
    }

    /// Snapshot this Mac's local sessions. Must run on main (reads SessionStore).
    private func buildManifest() -> MachineManifest {
        let store = SessionStore.shared
        let sessions = store.currentSessionSnapshots()
        let groups = store.projectGroups
            .filter { $0.remoteMachineId == nil }
            .map { GroupSnapshot(name: $0.name, rootPath: $0.rootPath) }
        return MachineManifest(
            machineId: MachineIdentity.id,
            name: MachineIdentity.displayName,
            hostname: MachineIdentity.hostname,
            lastSeen: Date(),
            sessions: sessions,
            groups: groups
        )
    }

    // MARK: - Poll (other Macs' manifests + requests targeting us)

    private func poll() {
        guard isRunning else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let manifests = self.readRemoteManifests()
            let requests = self.readPendingRequests()
            DispatchQueue.main.async {
                for manifest in manifests {
                    self.knownMachines[manifest.machineId] = manifest
                    RemoteSessionCoordinator.shared.applyManifest(manifest)
                }
                for (request, url) in requests {
                    guard !self.processedRequestIds.contains(request.requestId) else { continue }
                    self.markRequestProcessed(request.requestId)
                    RemoteSessionCoordinator.shared.handleCreateRequest(request, fileURL: url)
                }
            }
        }
    }

    private func readRemoteManifests() -> [MachineManifest] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: machinesURL, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifests: [MachineManifest] = []
        for url in urls where url.pathExtension == "json" {
            guard url.deletingPathExtension().lastPathComponent != MachineIdentity.id.uuidString else { continue }
            guard ensureDownloaded(url) else { continue }
            // Decode failures are skipped silently — the file may be mid-upload.
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(MachineManifest.self, from: data),
                  manifest.machineId != MachineIdentity.id else { continue }
            manifests.append(manifest)
        }
        return manifests
    }

    private func readPendingRequests() -> [(RemoteCreateRequest, URL)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: requestsURL, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var requests: [(RemoteCreateRequest, URL)] = []
        for url in urls where url.pathExtension == "json" {
            guard ensureDownloaded(url) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let request = try? decoder.decode(RemoteCreateRequest.self, from: data),
                  request.targetMachineId == MachineIdentity.id,
                  request.status == "pending" else { continue }
            requests.append((request, url))
        }
        return requests
    }

    /// Another Mac's writes land as dataless placeholders first — kick off the
    /// download and skip the file until a later poll cycle finds it material.
    private func ensureDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus else {
            // Not an ubiquitous item (e.g. loopback testing outside iCloud) — read directly.
            return true
        }
        if status == .current { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return false
    }

    // MARK: - Create requests

    /// Queue a "create this tab on that Mac" request for a currently-offline
    /// worker. Online workers get the request over the network instead.
    func enqueueCreateRequest(_ request: RemoteCreateRequest) {
        guard isRunning else { return }
        let url = requestsURL.appendingPathComponent("\(request.requestId.uuidString).json")
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(request) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Called by the worker after executing a request: delete on success, or
    /// rewrite with status="failed" so the requesting Mac can surface the error.
    func completeRequest(_ request: RemoteCreateRequest, fileURL: URL, error: String?) {
        ioQueue.async {
            if let error {
                var failed = request
                failed.status = "failed"
                failed.error = error
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(failed) {
                    try? data.write(to: fileURL, options: .atomic)
                }
            } else {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func markRequestProcessed(_ id: UUID) {
        processedRequestIds.append(id)
        if processedRequestIds.count > 100 {
            processedRequestIds.removeFirst(processedRequestIds.count - 100)
        }
        UserDefaults.standard.set(processedRequestIds.map(\.uuidString), forKey: Self.processedRequestsKey)
    }
}
