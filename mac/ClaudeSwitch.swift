// ClaudeSwitch for macOS — launches Claude Desktop with a profile of your choice.
// Same idea as the Windows version (../ClaudeSwitch.cs): the first profile is always the
// default one and uses the existing Claude login; every other profile runs Claude with
// its own --user-data-dir, so a second account can run alongside it. Profiles live in
// the app's user defaults (io.github.oizopower.ClaudeSwitch).
// Without arguments the picker window opens; with a profile name it launches directly.
//
// Copyright (C) 2026 Oizopower. Licensed under the GNU GPL v3 or later; see LICENSE.
import AppKit

struct Profile {
    var name: String
    var path: String   // empty = the default Claude profile
}

struct LaunchError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

let colBg = NSColor(srgbRed: 38 / 255, green: 38 / 255, blue: 36 / 255, alpha: 1)
let colText = NSColor(srgbRed: 245 / 255, green: 244 / 255, blue: 239 / 255, alpha: 1)
let colDim = NSColor(srgbRed: 140 / 255, green: 140 / 255, blue: 135 / 255, alpha: 1)
let colOrange = NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
let colSlate = NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 56 / 255, alpha: 1)

// ---------- profile storage (user defaults) ----------

enum Store {
    static let defaults = UserDefaults.standard

    static func loadProfiles() -> [Profile] {
        var list: [Profile] = []
        if let raw = defaults.array(forKey: "Profiles") {
            for case let entry as [String: Any] in raw {
                guard let name = entry["Name"] as? String, !name.isEmpty else { continue }
                list.append(Profile(name: name, path: (entry["Path"] as? String) ?? ""))
            }
        }
        if list.isEmpty {
            list = [Profile(name: "Work", path: ""),
                    Profile(name: "Personal", path: suggestPath("Personal"))]
        }
        list[0].path = ""   // the first profile is always the default one
        saveProfiles(list)
        return list
    }

    static func saveProfiles(_ list: [Profile]) {
        defaults.set(list.map { ["Name": $0.name, "Path": $0.path] }, forKey: "Profiles")
    }

    // Number of button columns the user chose by resizing the picker.
    static var columns: Int {
        get { let v = defaults.integer(forKey: "Columns"); return v > 0 ? v : Grid.defaultColumns }
        set { defaults.set(newValue, forKey: "Columns") }
    }
}

// For name comparison and folder names: case and accents ignored.
func normalize(_ s: String) -> String {
    return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

// New profile folders go under Application Support. They are stored with a leading ~
// so a profile stays valid for another user or Mac.
func suggestPath(_ name: String) -> String {
    let slug = String(normalize(name).map { $0.isLetter || $0.isNumber ? $0 : "-" })
    return "~/Library/Application Support/ClaudeSwitch/profiles/" + slug
}

// Paths may start with ~ and contain variables ($HOME, ${HOME}). They are stored as typed
// and expanded on use. A trailing slash is dropped so the same folder always compares equal.
func expandPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "" }
    let env = ProcessInfo.processInfo.environment
    let regex = try! NSRegularExpression(pattern: "\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}|\\$([A-Za-z_][A-Za-z0-9_]*)")
    let ns = trimmed as NSString
    var result = ""
    var last = 0
    for m in regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        let nameRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
        result += env[ns.substring(with: nameRange)] ?? ns.substring(with: m.range)
        last = m.range.location + m.range.length
    }
    result += ns.substring(from: last)
    var expanded = (result as NSString).expandingTildeInPath
    while expanded.count > 1 && expanded.hasSuffix("/") { expanded.removeLast() }
    return expanded
}

// ---------- launching Claude ----------

