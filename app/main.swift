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

/// True if a DaVinci Resolve app process is running (scripting requires it).
private func isDaVinciResolveRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { app in
        if let bid = app.bundleIdentifier, bid.contains("DaVinciResolve") {
            return true
        }
        return false
    }
}

private func showDaVinciResolveNotRunningAlert() {
    let alert = NSAlert()
    alert.messageText = "DaVinci Resolve is not running"
    alert.informativeText =
        "Please open the DaVinci Resolve app to add to DaVinci."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

// MARK: - ScriptRunner

enum BatchTask {
    case generateProjects
    case addToResolve
}

class ScriptRunner: ObservableObject {
    @Published var isRunning = false
    @Published var log = ""
    /// Which action is running (nil when idle).
    @Published var activeTask: BatchTask?
    /// Live item index/total from `GYROFLOW_BATCH_PROGRESS` (export script or Resolve import).
    @Published var batchItemProgress: (current: Int, total: Int)?

    private var process: Process?
    private var outputPipe: Pipe?
    private var outputLineBuffer = ""

    /// Run `gyroflow_export_projects.sh` (Gyroflow CLI / DNG builder).
    func run(
        projectFolder: String,
        motionFolder: String,
        videoFolder: String,
        lensFolder: String,
        presetFile: String,
        fps: String,
        force: Bool,
        maxOffsetMs: Int
    ) {
        guard !isRunning else { return }

        guard let scriptURL = Bundle.main.url(forResource: "gyroflow_export_projects", withExtension: "sh") else {
            log += "Error: Could not find bundled script.\n"
            return
        }

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
        args += ["--max-offset-ms", String(maxOffsetMs)]
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

        beginRun(task: .generateProjects, proc: proc)
    }

    /// Run `resolve_gyroflow_timeline.py` (DaVinci Resolve Studio must be running).
    func runResolveImport(
        videoFolder: String,
        projectFolder: String,
        resolveProjectName: String,
        resolveTimelineName: String,
        resolveBinName: String,
        resolveScriptApi: String,
        resolveScriptLib: String,
        resolvePythonModulesPath: String
    ) {
        guard !isRunning else { return }

        guard let scriptURL = Bundle.main.url(forResource: "resolve_gyroflow_timeline", withExtension: "py") else {
            log += "Error: Could not find bundled resolve_gyroflow_timeline.py.\n"
            return
        }

        var args = [scriptURL.path, videoFolder, projectFolder]
        let trimmedName = resolveProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            args += ["--project-name", trimmedName]
        }
        let tl = resolveTimelineName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tl.isEmpty {
            args += ["--timeline-name", tl]
        }
        let bn = resolveBinName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bn.isEmpty {
            args += ["--bin-name", bn]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: projectFolder)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPATH
        let api = resolveScriptApi.trimmingCharacters(in: .whitespacesAndNewlines)
        let lib = resolveScriptLib.trimmingCharacters(in: .whitespacesAndNewlines)
        let modulesOverride = resolvePythonModulesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        env["RESOLVE_SCRIPT_API"] = api.isEmpty ? ResolveDefaults.scriptApi : api
        env["RESOLVE_SCRIPT_LIB"] = lib.isEmpty ? ResolveDefaults.scriptLib : lib
        let resolvedApi = env["RESOLVE_SCRIPT_API"]!
        let modules: String
        if modulesOverride.isEmpty {
            modules = "\(resolvedApi)/Modules"
        } else {
            modules = modulesOverride
        }
        if let existing = env["PYTHONPATH"], !existing.isEmpty {
            env["PYTHONPATH"] = "\(modules):\(existing)"
        } else {
            env["PYTHONPATH"] = modules
        }
        proc.environment = env

        beginRun(task: .addToResolve, proc: proc)
    }

    private func beginRun(task: BatchTask, proc: Process) {
        isRunning = true
        activeTask = task
        log = ""
        outputLineBuffer = ""
        batchItemProgress = nil

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.appendScriptOutput(str)
            }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.flushScriptOutputBuffer(flushPartialLine: true)
                self?.isRunning = false
                self?.activeTask = nil
                self?.batchItemProgress = nil
                self?.log += "\n--- Process exited with code \(p.terminationStatus) ---\n"
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            log += "Failed to launch: \(error.localizedDescription)\n"
            isRunning = false
            activeTask = nil
            batchItemProgress = nil
        }
    }

    private static let progressPrefix = "GYROFLOW_BATCH_PROGRESS "

    private func appendScriptOutput(_ chunk: String) {
        outputLineBuffer += chunk
        flushScriptOutputBuffer(flushPartialLine: false)
    }

    /// Consumes full lines from `outputLineBuffer`. When `flushPartialLine` is true, emits the remainder as one line (process end).
    private func flushScriptOutputBuffer(flushPartialLine: Bool) {
        while let newlineRange = outputLineBuffer.range(of: "\n") {
            let line = String(outputLineBuffer[..<newlineRange.lowerBound])
            outputLineBuffer.removeSubrange(..<newlineRange.upperBound)
            emitScriptLine(line)
        }
        if flushPartialLine, !outputLineBuffer.isEmpty {
            emitScriptLine(outputLineBuffer)
            outputLineBuffer = ""
        }
    }

    private func emitScriptLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(Self.progressPrefix) {
            let rest = trimmed.dropFirst(Self.progressPrefix.count)
            let parts = rest.split(separator: " ")
            if parts.count >= 2,
               let cur = Int(parts[0]),
               let tot = Int(parts[1]),
               cur > 0, tot > 0 {
                batchItemProgress = (cur, tot)
            }
            return
        }
        log += line
        log += "\n"
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
    static let maxSyncOffsetMs = "maxSyncOffsetMs"
    static let resolveProjectName = "resolveProjectName"
    static let resolveTimelineName = "resolveTimelineName"
    static let resolveBinName = "resolveBinName"
    /// `RESOLVE_SCRIPT_API` — Developer/Scripting directory
    static let resolveScriptApi = "resolveScriptApi"
    /// Path to `fusionscript.so`
    static let resolveScriptLib = "resolveScriptLib"
    /// Override for `PYTHONPATH` entry (Resolve `Modules` folder). Empty = `resolveScriptApi` + "/Modules"
    static let resolvePythonModulesPath = "resolvePythonModulesPath"
}

