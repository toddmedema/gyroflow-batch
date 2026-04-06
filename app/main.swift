import SwiftUI
import AppKit

// MARK: - PATH Resolution

/// GUI apps launched from Finder get a minimal PATH. Resolve the user's full
/// login-shell PATH so child processes can find ffmpeg, python3, etc.
func resolveUserPATH() -> String {
    let fallback = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    guard let shell = ProcessInfo.processInfo.environment["SHELL"] else { return fallback }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: shell)
    proc.arguments = ["-l", "-c", "echo $PATH"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
    } catch {}
    return fallback
}

private let userPATH = resolveUserPATH()

// MARK: - ScriptRunner

class ScriptRunner: ObservableObject {
    @Published var isRunning = false
    @Published var log = ""

    private var process: Process?
    private var outputPipe: Pipe?

    func run(
        projectFolder: String,
        motionFolder: String,
        videoFolder: String,
        lensFolder: String,
        presetFile: String,
        fps: String,
        force: Bool,
        syncSearchMs: Int
    ) {
        guard !isRunning else { return }

        guard let scriptURL = Bundle.main.url(forResource: "gyroflow_export_projects", withExtension: "sh") else {
            log += "Error: Could not find bundled script.\n"
            return
        }

        isRunning = true
        log = ""

        var args = [
            scriptURL.path,
            projectFolder,
            motionFolder,
            videoFolder,
            lensFolder,
            presetFile
        ]
        if !fps.isEmpty {
            args += ["--fps", fps]
        }
        args += ["--sync-search-ms", String(syncSearchMs)]
        if force {
            args.append("--force")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: projectFolder)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPATH
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.outputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.log += str
            }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.log += "\n--- Process exited with code \(p.terminationStatus) ---\n"
            }
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            log += "Failed to launch script: \(error.localizedDescription)\n"
            isRunning = false
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            if let p = self?.process, p.isRunning {
                p.terminate()
            }
        }
    }
}

// MARK: - Persistence Keys

private enum PrefKeys {
    static let projectFolder = "projectFolder"
    static let motionFolder  = "motionFolder"
    static let videoFolder   = "videoFolder"
    static let lensFolder    = "lensFolder"
    static let presetFile    = "presetFile"
    static let fps           = "fps"
    static let forceRegenerate = "forceRegenerate"
    static let syncSearchMs  = "syncSearchMs"
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var runner = ScriptRunner()

    @AppStorage(PrefKeys.projectFolder) private var projectFolder = ""
    @AppStorage(PrefKeys.motionFolder)  private var motionFolder  = ""
    @AppStorage(PrefKeys.videoFolder)   private var videoFolder   = ""
    @AppStorage(PrefKeys.lensFolder)    private var lensFolder    = ""
    @AppStorage(PrefKeys.presetFile)    private var presetFile    = ""
    @AppStorage(PrefKeys.fps)           private var fps           = ""
    @AppStorage(PrefKeys.forceRegenerate) private var forceRegenerate = false
    @AppStorage(PrefKeys.syncSearchMs)  private var syncSearchMs  = "500"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gyroflow Batch Export")
                .font(.title)
                .fontWeight(.semibold)

            GroupBox("Folders & Preset") {
                VStack(spacing: 10) {
                    pathRow(label: "Project Output", path: $projectFolder, isDirectory: true)
                    pathRow(label: "Motion (.gcsv)", path: $motionFolder, isDirectory: true)
                    pathRow(label: "Video / DNG", path: $videoFolder, isDirectory: true)
                    pathRow(label: "Lens Profiles", path: $lensFolder, isDirectory: true)
                    pathRow(label: "Preset (.gyroflow)", path: $presetFile, isDirectory: false)
                }
                .padding(8)
            }

            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("FPS (DNG sequences)")
                            .frame(width: 150, alignment: .trailing)
                        TextField("e.g. 24", text: $fps)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("Leave blank if no DNG sequences")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    HStack {
                        Text("Search size (ms)")
                            .frame(width: 150, alignment: .trailing)
                        TextField("500", text: $syncSearchMs)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("Optical-flow auto-sync search window per sync point")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    HStack {
                        Text("")
                            .frame(width: 150, alignment: .trailing)
                        Toggle("Regenerate existing project files", isOn: $forceRegenerate)
                            .help("Passes --force to the script: removes existing .gyroflow files in the project folder and rebuilds them.")
                        Spacer()
                    }
                }
                .padding(8)
            }

            HStack {
                Button(runner.isRunning ? "Stop" : "Run") {
                    if runner.isRunning {
                        runner.stop()
                    } else {
                        startExport()
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.large)

                if runner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }

                Spacer()

                Button("Copy Log") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(runner.log, forType: .string)
                }
                .disabled(runner.log.isEmpty)

                Button("Clear Log") {
                    runner.log = ""
                }
                .disabled(runner.isRunning)
            }

            GroupBox("Output") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(runner.log.isEmpty ? "Ready." : runner.log)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("logBottom")
                    }
                    .onChange(of: runner.log) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 550)
    }

    // MARK: - Helpers

    private func pathRow(label: String, path: Binding<String>, isDirectory: Bool) -> some View {
        HStack {
            Text(label)
                .frame(width: 150, alignment: .trailing)
            TextField("Select…", text: path)
                .textFieldStyle(.roundedBorder)
                .truncationMode(.middle)
            Button("Browse…") {
                choosePathPanel(title: label, directory: isDirectory) { chosen in
                    path.wrappedValue = chosen
                }
            }
        }
    }

    private func choosePathPanel(title: String, directory: Bool, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select \(title)"
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        if !directory {
            panel.allowedContentTypes = [.json, .data]
        }
        panel.begin { response in
            if response == .OK, let url = panel.url {
                completion(url.path)
            }
        }
    }

    private func startExport() {
        var errors: [String] = []
        if projectFolder.isEmpty { errors.append("Project Output folder") }
        if motionFolder.isEmpty  { errors.append("Motion folder") }
        if videoFolder.isEmpty   { errors.append("Video folder") }
        if lensFolder.isEmpty    { errors.append("Lens Profiles folder") }
        if presetFile.isEmpty    { errors.append("Preset file") }

        if !errors.isEmpty {
            runner.log = "Missing required fields: \(errors.joined(separator: ", "))\n"
            return
        }

        let trimmedMs = syncSearchMs.trimmingCharacters(in: .whitespacesAndNewlines)
        let msStr = trimmedMs.isEmpty ? "500" : trimmedMs
        guard let ms = Int(msStr), ms >= 1, ms <= 600_000 else {
            runner.log =
                "Invalid Search size (ms): enter a whole number from 1 to 600000 (default 500).\n"
            return
        }

        runner.run(
            projectFolder: projectFolder,
            motionFolder: motionFolder,
            videoFolder: videoFolder,
            lensFolder: lensFolder,
            presetFile: presetFile,
            fps: fps,
            force: forceRegenerate,
            syncSearchMs: ms
        )
    }
}

// MARK: - App Delegate & Bootstrap

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    /// Without a main menu, the system never wires **⌘Q** to Quit. A minimal
    /// Application menu with a Quit item restores standard macOS behavior.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let appName =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
        let quitTitle = "Quit \(appName)"
        let quitItem = NSMenuItem(
            title: quitTitle,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        let contentView = ContentView()
        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Gyroflow Batch Export"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
