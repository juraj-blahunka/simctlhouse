import Foundation

/// The `--holder` label used when neither `--holder` nor `SIMCTLHOUSE_HOLDER` gives one.
///
/// Agents often skip `--holder`, which left `list` and `history` with nothing to say who held a device.
/// The default names the agent that ran the command and the directory it ran in, such as `claude in app`.
public enum DefaultHolder {
    /// Shells and wrappers between the agent and simctlhouse, which say nothing about who is asking.
    static let intermediaries: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login", "env", "sudo", "nohup", "timeout", "gtimeout", "time",
        "nice", "script", "xargs", "xcrun", "simctlhouse",
    ]
    /// How far up the process tree to look for the agent.
    static let maximumDepth = 12

    /// The label for a command started by `parent`, in the current directory.
    public static func label(parent: Int32 = getppid(), environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        label(agent: agentName(startingAt: parent, lookup: ProcessTable.entry), directory: currentDirectory(environment: environment))
    }

    /// The label for `simctlhouse run`: also names the command, shortened, such as `claude in app: xcodebuild test -scheme App`.
    public static func label(command: [String], parent: Int32 = getppid(), environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        "\(label(parent: parent, environment: environment)): \(summary(of: command))"
    }

    static let commandLength = 48

    static func summary(of command: [String]) -> String {
        guard let executable = command.first else { return "" }
        let text = ([(executable as NSString).lastPathComponent] + command.dropFirst()).joined(separator: " ")
        return text.count > commandLength ? String(text.prefix(commandLength - 3)) + "..." : text
    }

    /// Names the directory by its last component: `history` shows the full path in its own column, and `list` stays readable.
    static func label(agent: String?, directory: String) -> String {
        let abbreviated = abbreviatingHome(directory)
        let name = abbreviated == "~" || abbreviated == "/" ? abbreviated : (abbreviated as NSString).lastPathComponent
        return agent.map { "\($0) in \(name)" } ?? name
    }

    /// The first process up the tree from `pid` that is not a shell or wrapper, by the name it was started as.
    static func agentName(startingAt pid: Int32, lookup: (Int32) -> ProcessTable.Entry?) -> String? {
        var pid = pid
        for _ in 0..<maximumDepth {
            guard pid > 1, let entry = lookup(pid) else { return nil }
            let name = entry.name.hasPrefix("-") ? String(entry.name.dropFirst()) : entry.name
            if !name.isEmpty, !intermediaries.contains(name) { return name }
            pid = entry.parent
        }
        return nil
    }

    /// `$PWD` when it names the working directory, since it keeps the symlinked path the user typed; the resolved path otherwise.
    static func currentDirectory(environment: [String: String]) -> String {
        let resolved = FileManager.default.currentDirectoryPath
        guard let pwd = environment["PWD"], pwd.hasPrefix("/") else { return resolved }
        var lhs = stat()
        var rhs = stat()
        guard stat(pwd, &lhs) == 0, stat(resolved, &rhs) == 0, lhs.st_dev == rhs.st_dev, lhs.st_ino == rhs.st_ino else { return resolved }
        return pwd
    }

    static func abbreviatingHome(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Reads other processes' parent and the name they were started as.
enum ProcessTable {
    struct Entry: Equatable {
        var parent: Int32
        /// The basename of `argv[0]`. Unlike the kernel's process name, this is the command's name even for binaries
        /// installed under a version number, such as Claude Code's `~/.local/share/claude/versions/2.1.3`.
        var name: String
    }

    static func entry(_ pid: Int32) -> Entry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        let kernelName = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return Entry(parent: parent, name: argv0(of: pid).map { ($0 as NSString).lastPathComponent } ?? kernelName)
    }

    /// Every process below `pid`, found through parent links. Read before killing `pid`: once it is gone,
    /// its children are re-parented to launchd and can no longer be told apart.
    static func descendants(of pid: Int32) -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        // Room for processes started between the two calls.
        size += size / 8
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var children: [Int32: [Int32]] = [:]
        for process in processes.prefix(count) { children[process.kp_eproc.e_ppid, default: []].append(process.kp_proc.p_pid) }
        var found: [Int32] = []
        var queue = children[pid] ?? []
        while let next = queue.popLast() {
            found.append(next)
            queue += children[next] ?? []
        }
        return found
    }

    /// `argv[0]` from `KERN_PROCARGS2`: an argc, the executable path, padding, then the arguments.
    private static func argv0(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(decoding: buffer[start..<index], as: UTF8.self)
    }
}