enum Launcher {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    static func claudeApp() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) { return url }
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let url = URL(fileURLWithPath: dir + "/Claude.app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // Running Claude main processes with their --user-data-dir ("" = the default profile).
    // Helper processes live in other executables and are skipped.
    static func runningInstances(executable: String) -> [(pid: pid_t, dir: String)] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,args="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        do { try ps.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        var found: [(pid: pid_t, dir: String)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { continue }
            let args = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard args == executable || args.hasPrefix(executable + " ") else { continue }
            var dir = ""
            if let marker = args.range(of: "--user-data-dir=") {
                dir = String(args[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
                if dir.hasPrefix("\"") && dir.hasSuffix("\"") && dir.count >= 2 { dir = String(dir.dropFirst().dropLast()) }
                while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
            }
            found.append((pid, dir))
        }
        return found
    }

    // Brings the profile's Claude to the front when it already runs, otherwise starts a new
    // instance of Claude for it. macOS normally keeps one instance per app, so new ones are
    // started with open -n.
    static func start(_ profile: Profile) throws {
        guard let app = claudeApp() else {
            throw LaunchError("Claude Desktop was not found. Is it installed in Applications?")
        }
        let dir = expandPath(profile.path)
        if let exe = Bundle(url: app)?.executableURL?.resolvingSymlinksInPath().path {
            for instance in runningInstances(executable: exe) where instance.dir == dir {
                if let running = NSRunningApplication(processIdentifier: instance.pid) {
                    if #available(macOS 14.0, *) { running.activate() }
                    else { running.activate(options: [.activateIgnoringOtherApps]) }
                    return
                }
            }
        }

        var args = ["-n", "-a", app.path]
        if !dir.isEmpty {
            guard dir.hasPrefix("/") else { throw LaunchError("The folder of this profile is not valid: " + profile.path) }
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            args += ["--args", "--user-data-dir=" + dir]
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = args
        try open.run()
        open.waitUntilExit()
        if open.terminationStatus != 0 { throw LaunchError("Claude Desktop could not be started.") }
    }
}

// ---------- UI helpers ----------

class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

func makeLabel(_ text: String, size: CGFloat = 13, color: NSColor = colText) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: size)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

func styleButton(_ button: NSButton, back: NSColor, fore: NSColor, size: CGFloat) {
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.backgroundColor = back.cgColor
    button.layer?.cornerRadius = 6
    button.attributedTitle = NSAttributedString(string: button.title, attributes: [
        .foregroundColor: fore,
        .font: NSFont.systemFont(ofSize: size, weight: .semibold),
    ])
}

func showError(_ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "ClaudeSwitch"
    alert.informativeText = message
    alert.runModal()
}

