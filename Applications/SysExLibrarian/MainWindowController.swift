/*
 Copyright (c) 2002-2021, Kurt Revis.  All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Cocoa
import SnoizeMIDI

@objc class MainWindowController: GeneralWindowController {

    @objc static var shared = MainWindowController()

    init() {
        self.library = SSELibrary.shared()

        super.init(window: nil)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(libraryDidChange(_:)), name: .SSELibraryDidChange, object: library)
        center.addObserver(self, selector: #selector(displayPreferencesDidChange(_:)), name: .displayPreferenceChanged, object: nil)
        center.addObserver(self, selector: #selector(listenForProgramChangesDidChange(_:)), name: .listenForProgramChangesPreferenceChanged, object: nil)
        center.addObserver(self, selector: #selector(programChangeBaseIndexDidChange(_:)), name: .programChangeBaseIndexPreferenceChanged, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var windowNibName: NSNib.Name? {
        return "MainWindow"
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        window?.showsToolbarButton = false

        if #available(OSX 10.13, *) {
            libraryTableView.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])
            /* TODO Later:
             // https://stackoverflow.com/questions/44537356/swift-4-nsfilenamespboardtype-not-available-what-to-use-instead-for-registerfo
             override func draggingEnded(_ sender: NSDraggingInfo)
             {
                 sender
                     .draggingPasteboard()
                     .readObjects(forClasses: [NSURL.self],
                                  options: nil)?
                     .forEach
                     {
                         // Do something with the file paths.
                         if let url = $0 as? URL { print(url.path) }
                     }
             }
             */
        }
        else {
            // Fallback on earlier versions
            libraryTableView.registerForDraggedTypes([NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        }
        libraryTableView.target = self
        libraryTableView.doubleAction = #selector(play(_:))

        // Fix cells so they don't draw their own background (overdrawing the alternating row colors)
        for tableColumn in libraryTableView.tableColumns {
            (tableColumn.dataCell as? NSTextFieldCell)?.drawsBackground = false
        }

        // The MIDI controller may cause us to do some things to the UI, so we create it now instead of earlier
        midiController = MIDIController(mainWindowController: self)

        updateProgramChangeTableColumnFormatter()
        listenForProgramChangesDidChange(nil)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        synchronizeInterface()
    }

    override func speciallyInitializeToolbarItem(_ toolbarItem: NSToolbarItem!) {
        destinationToolbarItem = toolbarItem

        toolbarItem.view = destinationPopUpButton

        let height = destinationPopUpButton.frame.size.height
        toolbarItem.minSize = NSSize(width: 150, height: height)
        toolbarItem.maxSize = NSSize(width: 1000, height: height)

        let menuTitle = NSLocalizedString("Destination", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "title of destination toolbar item")
        let menuItem = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
        menuItem.submenu = NSMenu(title: "")
        toolbarItem.menuFormRepresentation = menuItem
    }

    override var firstResponderWhenNotEditing: NSResponder? {
        libraryTableView
    }

    // MARK: Actions

    @IBAction func selectDestinationFromPopUpButton(_ sender: Any?) {
        if let popUpButton = sender as? NSPopUpButton,
           let menuItem = popUpButton.selectedItem,
           let destination = menuItem.representedObject as? OutputStreamDestination {
            midiController.selectedDestination = destination
        }
    }

    @IBAction func selectDestinationFromMenuItem(_ sender: Any?) {
        if let menuItem = sender as? NSMenuItem,
           let destination = menuItem.representedObject as? OutputStreamDestination {
            midiController.selectedDestination = destination
        }
    }

    @IBAction override func selectAll(_ sender: Any?) {
        // Forward to the library table view, even if it isn't the first responder
        libraryTableView.selectAll(sender)
    }

    @IBAction func addToLibrary(_ sender: Any?) {
        guard let window = self.window, finishEditingWithoutError() else { return }

        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.allowedFileTypes = library.allowedFileTypes
        openPanel.beginSheetModal(for: window) { response in
            if response == .OK {
                let filenames = openPanel.urls.compactMap { $0.path }
                self.importFiles(filenames, showingProgress: false)
            }
        }
    }

    @IBAction func delete(_ sender: Any?) {
        guard finishEditingWithoutError() else { return }
        deleteController.deleteEntries(selectedEntries)
    }

    @IBAction func recordOne(_ sender: Any?) {
        guard finishEditingWithoutError() else { return }
        recordOneController.beginRecording()
    }

    @IBAction func recordMany(_ sender: Any?) {
        guard finishEditingWithoutError() else { return }
        recordManyController.beginRecording()
    }

    @IBAction func play(_ sender: Any?) {
        guard finishEditingWithoutError() else { return }
        findMissingFilesThen {
            self.playSelectedEntries()
        }
    }

    @IBAction func showFileInFinder(_ sender: Any?) {
        precondition(selectedEntries.count == 1)

        finishEditingInWindow()
        // We don't care if there is an error, go on anyway

        if let path = selectedEntries.first?.path {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
        else {
            NSSound.beep()    // Turns out the file isn't there after all
        }
    }

    @IBAction func rename(_ sender: Any?) {
        let columnIndex = libraryTableView.column(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "name"))

        if libraryTableView.editedRow >= 0 && libraryTableView.editedColumn == columnIndex {
            // We are already editing the name column of the table view, so don't do anything
        }
        else {
            finishEditingInWindow() // In case we are editing something else

            // Make sure that the file really exists right now before we try to rename it
            if let entry = selectedEntries.first,
               entry.isFilePresentIgnoringCachedValue() {
                libraryTableView.editColumn(columnIndex, row: libraryTableView.selectedRow, with: nil, select: true)
            }
            else {
                NSSound.beep()
            }
        }
    }

    @IBAction func changeProgramNumber(_ sender: Any?) {
        let columnIndex = libraryTableView.column(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "programNumber"))

        if libraryTableView.editedRow >= 0 && libraryTableView.editedColumn == columnIndex {
            // We are already editing the program# column of the table view, so don't do anything
        }
        else {
            finishEditingInWindow() // In case we are editing something else

            libraryTableView.editColumn(columnIndex, row: libraryTableView.selectedRow, with: nil, select: true)
        }
    }

    @IBAction func showDetails(_ sender: Any?) {
        guard finishEditingWithoutError() else { return }

        findMissingFilesThen {
            self.showDetailsOfSelectedEntries()
        }
    }

    @IBAction func saveAsStandardMIDI(_ sender: Any?) {
        guard finishEditingWithoutError() else { return }

        findMissingFilesThen {
            self.exportSelectedEntriesAsSMF()
        }
    }

    @IBAction func saveAsSysex(_ sender: Any?) {
        guard finishEditingWithoutError() else { return }

        findMissingFilesThen {
            self.exportSelectedEntriesAsSYX()
        }
    }

    // MARK: Other API

    func synchronizeInterface() {
        synchronizeDestinations()
        synchronizeLibrarySortIndicator()
        synchronizeLibrary()
    }

    func synchronizeDestinations() {
        // Remove empty groups from groupedDestinations
        let groupedDestinations = midiController.groupedDestinations.filter { (group: [OutputStreamDestination]) -> Bool in
            group.count > 0
        }

        let currentDestination = midiController.selectedDestination

        synchronizeDestinationPopUp(destinationGroups: groupedDestinations, currentDestination: currentDestination)
        synchronizeDestinationToolbarMenu(destinationGroups: groupedDestinations, currentDestination: currentDestination)
    }

    func synchronizeLibrarySortIndicator() {
        let column = libraryTableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: sortColumnIdentifier))
        libraryTableView.setSortColumn(column, isAscending: isSortAscending)
        libraryTableView.highlightedTableColumn = column
    }

    func synchronizeLibrary() {
        let selectedEntries = self.selectedEntries

        sortLibraryEntries()

        // NOTE Some entries in selectedEntries may no longer be present in sortedLibraryEntries.
        // We don't need to manually take them out of selectedEntries because selectEntries can deal with
        // entries that are missing.

        libraryTableView.reloadData()
        self.selectedEntries = selectedEntries

        // Sometimes, apparently, reloading the table view will not mark the window as needing update. Weird.
        NSApp.setWindowsNeedUpdate(true)
    }

    func importFiles(_ filePaths: [String], showingProgress: Bool) {
        importController.importFiles(filePaths, showingProgress: showingProgress)
    }

    func showNewEntries(_ newEntries: [SSELibraryEntry]) {
        synchronizeLibrary()
        selectedEntries = newEntries
        scrollToEntries(newEntries)
    }

    func addReadMessagesToLibrary() {
        guard let allSysexData = SystemExclusiveMessage.data(forMessages: midiController.messages) else { return }

        do {
            let entry = try library.addNewEntry(with: allSysexData)
            showNewEntries([entry])
        }
        catch {
            guard let window = window else { return }

            let messageText = NSLocalizedString("Error", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "title of error alert")
            let informativeTextPart1 = NSLocalizedString("The file could not be created.", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "message of alert when recording to a new file fails")
            let informativeText = informativeTextPart1 + "\n" + error.localizedDescription

            let alert = NSAlert()
            alert.messageText = messageText
            alert.informativeText = informativeText
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    func playEntry(withProgramNumber desiredProgramNumber: UInt8) {
        if let entry = sortedLibraryEntries.first(where: { $0.programNumber.uint8Value == desiredProgramNumber }) {
            playController.playMessages(inEntryForProgramChange: entry)
        }
    }

    var selectedEntries: [SSELibraryEntry] {
        get {
            var selectedEntries: [SSELibraryEntry] = []
            for rowIndex in libraryTableView.selectedRowIndexes
            where rowIndex < sortedLibraryEntries.count {
                selectedEntries.append(sortedLibraryEntries[rowIndex])
            }
            return selectedEntries
        }
        set {
            libraryTableView.deselectAll(nil)
            for entry in newValue {
                if let row = sortedLibraryEntries.firstIndex(of: entry) {
                    libraryTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
                }
            }
        }
    }

    // MARK: Private
    @IBOutlet private var destinationPopUpButton: NSPopUpButton!
    @IBOutlet private var libraryTableView: SSETableView!
    @IBOutlet private var programChangeTableColumn: NSTableColumn!

    // Library
    private let library: SSELibrary
    private var sortedLibraryEntries: [SSELibraryEntry] = []

    // Subcontrollers
    private var midiController: MIDIController!
    private lazy var playController = PlayController(mainWindowController: self, midiController: midiController)
    private lazy var recordOneController = RecordOneController(mainWindowController: self, midiController: midiController)
    private lazy var recordManyController = RecordManyController(mainWindowController: self, midiController: midiController)
    private lazy var deleteController = DeleteController(windowController: self)
    private lazy var importController = ImportController(windowController: self, library: library)
    private lazy var exportController = ExportController(windowController: self)
    private lazy var findMissingController = FindMissingController(windowController: self, library: library)

    // Transient data
    private var sortColumnIdentifier = "name"
    private var isSortAscending = true
    private weak var destinationToolbarItem: NSToolbarItem?

}

extension MainWindowController /* Preferences keys */ {

    static let abbreviateFileSizesInLibraryTableViewPreferenceKey = "SSEAbbreviateFileSizesInLibraryTableView"

}

extension MainWindowController /* NSUserInterfaceValidations */ {

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(play(_:)),
             #selector(delete(_:)),
             #selector(showDetails(_:)),
             #selector(saveAsStandardMIDI(_:)),
             #selector(saveAsSysex(_:)):
            return libraryTableView.numberOfSelectedRows > 0
        case #selector(showFileInFinder(_:)),
             #selector(rename(_:)):
            return libraryTableView.numberOfSelectedRows == 1 && selectedEntries.first!.isFilePresent()
        case #selector(changeProgramNumber(_:)):
            return libraryTableView.numberOfSelectedRows == 1 && programChangeTableColumn.tableView != nil
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

}

extension MainWindowController: SSETableViewDataSource {

    // NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        sortedLibraryEntries.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let tableColumn = tableColumn, row < sortedLibraryEntries.count else { return nil }

        let entry = sortedLibraryEntries[row]

        switch tableColumn.identifier.rawValue {
        case "name":
            return entry.name
        case "manufacturer":
            return entry.manufacturer
        case "size":
            if UserDefaults.standard.bool(forKey: Self.abbreviateFileSizesInLibraryTableViewPreferenceKey) {
                return String.abbreviatedByteCount(entry.size.intValue)
            }
            else {
                return entry.size.stringValue
            }
        case "messageCount":
            return entry.messageCount
        case "programNumber":
            if let programNumber = entry.programNumber {
                let baseIndex = UserDefaults.standard.integer(forKey: MIDIController.programChangeBaseIndexPreferenceKey)
                return baseIndex + programNumber.intValue
            }
            else {
                return nil
            }

        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let tableColumn = tableColumn, row < sortedLibraryEntries.count else { return }

        let entry = sortedLibraryEntries[row]

        switch tableColumn.identifier.rawValue {
        case "name":
            if let newName = object as? String {
                if !entry.renameFile(to: newName) {
                    if let window = window {
                        let alert = NSAlert()
                        alert.messageText = NSLocalizedString("Error", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "title of error alert")
                        alert.informativeText = NSLocalizedString("The file for this item could not be renamed.", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "message of alert when renaming a file fails")
                        alert.beginSheetModal(for: window, completionHandler: nil)
                    }
                }
            }

        case "programNumber":
            var newProgramNumber: NSNumber?
            if let newNumber = object as? NSNumber {
                var intValue = newNumber.intValue

                let baseIndex = UserDefaults.standard.integer(forKey: MIDIController.programChangeBaseIndexPreferenceKey)
                intValue -= baseIndex

                if (0...127).contains(intValue) {
                    newProgramNumber = NSNumber(value: intValue)
                }
            }
            entry.programNumber = newProgramNumber

        default:
            break
        }

    }

    // SSETableViewDataSource

    func tableView(_ tableView: SSETableView!, deleteRows rows: IndexSet!) {
        delete(tableView)
    }

    func tableView(_ tableView: SSETableView!, draggingEntered sender: NSDraggingInfo!) -> NSDragOperation {
        // TODO Use new method of getting files as above
        let maybeFilePaths = sender.draggingPasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        if let filePaths = maybeFilePaths as? [String], areAnyFilesAcceptableForImport(filePaths) {
            return .generic
        }
        else {
            return []
        }
    }

    func tableView(_ tableView: SSETableView!, performDragOperation sender: NSDraggingInfo!) -> Bool {
        // TODO Use new method of getting files as above
        let maybeFilePaths = sender.draggingPasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        if let filePaths = maybeFilePaths as? [String] {
            importFiles(filePaths, showingProgress: true)
            return true
        }
        else {
            return false
        }
    }

}

extension MainWindowController: SSETableViewDelegate {

    // NSTableViewDelegate

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let cell = cell as? NSTextFieldCell,
              row < sortedLibraryEntries.count else { return }
        let entry = sortedLibraryEntries[row]

        let color: NSColor
        if entry.isFilePresent() {
            if #available(macOS 10.14, *) {
                color = NSColor.labelColor
            }
            else {
                color = NSColor.black
            }
        }
        else {
            if #available(macOS 10.14, *) {
                color = NSColor.systemRed
            }
            else {
                color = NSColor.red
            }
        }

        cell.textColor = color
    }

    func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
        let columnIdentifier = tableColumn.identifier.rawValue
        if columnIdentifier == sortColumnIdentifier {
            isSortAscending = !isSortAscending
        }
        else {
            sortColumnIdentifier = columnIdentifier
            isSortAscending = true
        }

        synchronizeLibrarySortIndicator()
        synchronizeLibrary()
        scrollToEntries(selectedEntries)
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard let tableColumn = tableColumn, row < sortedLibraryEntries.count else { return false }

        switch tableColumn.identifier.rawValue {
        case "name":
            return sortedLibraryEntries[row].isFilePresent()
        case "programNumber":
            return true
        default:
            return false
        }
    }

    // SSETableViewDelegate

    func tableViewKeyDownReceivedSpace(_ tableView: SSETableView!) -> Bool {
        // Space key is used as a shortcut for -play:
        play(nil)
        return true
    }

}

