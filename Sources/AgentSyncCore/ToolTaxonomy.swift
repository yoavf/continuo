import Foundation

/// Cross-agent tool vocabulary: both providers' tool names map to a small set
/// of universal operations, and renderers emit the target's native name so
/// transplanted history reads naturally to the resumed model. Unknown tools
/// keep their original name — they're history, not executable calls.
enum ToolTaxonomy {
    static func universalOperation(provider: AgentKind, toolName: String) -> String? {
        switch provider {
        case .claude:
            switch toolName {
            case "Bash", "BashOutput", "KillShell":
                return "shell.exec"
            case "Read", "NotebookRead":
                return "file.read"
            case "Write":
                return "file.write"
            case "Edit", "MultiEdit", "NotebookEdit":
                return "file.edit"
            case "Glob":
                return "file.glob"
            case "Grep":
                return "search.content"
            case "WebSearch":
                return "web.search"
            case "WebFetch":
                return "web.fetch"
            case "Task", "Agent":
                return "agent.spawn"
            case "TodoWrite", "TaskCreate", "TaskUpdate":
                return "plan.update"
            default:
                return nil
            }
        case .codex:
            switch toolName {
            case "shell", "exec_command", "local_shell", "container.exec":
                return "shell.exec"
            case "apply_patch":
                return "file.edit"
            case "read_file", "view_image":
                return "file.read"
            case "web_search":
                return "web.search"
            case "update_plan":
                return "plan.update"
            default:
                return nil
            }
        case .opencode:
            switch toolName {
            case "bash":
                return "shell.exec"
            case "read":
                return "file.read"
            case "write":
                return "file.write"
            case "edit", "patch":
                return "file.edit"
            case "glob", "list":
                return "file.glob"
            case "grep":
                return "search.content"
            case "websearch":
                return "web.search"
            case "webfetch":
                return "web.fetch"
            case "task":
                return "agent.spawn"
            case "todowrite", "todoread":
                return "plan.update"
            default:
                return nil
            }
        }
    }

    static func nativeToolName(operation: String, provider: AgentKind) -> String? {
        switch provider {
        case .claude:
            switch operation {
            case "shell.exec":
                return "Bash"
            case "file.read":
                return "Read"
            case "file.write":
                return "Write"
            case "file.edit":
                return "Edit"
            case "file.glob":
                return "Glob"
            case "search.content":
                return "Grep"
            case "web.search":
                return "WebSearch"
            case "web.fetch":
                return "WebFetch"
            case "agent.spawn":
                return "Task"
            case "plan.update":
                return "TodoWrite"
            default:
                return nil
            }
        case .codex:
            switch operation {
            case "shell.exec":
                return "exec_command"
            case "file.edit", "file.write":
                return "apply_patch"
            case "plan.update":
                return "update_plan"
            case "web.search":
                return "web_search"
            default:
                return nil
            }
        case .opencode:
            switch operation {
            case "shell.exec":
                return "bash"
            case "file.read":
                return "read"
            case "file.write":
                return "write"
            case "file.edit":
                return "edit"
            case "file.glob":
                return "glob"
            case "search.content":
                return "grep"
            case "web.search":
                return "websearch"
            case "web.fetch":
                return "webfetch"
            case "agent.spawn":
                return "task"
            case "plan.update":
                return "todowrite"
            default:
                return nil
            }
        }
    }

    /// The name a renderer should emit for a tool event: the target's native
    /// tool when the operation translates, the original name otherwise.
    static func renderedToolName(for event: CanonicalEvent, target: AgentKind) -> String {
        let original = event.metadata.string("tool_name") ?? "tool"
        let operation = event.metadata.string("tool_op")
            ?? universalOperation(provider: event.sourceProvider, toolName: original)
        guard let operation, let mapped = nativeToolName(operation: operation, provider: target) else {
            return original
        }
        return mapped
    }
}