private enum ResolveDefaults {
    static let scriptApi =
        "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
    static let scriptLib =
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
}

// MARK: - Local Resolve project discovery

/// Subfolder names under each Resolve user's `Projects` directory (local disk library).
/// Network / PostgreSQL libraries are not scanned; users can still pick "(Currently open project)".
private func discoverLocalResolveProjectNames() -> [String] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let usersRoot = home
        .appendingPathComponent("Library/Application Support/Blackmagic Design/DaVinci Resolve", isDirectory: true)
        .appendingPathComponent("Resolve Project Library/Resolve Projects/Users", isDirectory: true)
    guard let userURLs = try? fm.contentsOfDirectory(
        at: usersRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    var names = Set<String>()
    for userURL in userURLs {
        let projectsDir = userURL.appendingPathComponent("Projects", isDirectory: true)
        guard let projectURLs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            continue
        }
        for projURL in projectURLs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            names.insert(projURL.lastPathComponent)
        }
    }
    return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

// MARK: - Footage & project counts (matches gyroflow_export_projects.sh)

/// Extensions from bundled `video_extensions.txt` (same as the export script).
private func loadVideoExtensions() -> Set<String> {
    let fallback: Set<String> = [
        "mp4", "mov", "avi", "mkv", "mxf", "braw", "r3d", "insv"
    ]
    guard let url = Bundle.main.url(forResource: "video_extensions", withExtension: "txt"),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
        return fallback
    }
    var exts = Set<String>()
    for line in text.components(separatedBy: .newlines) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") || t.isEmpty { continue }
        exts.insert(t.lowercased())
    }
    return exts.isEmpty ? fallback : exts
}

/// True when the directory contains at least one `.dng` at top level (case-insensitive), matching `is_image_sequence_dir` in the shell script.
private func isDngSequenceDirectory(_ dirURL: URL) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
        return false
    }
    guard let entries = try? fm.contentsOfDirectory(
        at: dirURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return false
    }
    return entries.contains { $0.pathExtension.lowercased() == "dng" }
}

/// Counts direct child video files and DNG sequence folders under `videoFolderPath`, using the same rules as `gyroflow_export_projects.sh` (skip a video file whose stem matches a DNG sequence directory name).
private func countVideoFootageItems(videoFolderPath: String, videoExtensions: Set<String>) -> (videos: Int, dngSequences: Int) {
    let fm = FileManager.default
    let trimmed = videoFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return (0, 0) }
    let base = URL(fileURLWithPath: trimmed).standardizedFileURL
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
        return (0, 0)
    }
    guard let entries = try? fm.contentsOfDirectory(
        at: base,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return (0, 0)
    }

    var dngSequenceNames = Set<String>()
    for url in entries {
        var isSubdir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isSubdir), isSubdir.boolValue else {
            continue
        }
        if isDngSequenceDirectory(url) {
            dngSequenceNames.insert(url.lastPathComponent)
        }
    }

    var videoCount = 0
    for url in entries {
        var isSubdir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isSubdir), !isSubdir.boolValue else {
            continue
        }
        let ext = url.pathExtension.lowercased()
        guard videoExtensions.contains(ext) else { continue }
        let stem = url.deletingPathExtension().lastPathComponent
        if dngSequenceNames.contains(stem) { continue }
        videoCount += 1
    }

    return (videoCount, dngSequenceNames.count)
}

