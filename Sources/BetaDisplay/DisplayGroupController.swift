import CoreGraphics
import Foundation

struct DisplayGroup: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var displayKeys: [String]

    init(id: UUID = UUID(), name: String, displayKeys: [String]) {
        self.id = id
        self.name = name
        self.displayKeys = displayKeys
    }
}

@MainActor
final class DisplayGroupController {
    private(set) var groups: [DisplayGroup] = []
    var selectedGroupID: UUID?
    private(set) var statusMessage = L10n.text("status.no_groups")
    var onStateChanged: (() -> Void)?

    private let storageKey = "BetaDisplay.displayGroups"

    init() {
        load()
    }

    var selectedGroup: DisplayGroup? {
        groups.first { $0.id == selectedGroupID }
    }

    func createGroup(name: String, displayIDs: [CGDirectDisplayID]) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            statusMessage = L10n.text("status.group_name_required")
            publish()
            return
        }
        guard !displayIDs.isEmpty else {
            statusMessage = L10n.text("status.group_members_required")
            publish()
            return
        }
        let displayKeys = displayIDs.compactMap { DisplayIdentity.key(for: $0) }
        guard displayKeys.count == displayIDs.count else {
            statusMessage = L10n.text("status.group_members_required")
            publish()
            return
        }
        let group = DisplayGroup(name: normalizedName, displayKeys: displayKeys)
        groups.append(group)
        selectedGroupID = group.id
        save()
        statusMessage = L10n.text("status.group_created", group.name)
        publish()
    }

    func updateSelectedGroup(displayIDs: [CGDirectDisplayID]) {
        guard let index = groups.firstIndex(where: { $0.id == selectedGroupID }) else { return }
        let displayKeys = displayIDs.compactMap { DisplayIdentity.key(for: $0) }
        guard displayKeys.count == displayIDs.count else {
            statusMessage = L10n.text("status.group_members_required")
            publish()
            return
        }
        groups[index].displayKeys = displayKeys
        save()
        statusMessage = L10n.text("status.group_members_updated")
        publish()
    }

    func deleteSelectedGroup() {
        guard let id = selectedGroupID else { return }
        groups.removeAll { $0.id == id }
        selectedGroupID = groups.first?.id
        save()
        statusMessage = L10n.text("status.group_deleted")
        publish()
    }

    func synchronize(adjustments: ColorAdjustments, displayController: DisplayController) {
        guard let group = selectedGroup else {
            statusMessage = L10n.text("status.select_group")
            publish()
            return
        }
        let activeDisplays = Dictionary(
            uniqueKeysWithValues: displayController.displays.compactMap { display in
                DisplayIdentity.key(for: display.id).map { ($0, display.id) }
            }
        )
        let ids = group.displayKeys.compactMap { activeDisplays[$0] }
        let result = displayController.apply(adjustments: adjustments, to: ids)
        let successCount = result.values.filter { $0 }.count
        statusMessage = successCount == ids.count
            ? L10n.text("status.group_synced", successCount)
            : L10n.text("status.group_synced_partial", successCount, ids.count)
        publish()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        guard let decoded = try? JSONDecoder().decode([DisplayGroup].self, from: data) else { return }
        groups = decoded
        selectedGroupID = groups.first?.id
        statusMessage = groups.isEmpty
            ? L10n.text("status.no_groups")
            : L10n.text("status.groups_loaded", groups.count)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func publish() {
        onStateChanged?()
    }
}
