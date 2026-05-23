import AppKit
import Foundation

extension PortManagerApp {
    func addConflictItems(for processes: [ListeningProcess], to menu: NSMenu) {
        let conflicts = Dictionary(grouping: processes) { $0.port }
            .filter { _, processes in processes.count > 1 }
            .map { port, processes in ProcessGroup(name: "\(port)", processes: processes) }
            .sorted { Int($0.name) ?? 0 < Int($1.name) ?? 0 }

        guard !conflicts.isEmpty else { return }

        let item = NSMenuItem(
            title: "Port Conflicts · \(conflicts.count)",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        for conflict in conflicts {
            submenu.addItem(conflictMenuItem(for: conflict))
        }

        item.submenu = submenu
        menu.addItem(item)
        menu.addItem(.separator())
    }

    func conflictMenuItem(for group: ProcessGroup) -> NSMenuItem {
        let port = group.name
        let item = NSMenuItem(
            title: "\(port) · \(group.processes.count) listeners",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        let heading = NSMenuItem(title: "Conflicting Listeners", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        submenu.addItem(heading)

        for process in group.sortedProcesses {
            submenu.addItem(menuItem(for: process))
        }

        item.submenu = submenu
        return item
    }

    func isIgnored(_ process: ListeningProcess) -> Bool {
        if ignoredPorts.contains(process.port) {
            return true
        }

        let command = process.command.lowercased()
        let prettyCommand = process.prettyCommand.lowercased()
        if ignoredCommands.contains(where: { command.contains($0) || prettyCommand.contains($0) }) {
            return true
        }

        guard let target = process.ignoreTargetKey else {
            return false
        }

        return ignoredTargets.contains { target.contains($0) }
    }

    func addProcessItems(_ processes: [ListeningProcess], to menu: NSMenu) {
        let pinned = pinnedKeys
        let pinnedProcesses = processes.filter { pinned.contains($0.pinKey) }
        let unpinnedProcesses = processes.filter { !pinned.contains($0.pinKey) }
        var addedPinnedSection = false

        if !pinnedProcesses.isEmpty {
            let pinnedHeading = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
            pinnedHeading.isEnabled = false
            menu.addItem(pinnedHeading)
            addPinnedItems(pinnedProcesses, to: menu)
            addedPinnedSection = true
        }

        let dockerProcesses = unpinnedProcesses.filter { $0.container != nil }
        let nonDockerProcesses = unpinnedProcesses.filter { $0.container == nil }
        let staleWorktreeProcesses = nonDockerProcesses.filter { $0.project?.isStaleWorktree == true }
        let orphanProcesses = nonDockerProcesses.filter {
            $0.project?.isOrphan == true && $0.project?.isStaleWorktree != true
        }
        let regularProcesses = nonDockerProcesses.filter { $0.project?.isOrphan != true }
        var addedSpecialGroup = false

        if !dockerProcesses.isEmpty {
            if addedPinnedSection {
                menu.addItem(.separator())
                addedPinnedSection = false
            }

            let group = ProcessGroup(name: "Docker Containers", processes: dockerProcesses)
            menu.addItem(dockerRootMenuItem(for: group))
            addedSpecialGroup = true
        }

        if !staleWorktreeProcesses.isEmpty {
            if addedPinnedSection || addedSpecialGroup {
                menu.addItem(.separator())
                addedPinnedSection = false
            }

            let group = ProcessGroup(name: "Stale Worktrees", processes: staleWorktreeProcesses)
            menu.addItem(groupMenuItem(for: group))
            addedSpecialGroup = true
        }

        if !orphanProcesses.isEmpty {
            if addedPinnedSection || addedSpecialGroup {
                menu.addItem(.separator())
                addedPinnedSection = false
            }

            let group = ProcessGroup(name: "Orphan Processes", processes: orphanProcesses)
            menu.addItem(groupMenuItem(for: group))
            addedSpecialGroup = true
        }

        if addedSpecialGroup && !regularProcesses.isEmpty {
            menu.addItem(.separator())
        }

        if addedPinnedSection && !regularProcesses.isEmpty {
            menu.addItem(.separator())
        }

        let grouped = Dictionary(grouping: regularProcesses) { $0.groupName }
        let projectGroupNames = Set(grouped.compactMap { name, processes in
            processes.count > 1 && processes.contains { $0.project != nil } ? name : nil
        })

        guard regularProcesses.count > 24 else {
            addRegularProcessItems(
                regularProcesses,
                grouped: grouped,
                groupNames: projectGroupNames,
                to: menu
            )

            return
        }

        let groupNames = Set(grouped.compactMap { name, processes in
            processes.count >= 4 ? name : nil
        }).union(projectGroupNames)

        addRegularProcessItems(
            regularProcesses,
            grouped: grouped,
            groupNames: groupNames,
            to: menu
        )
    }

    func addPinnedItems(_ processes: [ListeningProcess], to menu: NSMenu) {
        let grouped = Dictionary(grouping: processes) { $0.pinKey }
        let groups = grouped.values
            .map { ProcessGroup(name: $0.first?.groupName ?? "Pinned", processes: $0) }
            .sorted {
                let left = $0.primaryProcess?.displayName ?? $0.name
                let right = $1.primaryProcess?.displayName ?? $1.name
                return left < right
            }

        for group in groups {
            if group.allDocker, let container = group.dockerContainers.first {
                if group.processes.count == 1, let process = group.processes.first {
                    menu.addItem(menuItem(for: process))
                } else {
                    menu.addItem(dockerContainerMenuItem(for: group, container: container))
                }

                continue
            }

            if group.processes.count > 1 || group.project != nil {
                menu.addItem(projectGroupMenuItem(for: group))
            } else if let process = group.processes.first {
                menu.addItem(menuItem(for: process))
            }
        }
    }

    func addRegularProcessItems(
        _ processes: [ListeningProcess],
        grouped: [String: [ListeningProcess]],
        groupNames: Set<String>,
        to menu: NSMenu
    ) {
        var addedGroups = Set<String>()

        for process in processes {
            let name = process.groupName

            guard groupNames.contains(name) else {
                menu.addItem(menuItem(for: process))
                continue
            }

            if addedGroups.contains(name) {
                continue
            }

            let groupProcesses = (grouped[name] ?? []).sorted {
                if $0.port == $1.port {
                    return ($0.primaryPID ?? 0) < ($1.primaryPID ?? 0)
                }

                return $0.port < $1.port
            }

            let group = ProcessGroup(name: name, processes: groupProcesses)
            menu.addItem(projectGroupMenuItem(for: group))
            addedGroups.insert(name)
        }
    }

    func projectGroupMenuItem(for group: ProcessGroup) -> NSMenuItem {
        guard let primaryProcess = group.primaryProcess else {
            return groupMenuItem(for: group)
        }

        let title = group.processes.count > 1
            ? "\(primaryProcess.displayName) · \(group.processes.count) ports"
            : primaryProcess.displayName

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let openItem = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
        openItem.representedObject = primaryProcess
        openItem.target = self
        submenu.addItem(openItem)

        let copyLocalItem = NSMenuItem(title: "Copy Local URL", action: #selector(copyLocalURL(_:)), keyEquivalent: "")
        copyLocalItem.representedObject = primaryProcess
        copyLocalItem.target = self
        submenu.addItem(copyLocalItem)

        let copyNetworkItem = NSMenuItem(title: "Copy Network URL", action: #selector(copyNetworkURL(_:)), keyEquivalent: "")
        copyNetworkItem.representedObject = primaryProcess
        copyNetworkItem.target = self
        copyNetworkItem.isEnabled = networkAddress != nil
        submenu.addItem(copyNetworkItem)

        if let pinKey = group.pinKey {
            addPinItem(to: submenu, key: pinKey, pinTitle: group.pinTitle, unpinTitle: group.unpinTitle)
        }

        if let target = group.project.map({ ($0.root ?? $0.cwd ?? $0.name).lowercased() }) {
            addIgnoreItem(to: submenu, title: "Ignore Project", kind: "target", value: target)
        }

        submenu.addItem(.separator())

        let killAllItem = NSMenuItem(title: group.killTitle, action: #selector(killProcessGroup(_:)), keyEquivalent: "")
        killAllItem.representedObject = group
        killAllItem.target = self
        submenu.addItem(killAllItem)

        if let project = group.project, let displayPath = project.displayPath {
            submenu.addItem(.separator())

            let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
            projectItem.isEnabled = false
            submenu.addItem(projectItem)

            let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
            pathItem.isEnabled = false
            submenu.addItem(pathItem)

            let copyProjectItem = NSMenuItem(title: "Copy Project Path", action: #selector(copyGroupProjectPath(_:)), keyEquivalent: "")
            copyProjectItem.representedObject = group
            copyProjectItem.target = self
            submenu.addItem(copyProjectItem)

            let revealProjectItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealGroupProject(_:)), keyEquivalent: "")
            revealProjectItem.representedObject = group
            revealProjectItem.target = self
            submenu.addItem(revealProjectItem)

            addProjectLaunchItems(
                to: submenu,
                path: project.root ?? project.cwd ?? displayPath,
                restartTarget: RestartTarget(path: project.root ?? project.cwd ?? displayPath, pids: group.pids)
            )
        }

        let helperProcesses = group.sortedProcesses.filter { $0 != primaryProcess }
        if !helperProcesses.isEmpty {
            submenu.addItem(.separator())

            let portsItem = NSMenuItem(title: "Other Listening Ports", action: nil, keyEquivalent: "")
            portsItem.isEnabled = false
            submenu.addItem(portsItem)

            for process in helperProcesses {
                submenu.addItem(menuItem(for: process))
            }
        }

        item.toolTip = group.project?.displayPath
        item.submenu = submenu
        return item
    }

    func dockerRootMenuItem(for group: ProcessGroup) -> NSMenuItem {
        let containers = group.dockerContainers
        let item = NSMenuItem(
            title: "Docker Containers · \(containers.count) containers · \(group.processes.count) ports",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        let stopAllItem = NSMenuItem(title: "Stop All Containers (\(containers.count))", action: #selector(stopContainerGroup(_:)), keyEquivalent: "")
        stopAllItem.representedObject = group
        stopAllItem.target = self
        submenu.addItem(stopAllItem)

        submenu.addItem(.separator())

        let processesByContainer = Dictionary(grouping: group.sortedProcesses) { process in
            process.container?.id ?? ""
        }

        for container in containers {
            let processes = processesByContainer[container.id] ?? []
            if processes.count == 1, let process = processes.first {
                submenu.addItem(menuItem(for: process))
                continue
            }

            let containerGroup = ProcessGroup(name: container.displayName, processes: processes)
            submenu.addItem(dockerContainerMenuItem(for: containerGroup, container: container))
        }

        item.submenu = submenu
        return item
    }

    func dockerContainerMenuItem(for group: ProcessGroup, container: DockerContainer) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(container.displayName) · \(group.processes.count) ports",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        let stopItem = NSMenuItem(title: "Stop Container (\(container.name))", action: #selector(stopContainerGroup(_:)), keyEquivalent: "")
        stopItem.representedObject = group
        stopItem.target = self
        submenu.addItem(stopItem)

        if let pinKey = group.pinKey {
            addPinItem(to: submenu, key: pinKey, pinTitle: group.pinTitle, unpinTitle: group.unpinTitle)
        }

        addIgnoreItem(
            to: submenu,
            title: "Ignore Container",
            kind: "target",
            value: container.displayName.lowercased()
        )

        submenu.addItem(.separator())

        let dockerItem = NSMenuItem(title: "Docker", action: nil, keyEquivalent: "")
        dockerItem.isEnabled = false
        submenu.addItem(dockerItem)

        let nameItem = NSMenuItem(title: container.name, action: nil, keyEquivalent: "")
        nameItem.isEnabled = false
        submenu.addItem(nameItem)

        let imageItem = NSMenuItem(title: container.image, action: nil, keyEquivalent: "")
        imageItem.isEnabled = false
        submenu.addItem(imageItem)

        if let displayPath = container.displayPath {
            let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
            pathItem.isEnabled = false
            submenu.addItem(pathItem)

            if let path = container.workingDirectory {
                addProjectLaunchItems(to: submenu, path: path, restartTarget: nil)
            }
        }

        submenu.addItem(.separator())

        for process in group.sortedProcesses {
            submenu.addItem(menuItem(for: process))
        }

        item.toolTip = container.displayPath
        item.submenu = submenu
        return item
    }

    func groupMenuItem(for group: ProcessGroup) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(group.name) · \(group.processes.count) ports",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        let killTitle: String
        let killAction: Selector

        if group.allDocker {
            killTitle = "Stop All Containers (\(group.dockerContainers.count))"
            killAction = #selector(stopContainerGroup(_:))
        } else if group.allStaleWorktrees {
            killTitle = "Kill All Stale Worktree Processes (\(group.pids.count) ids)"
            killAction = #selector(killProcessGroup(_:))
        } else if group.allOrphans {
            killTitle = "Kill All Orphan Processes (\(group.pids.count) ids)"
            killAction = #selector(killProcessGroup(_:))
        } else {
            killTitle = group.killTitle
            killAction = #selector(killProcessGroup(_:))
        }

        let killAllItem = NSMenuItem(title: killTitle, action: killAction, keyEquivalent: "")
        killAllItem.representedObject = group
        killAllItem.target = self
        submenu.addItem(killAllItem)

        if group.allStaleWorktrees {
            submenu.addItem(.separator())

            let staleItem = NSMenuItem(title: "Agent worktree project files are missing", action: nil, keyEquivalent: "")
            staleItem.isEnabled = false
            submenu.addItem(staleItem)
        }

        if let pinKey = group.pinKey {
            addPinItem(to: submenu, key: pinKey, pinTitle: group.pinTitle, unpinTitle: group.unpinTitle)
        }

        if group.allOrphans {
            submenu.addItem(.separator())

            let orphanItem = NSMenuItem(title: "Project folders or files are missing", action: nil, keyEquivalent: "")
            orphanItem.isEnabled = false
            submenu.addItem(orphanItem)
        }

        if group.allDocker {
            submenu.addItem(.separator())

            let dockerItem = NSMenuItem(title: "Docker Containers", action: nil, keyEquivalent: "")
            dockerItem.isEnabled = false
            submenu.addItem(dockerItem)

            for container in group.dockerContainers {
                let portText = container.containerPort.map { "\(container.hostPort) -> \($0)" } ?? "\(container.hostPort)"
                let containerItem = NSMenuItem(title: "\(container.name) · \(portText)", action: nil, keyEquivalent: "")
                containerItem.isEnabled = false
                submenu.addItem(containerItem)
            }
        }

        if let project = group.project, let displayPath = project.displayPath {
            submenu.addItem(.separator())

            let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
            projectItem.isEnabled = false
            submenu.addItem(projectItem)

            let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
            pathItem.isEnabled = false
            submenu.addItem(pathItem)

            let copyProjectItem = NSMenuItem(
                title: "Copy Project Path",
                action: #selector(copyGroupProjectPath(_:)),
                keyEquivalent: ""
            )
            copyProjectItem.representedObject = group
            copyProjectItem.target = self
            submenu.addItem(copyProjectItem)

            let revealProjectItem = NSMenuItem(
                title: "Reveal in Finder",
                action: #selector(revealGroupProject(_:)),
                keyEquivalent: ""
            )
            revealProjectItem.representedObject = group
            revealProjectItem.target = self
            submenu.addItem(revealProjectItem)

            addProjectLaunchItems(
                to: submenu,
                path: project.root ?? project.cwd ?? displayPath,
                restartTarget: RestartTarget(path: project.root ?? project.cwd ?? displayPath, pids: group.pids)
            )
        }

        submenu.addItem(.separator())

        for process in group.sortedProcesses {
            submenu.addItem(menuItem(for: process))
        }

        item.toolTip = group.project?.displayPath
        item.submenu = submenu
        return item
    }

    func menuItem(for process: ListeningProcess) -> NSMenuItem {
        let item = NSMenuItem(title: process.displayName, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let openItem = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
        openItem.representedObject = process
        openItem.target = self
        submenu.addItem(openItem)

        let copyLocalItem = NSMenuItem(title: "Copy Local URL", action: #selector(copyLocalURL(_:)), keyEquivalent: "")
        copyLocalItem.representedObject = process
        copyLocalItem.target = self
        submenu.addItem(copyLocalItem)

        let copyNetworkItem = NSMenuItem(title: "Copy Network URL", action: #selector(copyNetworkURL(_:)), keyEquivalent: "")
        copyNetworkItem.representedObject = process
        copyNetworkItem.target = self
        copyNetworkItem.isEnabled = networkAddress != nil
        submenu.addItem(copyNetworkItem)

        addPinItem(
            to: submenu,
            key: process.pinKey,
            pinTitle: process.pinTitle,
            unpinTitle: process.unpinTitle
        )
        addIgnoreItem(to: submenu, title: "Ignore Port", kind: "port", value: "\(process.port)")

        if let target = process.ignoreTargetKey {
            addIgnoreItem(
                to: submenu,
                title: process.container == nil ? "Ignore Project" : "Ignore Container",
                kind: "target",
                value: target
            )
        } else {
            addIgnoreItem(
                to: submenu,
                title: "Ignore App",
                kind: "command",
                value: process.command.lowercased()
            )
        }

        if let container = process.container {
            submenu.addItem(.separator())

            let dockerItem = NSMenuItem(title: "Docker", action: nil, keyEquivalent: "")
            dockerItem.isEnabled = false
            submenu.addItem(dockerItem)

            let nameItem = NSMenuItem(title: container.name, action: nil, keyEquivalent: "")
            nameItem.isEnabled = false
            submenu.addItem(nameItem)

            let imageItem = NSMenuItem(title: container.image, action: nil, keyEquivalent: "")
            imageItem.isEnabled = false
            submenu.addItem(imageItem)

            if let composeProject = container.composeProject, let composeService = container.composeService {
                let composeItem = NSMenuItem(title: "\(composeProject) / \(composeService)", action: nil, keyEquivalent: "")
                composeItem.isEnabled = false
                submenu.addItem(composeItem)
            }

            if let displayPath = container.displayPath {
                let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
                pathItem.isEnabled = false
                submenu.addItem(pathItem)

                let copyPathItem = NSMenuItem(title: "Copy Project Path", action: #selector(copyContainerProjectPath(_:)), keyEquivalent: "")
                copyPathItem.representedObject = process
                copyPathItem.target = self
                submenu.addItem(copyPathItem)

                let revealPathItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealContainerProject(_:)), keyEquivalent: "")
                revealPathItem.representedObject = process
                revealPathItem.target = self
                submenu.addItem(revealPathItem)

                addProjectLaunchItems(to: submenu, path: container.workingDirectory, restartTarget: nil)
            }

            let copyNameItem = NSMenuItem(title: "Copy Container Name", action: #selector(copyContainerName(_:)), keyEquivalent: "")
            copyNameItem.representedObject = process
            copyNameItem.target = self
            submenu.addItem(copyNameItem)
        }

        if let project = process.project, let displayPath = project.displayPath {
            submenu.addItem(.separator())

            let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
            projectItem.isEnabled = false
            submenu.addItem(projectItem)

            let pathItem = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
            pathItem.isEnabled = false
            submenu.addItem(pathItem)

            let copyProjectItem = NSMenuItem(
                title: "Copy Project Path",
                action: #selector(copyProjectPath(_:)),
                keyEquivalent: ""
            )
            copyProjectItem.representedObject = process
            copyProjectItem.target = self
            submenu.addItem(copyProjectItem)

            let revealProjectItem = NSMenuItem(
                title: "Reveal in Finder",
                action: #selector(revealProject(_:)),
                keyEquivalent: ""
            )
            revealProjectItem.representedObject = process
            revealProjectItem.target = self
            submenu.addItem(revealProjectItem)

            addProjectLaunchItems(
                to: submenu,
                path: project.root ?? project.cwd ?? displayPath,
                restartTarget: RestartTarget(path: project.root ?? project.cwd ?? displayPath, pids: process.pids)
            )
        }

        submenu.addItem(.separator())

        let killAction: Selector = process.container == nil ? #selector(killProcess(_:)) : #selector(stopContainer(_:))
        let killItem = NSMenuItem(title: process.killTitle, action: killAction, keyEquivalent: "")
        killItem.representedObject = process
        killItem.target = self
        submenu.addItem(killItem)

        item.toolTip = process.project?.displayPath
        item.submenu = submenu
        return item
    }

    func addProjectLaunchItems(to menu: NSMenu, path: String?, restartTarget: RestartTarget?) {
        guard let path, !path.isEmpty else { return }

        let ghosttyItem = NSMenuItem(title: "Open in Ghostty", action: #selector(openInGhostty(_:)), keyEquivalent: "")
        ghosttyItem.representedObject = path
        ghosttyItem.target = self
        menu.addItem(ghosttyItem)

        let codeItem = NSMenuItem(title: "Open in VS Code", action: #selector(openInVSCode(_:)), keyEquivalent: "")
        codeItem.representedObject = path
        codeItem.target = self
        menu.addItem(codeItem)

        if let restartTarget, devCommand(for: path) != nil {
            let restartItem = NSMenuItem(title: "Restart Dev Server", action: #selector(restartDevServer(_:)), keyEquivalent: "")
            restartItem.representedObject = restartTarget
            restartItem.target = self
            menu.addItem(restartItem)
        }
    }

    func addPinItem(to menu: NSMenu, key: String, pinTitle: String, unpinTitle: String) {
        let isPinned = pinnedKeys.contains(key)
        let item = NSMenuItem(
            title: isPinned ? unpinTitle : pinTitle,
            action: isPinned ? #selector(unpinItem(_:)) : #selector(pinItem(_:)),
            keyEquivalent: ""
        )
        item.representedObject = key
        item.target = self
        menu.addItem(item)
    }

    func addIgnoreItem(to menu: NSMenu, title: String, kind: String, value: String) {
        let item = NSMenuItem(title: title, action: #selector(ignoreItem(_:)), keyEquivalent: "")
        item.representedObject = "\(kind):\(value)"
        item.target = self
        menu.addItem(item)
    }
}