/// Counts `.gyroflow` files directly in the project output folder (not in subfolders).
private func countGyroflowProjects(in projectFolderPath: String) -> Int {
    let fm = FileManager.default
    let trimmed = projectFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    let base = URL(fileURLWithPath: trimmed).standardizedFileURL
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
        return 0
    }
    guard let entries = try? fm.contentsOfDirectory(
        at: base,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return 0
    }
    return entries.filter { $0.pathExtension.lowercased() == "gyroflow" }.count
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
    @AppStorage(PrefKeys.maxSyncOffsetMs) private var maxSyncOffsetMs = "5000"
    @AppStorage(PrefKeys.resolveProjectName) private var resolveProjectName = ""
    @AppStorage(PrefKeys.resolveTimelineName) private var resolveTimelineName = "Gyroflow batch"
    @AppStorage(PrefKeys.resolveBinName) private var resolveBinName = ""
    @AppStorage(PrefKeys.resolveScriptApi) private var resolveScriptApi = ResolveDefaults.scriptApi
    @AppStorage(PrefKeys.resolveScriptLib) private var resolveScriptLib = ResolveDefaults.scriptLib
    @AppStorage(PrefKeys.resolvePythonModulesPath) private var resolvePythonModulesPath = ""

    @State private var discoveredResolveProjects: [String] = []

    /// Matches `gyroflow_export_projects.sh` footage discovery (videos + DNG sequence dirs).
    @State private var videoFootageCounts: (videos: Int, dngSequences: Int) = (0, 0)
    /// Top-level `.gyroflow` files in the project output folder.
    @State private var gyroflowProjectCount = 0

    /// Log / output panel: collapsed by default (same pattern as Resolve scripting paths).
    @State private var outputSectionExpanded = false

    /// Saved name (e.g. from prefs) is kept visible even if not found on disk (network DB, moved library).
    private var mergedResolveProjectNames: [String] {
        let saved = resolveProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        var set = Set(discoveredResolveProjects)
        if !saved.isEmpty {
            set.insert(saved)
        }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Generate Gyroflow Projects (step 1)") {
                VStack(alignment: .leading, spacing: 10) {
                    pathRow(label: "Project Output", path: $projectFolder, isDirectory: true)
                    pathRow(label: "Motion (.gcsv)", path: $motionFolder, isDirectory: true)
                    pathRow(label: "Video / DNG", path: $videoFolder, isDirectory: true)
                    pathRow(label: "Lens Profiles", path: $lensFolder, isDirectory: true)
                    pathRow(label: "Preset (.gyroflow)", path: $presetFile, isDirectory: false)

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
                        Text("Maximum offset (ms)")
                            .frame(width: 150, alignment: .trailing)
                        TextField("5000", text: $maxSyncOffsetMs)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("Drop autosync points with |offset| greater than this (project offsets are in ms). Gyroflow search is always 5s. Requires ≥2 points after trim.")
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

            HStack(alignment: .center, spacing: 12) {
                Group {
                    if runner.isRunning, runner.activeTask == .generateProjects {
                        HStack(spacing: 6) {
                            Text("\(videoFootageCounts.videos)")
                                .monospacedDigit()
                            Text("/")
                                .foregroundColor(.secondary)
                            Text("\(videoFootageCounts.dngSequences)")
                                .monospacedDigit()
                            Text("videos / DNG sequences")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("\(videoFootageCounts.videos) videos, \(videoFootageCounts.dngSequences) DNG sequences")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                if runner.isRunning, runner.activeTask == .generateProjects {
                    Text("(\(runner.batchItemProgress?.current ?? 0) out of \(runner.batchItemProgress?.total ?? 0))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)

                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .labelsHidden()

                    Button("Stop") {
                        runner.stop()
                    }
                    .controlSize(.large)
                }

                Button("Generate projects") {
                    startExport()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.large)
                .disabled(runner.isRunning)
            }

            GroupBox("DaVinci Resolve (step 2)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Open DaVinci Resolve Studio with Local scripting enabled, then run “Add projects to DaVinci”.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Resolve project")
                            .frame(width: 200, alignment: .trailing)
                        Picker("", selection: $resolveProjectName) {
                            Text("(Currently open project)").tag("")
                            ForEach(mergedResolveProjectNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320, alignment: .leading)
                        Button("Refresh list") {
                            discoveredResolveProjects = discoverLocalResolveProjectNames()
                        }
                        .help("Re-scan the local Resolve disk library under Application Support.")
                        Spacer(minLength: 0)
                    }
                    Text(
                        "Lists projects in the local Resolve library (Application Support). "
                            + "Network or relocated libraries: choose “(Currently open project)” or open that project in Resolve first."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    HStack {
                        Text("Timeline name")
                            .frame(width: 200, alignment: .trailing)
                        TextField("Gyroflow batch", text: $resolveTimelineName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("Bin name")
                            .frame(width: 200, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("e.g. Gyroflow batch", text: $resolveBinName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 280)
                            Text("Media Pool folder at project root; reuses an existing bin with the same name. Leave empty to import into the root.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: 420, alignment: .leading)
                        }
                    }
                    DisclosureGroup("Resolve scripting paths (advanced)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Override only for non-standard Resolve installs. Leave “Python modules” empty to use Scripting API + “/Modules”.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Text("Scripting API")
                                    .frame(width: 150, alignment: .trailing)
                                TextField(ResolveDefaults.scriptApi, text: $resolveScriptApi)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("fusionscript.so")
                                    .frame(width: 150, alignment: .trailing)
                                TextField(ResolveDefaults.scriptLib, text: $resolveScriptLib)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("Python modules")
                                    .frame(width: 150, alignment: .trailing)
                                TextField("Optional — default …/Scripting/Modules", text: $resolvePythonModulesPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(8)
            }

            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 6) {
                    Text("\(gyroflowProjectCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    Text(".gyroflow projects")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                if runner.isRunning, runner.activeTask == .addToResolve {
                    Button("Stop") {
                        runner.stop()
                    }
                    .controlSize(.large)

                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .labelsHidden()

                    Text("(\(runner.batchItemProgress?.current ?? 0) out of \(runner.batchItemProgress?.total ?? 0))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }

                if !(runner.isRunning && runner.activeTask == .addToResolve) {
                    Button("Add projects to DaVinci") {
                        startResolveImport()
                    }
                    .controlSize(.large)
                    .disabled(runner.isRunning)
                }
            }

            DisclosureGroup("Output", isExpanded: $outputSectionExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
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

                        Spacer()
                    }

                    GroupBox {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(runner.log.isEmpty ? "Ready." : runner.log)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                    // Extra scrollable space below the last line avoids the
                                    // last wrapped row being vertically clipped when the
                                    // scroll view relayouts for text selection (SwiftUI/macOS).
                                    Color.clear
                                        .frame(height: 16)
                                        .id("logBottom")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 8)
                            }
                            .onChange(of: runner.log) {
                                proxy.scrollTo("logBottom", anchor: .bottom)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.top, 4)
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: outputSectionExpanded ? .infinity : nil)
        }
        .padding()
        .frame(minWidth: 700, minHeight: 650, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            discoveredResolveProjects = discoverLocalResolveProjectNames()
            refreshFolderStats()
        }
        .onChange(of: videoFolder) { _, _ in
            refreshFolderStats()
        }
        .onChange(of: projectFolder) { _, _ in
            refreshFolderStats()
        }
        .onChange(of: runner.isRunning) { _, running in
            if !running {
                refreshFolderStats()
            }
        }
    }

    // MARK: - Helpers

    private func refreshFolderStats() {
        let exts = loadVideoExtensions()
        videoFootageCounts = countVideoFootageItems(videoFolderPath: videoFolder, videoExtensions: exts)
        gyroflowProjectCount = countGyroflowProjects(in: projectFolder)
    }

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
        if runner.isRunning { return }

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

        let trimmedMs = maxSyncOffsetMs.trimmingCharacters(in: .whitespacesAndNewlines)
        let msStr = trimmedMs.isEmpty ? "5000" : trimmedMs
        guard let ms = Int(msStr), ms >= 1, ms <= 600_000 else {
            runner.log =
                "Invalid Maximum offset (ms): enter a whole number from 1 to 600000 (default 5000).\n"
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
            maxOffsetMs: ms
        )
    }

    private func startResolveImport() {
        if runner.isRunning { return }

        var errors: [String] = []
        if projectFolder.isEmpty { errors.append("Project Output folder") }
        if videoFolder.isEmpty { errors.append("Video folder") }

        if !errors.isEmpty {
            runner.log = "Add to DaVinci — missing: \(errors.joined(separator: ", "))\n"
            return
        }

        if !isDaVinciResolveRunning() {
            showDaVinciResolveNotRunningAlert()
            return
        }

        runner.runResolveImport(
            videoFolder: videoFolder,
            projectFolder: projectFolder,
            resolveProjectName: resolveProjectName,
            resolveTimelineName: resolveTimelineName,
            resolveBinName: resolveBinName,
            resolveScriptApi: resolveScriptApi,
            resolveScriptLib: resolveScriptLib,
            resolvePythonModulesPath: resolvePythonModulesPath
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
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 800),
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