func confirm(_ message: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "ClaudeSwitch"
    alert.informativeText = message
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

// ---------- editing a single profile ----------

final class FolderChooser: NSObject {
    let field: NSTextField
    init(field: NSTextField) { self.field = field }

    @objc func choose(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder for this profile"
        if panel.runModal() == .OK, let url = panel.url { field.stringValue = url.path }
    }
}

// Dialog for one profile (new or existing). Validates the name, rejects duplicates and
// checks the folder; returns the changed profile, or nil when cancelled.
func editProfile(_ profile: Profile, isDefault: Bool, all: [Profile], selfIndex: Int?) -> Profile? {
    let width: CGFloat = 380
    let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: isDefault ? 64 : 110))

    view.addSubview(makeLabel("Name:", color: .labelColor))
    view.subviews.last!.frame = NSRect(x: 0, y: 3, width: 60, height: 18)
    let nameField = NSTextField(string: profile.name)
    nameField.frame = NSRect(x: 64, y: 0, width: width - 64, height: 24)
    view.addSubview(nameField)

    var pathField: NSTextField? = nil
    var chooser: FolderChooser? = nil
    if isDefault {
        let note = makeLabel("This is the default profile: your existing Claude login. Only the name can be changed.", size: 11, color: .secondaryLabelColor)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        note.frame = NSRect(x: 0, y: 32, width: width, height: 32)
        view.addSubview(note)
    } else {
        view.addSubview(makeLabel("Folder:", color: .labelColor))
        view.subviews.last!.frame = NSRect(x: 0, y: 39, width: 60, height: 18)
        let field = NSTextField(string: profile.path)
        field.frame = NSRect(x: 64, y: 36, width: width - 64 - 90, height: 24)
        view.addSubview(field)
        let picker = FolderChooser(field: field)
        let browse = NSButton(title: "Choose…", target: picker, action: #selector(FolderChooser.choose(_:)))
        browse.bezelStyle = .rounded
        browse.frame = NSRect(x: width - 86, y: 33, width: 88, height: 30)
        view.addSubview(browse)
        let hint = makeLabel("Leave empty for a folder under Application Support. ~ and $HOME work.", size: 11, color: .secondaryLabelColor)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.frame = NSRect(x: 64, y: 66, width: width - 64, height: 32)
        view.addSubview(hint)
        pathField = field
        chooser = picker
    }

    // The Choose… button only holds its target weakly.
    return withExtendedLifetime(chooser) { () -> Profile? in
    while true {
        let alert = NSAlert()
        alert.messageText = (selfIndex == nil) ? "New profile" : "Edit profile"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = view
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { showError("Please give the profile a name."); continue }
        if let other = all.enumerated().first(where: { $0.offset != selfIndex && normalize($0.element.name) == normalize(name) }) {
            showError("A profile named \"\(other.element.name)\" already exists.")
            continue
        }
        var path = ""
        if let field = pathField {
            path = field.stringValue.trimmingCharacters(in: .whitespaces)
            if path.isEmpty {
                path = suggestPath(name)
            } else if !expandPath(path).hasPrefix("/") {
                showError("That folder is not valid. Enter a full path, for example ~/ClaudeProfiles/name or /Users/you/ClaudeProfiles/name.")
                continue
            }
        }
        return Profile(name: name, path: path)
    }
    }
}

// ---------- settings ----------

