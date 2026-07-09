import SwiftUI

struct DiscoveredMac: Identifiable {
    let machineId: UUID
    let name: String
    var id: UUID { machineId }
}

/// Bridges RemotePeerManager's pairing callbacks into observable state for the
/// "Add Mac" sheet.
@Observable
final class PairingModel {
    var candidates: [DiscoveredMac] = []
    enum State: Equatable { case idle, pairing, failed }
    var state: State = .idle

    func activate() {
        refresh()
        RemotePeerManager.shared.onCandidatesChanged = { [weak self] in self?.refresh() }
        RemotePeerManager.shared.onPairingFailed = { [weak self] _ in self?.state = .failed }
    }

    func deactivate() {
        RemotePeerManager.shared.onCandidatesChanged = nil
        RemotePeerManager.shared.onPairingFailed = nil
        RemotePeerManager.shared.onPairingSucceeded = nil
    }

    func refresh() {
        candidates = RemotePeerManager.shared.discoveredUnpairedPeers()
            .map { DiscoveredMac(machineId: $0.machineId, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var timeoutTask: Task<Void, Never>?

    func pair(_ mac: DiscoveredMac, pin: String, onSuccess: @escaping () -> Void) {
        state = .pairing
        RemotePeerManager.shared.onPairingSucceeded = { [weak self] _, _ in
            self?.timeoutTask?.cancel()
            self?.state = .idle
            onSuccess()
        }
        RemotePeerManager.shared.startPairing(machineId: mac.machineId, pin: pin)
        // The Mac silently ignores our request if it isn't in pairing mode (or
        // the code is wrong and no failure is signalled) — don't spin forever.
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.state == .pairing else { return }
            RemotePeerManager.shared.cancelPairing(machineId: mac.machineId)
            self.state = .failed
        }
    }
}

struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = PairingModel()
    @State private var selected: DiscoveredMac?
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Group {
                if let mac = selected {
                    pinEntry(mac)
                } else {
                    macList
                }
            }
            .navigationTitle("Add Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
    }

    private var macList: some View {
        List {
            Section {
                if model.candidates.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Searching for Macs on this network…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.candidates) { mac in
                        Button {
                            selected = mac
                            pin = ""
                            model.state = .idle
                        } label: {
                            HStack {
                                Image(systemName: "macbook")
                                Text(mac.name)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } footer: {
                Text("On the Mac, open Notchy's menu bar icon and choose \u{201C}Pair a Device\u{2026}\u{201D}, then enter the code it shows.")
            }
        }
    }

    private func pinEntry(_ mac: DiscoveredMac) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "macbook.and.iphone").font(.system(size: 40))
            Text(mac.name).font(.headline)
            Text("Enter the 6-digit code shown on the Mac.")
                .foregroundStyle(.secondary)
            TextField("000000", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(.largeTitle, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
                .onChange(of: pin) { _, new in
                    pin = String(new.filter(\.isNumber).prefix(6))
                }
            if model.state == .failed {
                Text("Pairing failed — check the code and try again.")
                    .foregroundStyle(.red).font(.callout)
            }
            Button {
                model.pair(mac, pin: pin) { dismiss() }
            } label: {
                if model.state == .pairing {
                    ProgressView()
                } else {
                    Text("Pair").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pin.count != 6 || model.state == .pairing)
            Spacer()
        }
        .padding()
    }
}
