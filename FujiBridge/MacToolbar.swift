import UIKit

/// The Mac window's title bar, used as a real toolbar the way Finder does: the grid switch in the
/// middle and the grid's action on the right, instead of an empty strip above a second header row.
/// iPhone and iPad keep the header in the view, so this is inert there.
@MainActor
final class MacToolbar: NSObject {
    static let shared = MacToolbar()

    var onTab: ((GalleryTab) -> Void)?
    var onAction: (() -> Void)?

    #if targetEnvironment(macCatalyst)
    private static let tabsID = NSToolbarItem.Identifier("fujibridge.tabs")
    private static let actionID = NSToolbarItem.Identifier("fujibridge.action")

    private lazy var toolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "fujibridge.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifier = Self.tabsID
        return toolbar
    }()
    private var tabs: NSToolbarItemGroup?
    private var action: UIBarButtonItem?
    private var actionItem: NSToolbarItem?
    #endif

    private var titles = ["Imported", "On the camera"]
    private var selected = 0
    private var actionTitle: String? = "Show in Finder"
    private var galleryVisible = true

    func install(on scene: UIWindowScene) {
        #if targetEnvironment(macCatalyst)
        guard let titlebar = scene.titlebar else { return }
        titlebar.titleVisibility = .hidden
        titlebar.toolbarStyle = .unified
        // A hairline under the bar keeps it apart from the grid, which is as dark as the bar itself.
        titlebar.separatorStyle = .line
        if titlebar.toolbar !== toolbar { titlebar.toolbar = toolbar }
        #endif
    }

    /// Keeps the toolbar in step with the view: which grid is shown, the counts, what the action does.
    func update(tab: GalleryTab, imported: Int, camera: Int, action title: String?) {
        titles = ["Imported · \(imported)", camera > 0 ? "On the camera · \(camera)" : "On the camera"]
        selected = tab == .imported ? 0 : 1
        actionTitle = title
        #if targetEnvironment(macCatalyst)
        if let tabs {
            for (index, item) in tabs.subitems.enumerated() where index < titles.count {
                item.label = titles[index]
                item.title = titles[index]
            }
            tabs.selectedIndex = selected
        }
        // The item copies the button's title when it is made; change both, or the old label stays.
        action?.title = title ?? " "
        action?.isEnabled = title != nil
        actionItem?.title = title ?? " "
        actionItem?.label = title ?? ""
        actionItem?.isEnabled = title != nil
        // Nothing to do on this grid: take the button away rather than leave an empty bordered circle.
        applyVisibility()
        #endif
    }

    /// The switch and the action belong to the grid; pages pushed over it (Diagnostics) hide them.
    func setGalleryVisible(_ visible: Bool) {
        galleryVisible = visible
        #if targetEnvironment(macCatalyst)
        applyVisibility()
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func applyVisibility() {
        guard #available(macCatalyst 18.0, *) else { return }
        tabs?.isHidden = !galleryVisible
        // Nothing to do on this grid: take the button away rather than leave an empty bordered circle.
        actionItem?.isHidden = !galleryVisible || actionTitle == nil
    }
    #endif

    #if targetEnvironment(macCatalyst)
    @objc private func tabChanged(_ sender: NSToolbarItemGroup) {
        onTab?(sender.selectedIndex == 0 ? .imported : .camera)
    }

    @objc private func actionTapped() {
        onAction?()
    }
    #endif
}

#if targetEnvironment(macCatalyst)
extension MacToolbar: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.tabsID, .flexibleSpace, Self.actionID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.tabsID:
            let group = NSToolbarItemGroup(itemIdentifier: id, titles: titles, selectionMode: .selectOne, labels: titles, target: self, action: #selector(tabChanged(_:)))
            group.selectedIndex = selected
            if #available(macCatalyst 18.0, *) { group.isHidden = !galleryVisible }
            tabs = group
            return group
        case Self.actionID:
            let button = UIBarButtonItem(title: actionTitle ?? "", style: .plain, target: self, action: #selector(actionTapped))
            button.isEnabled = actionTitle != nil
            action = button
            let item = NSToolbarItem(itemIdentifier: id, barButtonItem: button)
            item.isBordered = true
            actionItem = item
            if #available(macCatalyst 18.0, *) { item.isHidden = !galleryVisible || actionTitle == nil }
            return item
        default:
            return nil
        }
    }
}
#endif