final class SettingsController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var profiles: [Profile]
    let window: NSWindow
    let table = NSTableView()
    let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let defaultButton = NSButton(title: "Make default", target: nil, action: nil)

    init(profiles: [Profile]) {
        self.profiles = profiles
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "ClaudeSwitch — settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        window.contentView = content

        let head = makeLabel("The top profile uses your existing Claude login.", color: .secondaryLabelColor)
        head.frame = NSRect(x: 16, y: 14, width: 480, height: 18)
        content.addSubview(head)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.width = 360
        column.isEditable = false   // a double-click opens the profile dialog instead
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(edit)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 40, width: 370, height: 180))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        content.addSubview(scroll)

        let newButton = NSButton(title: "New…", target: self, action: #selector(add))
        let buttons: [(NSButton, Selector, CGFloat)] = [
            (newButton, #selector(add), 40),
            (editButton, #selector(edit), 74),
            (deleteButton, #selector(remove), 108),
            (defaultButton, #selector(makeDefault), 190),
        ]
        for (button, action, y) in buttons {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 396, y: y, width: 112, height: 30)
            content.addSubview(button)
        }

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.frame = NSRect(x: 396, y: 236, width: 112, height: 30)
        content.addSubview(close)

        updateButtons()
    }

    // Shows the window modally; returns the (possibly changed) profiles.
    func run() -> [Profile] {
        window.center()
        NSApp.runModal(for: window)
        return profiles
    }

    func windowWillClose(_ notification: Notification) { NSApp.stopModal() }
    @objc func closeWindow() { window.close() }

    func numberOfRows(in tableView: NSTableView) -> Int { return profiles.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let extra = (row == 0) ? "★ default — existing Claude login" : profiles[row].path
        return profiles[row].name + "   —   " + extra
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func updateButtons() {
        editButton.isEnabled = table.selectedRow >= 0
        deleteButton.isEnabled = table.selectedRow > 0
        defaultButton.isEnabled = table.selectedRow > 0
    }

    func refresh(select row: Int) {
        Store.saveProfiles(profiles)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateButtons()
    }

    @objc func add() {
        if let p = editProfile(Profile(name: "", path: ""), isDefault: false, all: profiles, selfIndex: nil) {
            profiles.append(p)
            refresh(select: profiles.count - 1)
        }
    }

    @objc func edit() {
        let i = table.selectedRow
        guard i >= 0 else { return }
        if let p = editProfile(profiles[i], isDefault: i == 0, all: profiles, selfIndex: i) {
            profiles[i] = p
            if i == 0 { profiles[0].path = "" }
            refresh(select: i)
        }
    }

    @objc func remove() {
        let i = table.selectedRow
        guard i > 0 else { return }
        guard confirm("Remove the profile \"\(profiles[i].name)\" from the list?\n(The profile folder itself stays on disk.)") else { return }
        profiles.remove(at: i)
        refresh(select: min(i, profiles.count - 1))
    }

    @objc func makeDefault() {
        let i = table.selectedRow
        guard i > 0 else { return }
        var newDefault = profiles[i]
        var oldDefault = profiles[0]
        let oldPath = suggestPath(oldDefault.name)
        guard confirm("\"\(newDefault.name)\" will use the existing Claude login.\n\n" +
                      "\"\(oldDefault.name)\" then gets its own profile folder:\n\(oldPath)\n\n" +
                      "You will sign in there once, the next time you use it.") else { return }
        oldDefault.path = oldPath
        newDefault.path = ""
        profiles[0] = newDefault
        profiles[i] = oldDefault
        refresh(select: 0)
    }
}

// ---------- picker window ----------

// Button grid of the picker. A grid of n columns is margin + n * colPitch wide.
enum Grid {
    static let margin: CGFloat = 20, top: CGFloat = 50
    static let buttonW: CGFloat = 150, buttonH: CGFloat = 70, colPitch: CGFloat = 170, rowPitch: CGFloat = 80
    static let defaultColumns = 3     // up to three profiles on one row, the fourth wraps
    static let minWindowColumns = 2   // never narrower than two columns: the question must fit
}

final class PickerWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

final class PickerController: NSObject, NSWindowDelegate {
    var profiles: [Profile]
    var preferred = Store.columns
    let window: PickerWindow
    let content = FlippedView()
    let question = makeLabel("Which account do you want to start Claude with?")
    let footer = makeLabel("", size: 11, color: colDim)
    let settings = NSButton(title: "settings", target: nil, action: nil)
    var buttons: [NSButton] = []

    init(profiles: [Profile]) {
        self.profiles = profiles
        window = PickerWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 158),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init()
        window.title = "ClaudeSwitch"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = colBg
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentView = content

        question.alignment = .center
        content.addSubview(question)
        content.addSubview(footer)
        settings.isBordered = false
        settings.alignment = .right
        settings.attributedTitle = NSAttributedString(string: "settings", attributes: [
            .foregroundColor: colDim, .font: NSFont.systemFont(ofSize: 11)])
        settings.target = self
        settings.action = #selector(openSettings)
        content.addSubview(settings)

        rebuild()
        window.center()
    }

    // Columns the window is wide: at least minWindowColumns, at most one per profile,
    // and never wider than the screen.
    func clampColumns(_ columns: Int) -> Int {
        var max = Swift.max(Grid.minWindowColumns, profiles.count)
        if let screen = window.screen ?? NSScreen.main {
            let chrome = window.frame.width - window.contentLayoutRect.width
            let fits = Int((screen.visibleFrame.width - chrome - Grid.margin) / Grid.colPitch)
            max = Swift.max(Grid.minWindowColumns, Swift.min(max, fits))
        }
        return Swift.max(Grid.minWindowColumns, Swift.min(columns, max))
    }

    func perRow(_ columns: Int) -> Int { return Swift.max(1, Swift.min(columns, profiles.count)) }

    func contentSize(columns: Int) -> NSSize {
        let rows = (profiles.count + perRow(columns) - 1) / perRow(columns)
        return NSSize(width: Grid.margin + CGFloat(columns) * Grid.colPitch,
                      height: Grid.top + CGFloat(rows) * Grid.rowPitch + 28)
    }

    var currentColumns: Int {
        return clampColumns(Int((content.bounds.width - Grid.margin) / Grid.colPitch + 0.01))
    }

    // While the user drags a side, the width snaps to the nearest whole column and the
    // height follows the rows; dragging the top or bottom changes nothing.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let columns = clampColumns(Int(((proposed.width - Grid.margin) / Grid.colPitch).rounded()))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize(columns: columns))).size
    }

    func windowDidResize(_ notification: Notification) { arrange() }

    // Remember a width the user dragged to.
    func windowDidEndLiveResize(_ notification: Notification) {
        let columns = currentColumns
        if columns != clampColumns(preferred) {
            preferred = columns
            Store.columns = columns
        }
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    // Places the controls for the current width; the grid is centred, so a lone button
    // does not hug the left edge of the (two-column minimum) window.
    func arrange() {
        let width = content.bounds.width
        let n = perRow(currentColumns)
        let rows = (buttons.count + n - 1) / n
        let left = ((width - (CGFloat(n) * Grid.colPitch - (Grid.colPitch - Grid.buttonW))) / 2).rounded()
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: left + CGFloat(i % n) * Grid.colPitch, y: Grid.top + CGFloat(i / n) * Grid.rowPitch,
                                  width: Grid.buttonW, height: Grid.buttonH)
        }
        let footerY = Grid.top + CGFloat(rows) * Grid.rowPitch + 4
        question.frame = NSRect(x: 0, y: 14, width: width, height: 20)
        footer.frame = NSRect(x: Grid.margin, y: footerY + 2, width: width - 2 * Grid.margin - 90, height: 16)
        settings.frame = NSRect(x: width - Grid.margin - 90, y: footerY, width: 90, height: 20)
    }

    func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        for (i, profile) in profiles.enumerated() {
            let button = NSButton(title: profile.name, target: self, action: #selector(launch(_:)))
            button.tag = i
            styleButton(button, back: i == 0 ? colOrange : colSlate, fore: i == 0 ? colBg : colText, size: 18)
            content.addSubview(button)
            buttons.append(button)
        }
        footer.stringValue = "★ " + profiles[0].name + " = your Claude login"
        window.setContentSize(contentSize(columns: clampColumns(preferred)))
        arrange()
    }

    @objc func launch(_ sender: NSButton) {
        do {
            try Launcher.start(profiles[sender.tag])
            window.close()
        } catch let error as LaunchError {
            showError(error.message)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc func openSettings() {
        profiles = SettingsController(profiles: profiles).run()
        rebuild()
    }
}

// ---------- app ----------

final class AppDelegate: NSObject, NSApplicationDelegate {
    var picker: PickerController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        picker = PickerController(profiles: Store.loadProfiles())
        picker.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { return true }

    @objc func openSettings() { picker.openSettings() }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ClaudeSwitch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide ClaudeSwitch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ClaudeSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Needed for cut/copy/paste in the text fields of the profile dialog.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = main
    }
}

// With a profile name as argument ClaudeSwitch launches it directly, without a window:
//   ClaudeSwitch.app/Contents/MacOS/ClaudeSwitch Work
//   open -a ClaudeSwitch --args Work
// Arguments starting with "-" are macOS/Xcode options and ignored.
let app = NSApplication.shared
let profileArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
if let wanted = profileArgs.first {
    let profiles = Store.loadProfiles()
    do {
        guard let match = profiles.first(where: { normalize($0.name) == normalize(wanted) }) else {
            throw LaunchError("Unknown profile: \(wanted) (available: \(profiles.map { $0.name }.joined(separator: ", ")))")
        }
        try Launcher.start(match)
        exit(0)
    } catch {
        let message = (error as? LaunchError)?.message ?? error.localizedDescription
        FileHandle.standardError.write(("ClaudeSwitch: " + message + "\n").data(using: .utf8)!)
        if isatty(STDERR_FILENO) == 0 {
            // Started from a shortcut rather than a terminal: nobody sees stderr.
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            showError(message)
        }
        exit(1)
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