extension MainWindowController /* Private */ {

    @objc private func displayPreferencesDidChange(_ notification: Notification) {
        libraryTableView.reloadData()
    }

    @objc private func listenForProgramChangesDidChange(_ notification: Notification?) {
        finishEditingInWindow()

        if UserDefaults.standard.bool(forKey: MIDIController.listenForProgramChangesPreferenceKey) {
            if programChangeTableColumn.tableView == nil {
                libraryTableView.addTableColumn(programChangeTableColumn)

                if let nameColumn = libraryTableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "name")) {
                    nameColumn.width -= (programChangeTableColumn.width + 3)
                }
            }
        }
        else {
            if programChangeTableColumn.tableView != nil {
                libraryTableView.removeTableColumn(programChangeTableColumn)

                if let nameColumn = libraryTableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "name")) {
                    nameColumn.width += (programChangeTableColumn.width + 3)
                }
            }
        }
    }

    @objc private func programChangeBaseIndexDidChange(_ notification: Notification) {
        updateProgramChangeTableColumnFormatter()
        libraryTableView.reloadData()
    }

    private func updateProgramChangeTableColumnFormatter() {
        if let cell = programChangeTableColumn.dataCell as? NSCell,
           let formatter = cell.formatter as? NumberFormatter {
            let baseIndex = UserDefaults.standard.integer(forKey: MIDIController.programChangeBaseIndexPreferenceKey)
            formatter.minimum = NSNumber(value: baseIndex + 0)
            formatter.maximum = NSNumber(value: baseIndex + 127)
        }
    }

    private func finishEditingWithoutError() -> Bool {
        finishEditingInWindow()
        return window?.attachedSheet == nil
    }

    // MARK: Destination selections (popup and toolbar menu)

    private func synchronizeDestinationPopUp(destinationGroups: [[OutputStreamDestination]], currentDestination: OutputStreamDestination?) {
        guard let window = window else { return }

        // The pop up button redraws whenever it's changed, so turn off autodisplay to stop the blinkiness
        let wasAutodisplay = window.isAutodisplay
        window.isAutodisplay = false
        defer {
            if wasAutodisplay {
                window.displayIfNeeded()
            }
            window.isAutodisplay = wasAutodisplay
        }

        destinationPopUpButton.removeAllItems()

        var found = false
        for (index, destinations) in destinationGroups.enumerated() {
            if index > 0 {
                destinationPopUpButton.addSeparatorItem()
            }

            for destination in destinations {
                destinationPopUpButton.addItem(title: titleForDestination(destination) ?? "", representedObject: destination)

                if !found && destination === currentDestination {
                    destinationPopUpButton.selectItem(at: destinationPopUpButton.numberOfItems - 1)
                    found = true
                }
            }
        }

        if !found {
            destinationPopUpButton.select(nil)
        }
    }

    private func synchronizeDestinationToolbarMenu(destinationGroups: [[OutputStreamDestination]], currentDestination: OutputStreamDestination?) {
        guard let toolbarItem = destinationToolbarItem else { return }
        // Set the title to "Destination: <Whatever>"
        // Then set up the submenu items

        let topMenuItem = toolbarItem.menuFormRepresentation

        let selectedDestinationTitle = titleForDestination(currentDestination) ?? NSLocalizedString("None", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "none")

        let topTitle = NSLocalizedString("Destination", tableName: "SysExLibrarian", bundle: SMBundleForObject(self), comment: "title of destination toolbar item") + ": " + selectedDestinationTitle
        topMenuItem?.title = topTitle

        if let submenu = topMenuItem?.submenu {
            submenu.removeAllItems()

            var found = false
            for (index, destinations) in destinationGroups.enumerated() {
                if index > 0 {
                    submenu.addItem(NSMenuItem.separator())
                }

                for destination in destinations {
                    let title = titleForDestination(destination) ?? ""
                    let menuItem = submenu.addItem(withTitle: title, action: #selector(selectDestinationFromMenuItem(_:)), keyEquivalent: "")
                    menuItem.representedObject = destination
                    menuItem.target = self

                    if !found && destination === currentDestination {
                        menuItem.state = .on
                        found = true
                    }
                }
            }
        }

        // Workaround to get the toolbar item to refresh after we change the title of the menu item
        toolbarItem.menuFormRepresentation = nil
        toolbarItem.menuFormRepresentation = topMenuItem
    }

    private func titleForDestination(_ destination: OutputStreamDestination?) -> String? {
        destination?.outputStreamDestinationName
    }

    // MARK: Library interaction

    @objc private func libraryDidChange(_ notification: Notification) {
        // Reloading the table view will wipe out the edit session, so don't do that if we're editing
        if libraryTableView.editedRow == -1 {
            synchronizeLibrary()
        }
    }

    private func sortLibraryEntries() {
        if let entries = library.entries() {
            let sortedEntries = entries.sorted(by: { (entry1, entry2) -> Bool in
                switch sortColumnIdentifier {
                case "name":
                    return entry1.name < entry2.name
                case "manufacturer":
                    return entry1.manufacturer < entry2.manufacturer
                case "size":
                    return entry1.size.intValue < entry2.size.intValue
                case "messageCount":
                    return entry1.messageCount.intValue < entry2.messageCount.intValue
                case "programNumber":
                    return entry1.programNumber.intValue < entry2.programNumber.intValue
                default:
                    fatalError()
                }
            })

            self.sortedLibraryEntries = isSortAscending ? sortedEntries : sortedEntries.reversed()
        }
    }

    private func scrollToEntries(_ entries: [SSELibraryEntry]) {
        guard entries.count > 0 else { return }

        var lowestRow = Int.max
        for entry in entries {
            if let row = sortedLibraryEntries.firstIndex(of: entry) {
                lowestRow = min(lowestRow, row)
            }
        }

        libraryTableView.scrollRowToVisible(lowestRow)
    }

    // MARK: Doing things with selected entries

    private var selectedMessages: [SystemExclusiveMessage] {
        Array(selectedEntries.compactMap({ $0.messages }).joined())
    }

    private func playSelectedEntries() {
        let messages = selectedMessages
        if !messages.isEmpty {
            playController.playMessages(messages)
        }
    }

    private func showDetailsOfSelectedEntries() {
        for entry in selectedEntries {
            DetailsWindowController.showWindow(forEntry: entry)
        }
    }

    private func exportSelectedEntriesAsSMF() {
        exportSelectedEntries(true)
    }

    private func exportSelectedEntriesAsSYX() {
        exportSelectedEntries(false)
    }

    private func exportSelectedEntries(_ asSMF: Bool) {
        guard let fileName = selectedEntries.first?.name else { return }

        let messages = selectedMessages
        guard !messages.isEmpty else { return }

        exportController.exportMessages(messages, fromFileName: fileName, asSMF: asSMF)
    }

    // MARK: Add files / importing

    private func areAnyFilesAcceptableForImport(_ filePaths: [String]) -> Bool {
        let fileManager = FileManager.default

        for filePath in filePaths {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return true
                }

                if fileManager.isReadableFile(atPath: filePath) && library.typeOfFile(atPath: filePath) != SSELibraryFileType.unknown {
                    return true
                }
            }
        }

        return false
    }

    // MARK: Finding missing files

    private func findMissingFilesThen(successfulCompletion: @escaping (() -> Void)) {
        let entriesWithMissingFiles = selectedEntries.filter { !$0.isFilePresentIgnoringCachedValue() }
        if entriesWithMissingFiles.count == 0 {
            successfulCompletion()
        }
        else {
            findMissingController.findMissingFiles(forEntries: entriesWithMissingFiles, completion: successfulCompletion)
        }
    }
}
