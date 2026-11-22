import AppKit
import BasilCore

/// One folder tab of a pane (Total Commander folder tabs). The active tab's live state is in the
/// pane's model; the others keep where they were.
struct PaneTab: Codable, Equatable {
    var directory: VFSPath
    var cursor: VFSPath?
    /// Set by Rename Tab; nil shows the folder name.
    var customName: String?
    /// A locked tab keeps its folder: going into another folder opens a new tab (TC).
    var locked = false
    var sort: ListSortOrder
    var viewID: String

    var title: String { customName ?? PathBar.segments(of: directory).last?.title ?? directory.displayName }
}

/// The tab row above a pane's path bar, shown when the pane has more than one tab. A tab group
/// whose tabs are radio buttons, so VoiceOver reads "Downloads, selected, tab 2 of 3".
@MainActor
final class TabBar: ThemedBox {
    var onSelect: ((Int) -> Void)?
    private let stack = NSStackView()
    private var buttons: [NSButton] = []
    var isActive = false

    init(side: PaneSide) {
        super.init(frame: .zero)
        fillColor = Theme.barBackground
        bottomBorder = true
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("\(side.accessibilityLabel) tabs")
        setAccessibilityIdentifier("pane.\(side.identifier).tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ tabs: [PaneTab], active: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = []
        for (index, tab) in tabs.enumerated() {
            // "(locked)" in words: the state must not be shown by colour or a symbol alone.
            let title = tab.locked ? "\(tab.title) (locked)" : tab.title
            let button = NSButton(title: title, target: self, action: #selector(clicked(_:)))
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = Theme.barFont
            button.refusesFirstResponder = true
            button.setButtonType(.pushOnPushOff)
            button.state = index == active ? .on : .off
            button.tag = index
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(title)
            button.setAccessibilityValue(index == active ? 1 : 0)
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        onSelect?(sender.tag)
    }
}

extension PaneViewController {
    private var tabsKey: String { "pane.\(side.identifier).tabs" }
    private var activeTabKey: String { "pane.\(side.identifier).activeTab" }

    var tabCount: Int { tabs.count }
    var activeTab: PaneTab { tabs[activeTabIndex] }

    /// The live state of the active tab.
    private func currentTabState() -> PaneTab {
        var tab = tabs[activeTabIndex]
        tab.directory = model.directory
        tab.cursor = cursorPath
        tab.sort = model.sortOrder
        tab.viewID = viewID
        return tab
    }

    /// Called whenever the pane shows a folder: keeps the tab title and the saved tabs current.
    func tabsDirectoryChanged() {
        tabs[activeTabIndex] = currentTabState()
        tabsChanged()
    }

    private func tabsChanged() {
        tabBar.show(tabs, active: activeTabIndex)
        tabBar.isHidden = tabs.count < 2
        saveTabs()
    }

    /// Tabs restored at launch, except where start folders are forced (UI tests).
    func restoreTabs() {
        guard let data = defaults.data(forKey: tabsKey),
              let saved = try? JSONDecoder().decode([PaneTab].self, from: data), !saved.isEmpty else { return }
        let active = min(max(defaults.integer(forKey: activeTabKey), 0), saved.count - 1)
        tabs = saved
        activeTabIndex = active
        // The active tab's folder is the pane's start folder (already restored); keep the others.
        tabs[active].directory = model.directory
        applyTabView(tabs[active].viewID, sort: tabs[active].sort)
        tabsChanged()
    }

    private func saveTabs() {
        guard persistsTabs else { return }
        // Inside an archive, the folder holding it is remembered: providers do not survive a restart.
        let stored = tabs.map { tab -> PaneTab in
            var tab = tab
            let outermost = tab.directory.outermostContainer
            if outermost != tab.directory, let folder = outermost.parent {
                tab.directory = folder
                tab.cursor = outermost
            }
            if tab.directory.location != .local { tab.directory = .local(FileManager.default.homeDirectoryForCurrentUser.path) }
            return tab
        }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: tabsKey) }
        defaults.set(activeTabIndex, forKey: activeTabKey)
    }

    /// Cmd+T: a new tab with the current folder, after the current tab.
    func newTab(at directory: VFSPath? = nil, cursor: VFSPath? = nil, duplicate: Bool = false) {
        tabs[activeTabIndex] = currentTabState()
        var tab = tabs[activeTabIndex]
        if !duplicate {
            tab.customName = nil
            tab.locked = false
        }
        if let directory {
            tab.directory = directory
            tab.cursor = cursor
        }
        tabs.insert(tab, at: activeTabIndex + 1)
        switchToTab(activeTabIndex + 1, saveCurrent: false)
    }

    /// Cmd+W: closes the active tab; the last one stays.
    func closeTab() {
        guard tabs.count > 1 else { return delegate?.pane(self, announce: "This is the only tab") ?? () }
        tabs.remove(at: activeTabIndex)
        switchToTab(min(activeTabIndex, tabs.count - 1), saveCurrent: false)
    }

    func closeOtherTabs() {
        guard tabs.count > 1 else { return delegate?.pane(self, announce: "This is the only tab") ?? () }
        tabs = [currentTabState()]
        activeTabIndex = 0
        tabsChanged()
        announceTab()
    }

    /// Ctrl+Tab / Ctrl+Shift+Tab, wrapping around.
    func cycleTab(by offset: Int) {
        guard tabs.count > 1 else { return delegate?.pane(self, announce: "This is the only tab") ?? () }
        switchToTab((activeTabIndex + offset + tabs.count) % tabs.count)
    }

    /// Cmd+1 ... Cmd+9.
    func goToTab(_ number: Int) {
        guard tabs.indices.contains(number - 1) else { return delegate?.pane(self, announce: "No tab \(number)") ?? () }
        switchToTab(number - 1)
    }

    func toggleTabLock() {
        tabs[activeTabIndex].locked.toggle()
        tabsChanged()
        delegate?.pane(self, announce: tabs[activeTabIndex].locked ? "Tab locked" : "Tab unlocked")
    }

    /// An empty name goes back to the folder name.
    func renameTab(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        tabs[activeTabIndex].customName = trimmed.isEmpty ? nil : trimmed
        tabsChanged()
    }

    func switchToTab(_ index: Int, saveCurrent: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        if saveCurrent { tabs[activeTabIndex] = currentTabState() }
        activeTabIndex = index
        let tab = tabs[index]
        applyTabView(tab.viewID, sort: tab.sort)
        model.load(tab.directory, cursor: tab.cursor)
        tabsChanged()
        announceTab()
        view.window?.makeFirstResponder(tableView)
    }

    /// "Tab 2 of 3, Downloads".
    private func announceTab() {
        delegate?.pane(self, announce: "Tab \(activeTabIndex + 1) of \(tabs.count), \(tabs[activeTabIndex].title)")
    }
}

extension MainWindowController {
    /// Tabs > Rename Tab: an empty name shows the folder name again.
    func renameTab() {
        guard let window else { return }
        let pane = activePane
        Task {
            guard let name = await askText(in: window, message: "Tab name:", initial: pane.activeTab.customName ?? "",
                                           confirm: "Rename", fieldLabel: "Tab name") else { return }
            pane.renameTab(name)
        }
    }
}
