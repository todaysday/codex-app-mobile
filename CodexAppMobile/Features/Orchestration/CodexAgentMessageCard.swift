import SwiftUI
import Textual

struct CodexAgentMessageCard: View {
    let item: CodexAgentHistoryItem
    let openThread: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(item.title, systemImage: icon).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let status = item.status {
                    Text(statusTitle(status)).font(.caption).foregroundStyle(statusColor(status))
                }
            }
            if let body = item.body {
                if item.kind == .command {
                    code(body)
                } else if item.kind == .reasoning {
                    DisclosureGroup("Summary") { markdown(body) }
                } else {
                    markdown(body)
                }
            }
            ForEach(item.fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                    Text(field.value).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            ForEach(item.files) { file in
                DisclosureGroup {
                    if let destination = file.destination {
                        Text("Moved to \(destination)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    code(file.diff)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.path).font(.subheadline.monospaced()).lineLimit(3)
                        Text(file.kind).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(item.sections) { section in
                DisclosureGroup(section.title) { code(section.content) }
                    .font(.subheadline)
            }
            ForEach(item.destinations, id: \.self) { destination in
                Button { openThread(destination) } label: {
                    Label("Open agent \(destination)", systemImage: "arrow.turn.down.right")
                        .font(.caption).lineLimit(2)
                }.buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent-item-\(item.id.turnID)-\(item.id.itemID)-\(item.id.occurrence)")
    }

    private func markdown(_ preview: CodexHistoryPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            StructuredText(markdown: preview.text.replacingOccurrences(of: "\r\n", with: "\n"))
                .font(item.kind == .reasoning ? .footnote : .body)
                .textSelection(.enabled)
            truncationNotice(preview)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func code(_ preview: CodexHistoryPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                Text(preview.text.isEmpty ? "No output." : preview.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            truncationNotice(preview)
        }
    }

    @ViewBuilder
    private func truncationNotice(_ preview: CodexHistoryPreview) -> some View {
        if preview.isTruncated {
            Text("Preview truncated after \(CodexHistoryPreview.maximumCharacters.formatted()) characters.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backgroundColor: Color {
        item.kind == .user ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06)
    }

    private var icon: String {
        switch item.kind {
        case .user: return "person.crop.circle"
        case .assistant: return "sparkles"
        case .plan: return "list.bullet.clipboard"
        case .reasoning: return "text.bubble"
        case .command: return "terminal"
        case .fileChange: return "doc.text"
        case .tool: return "wrench.and.screwdriver"
        case .agentAction: return "person.crop.rectangle.stack"
        case .event: return "info.circle"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "failed", "declined": return .red
        case "inProgress": return .orange
        default: return .secondary
        }
    }

    private func statusTitle(_ status: String) -> String {
        switch status {
        case "inProgress": return "In progress"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "declined": return "Declined"
        case "interrupted": return "Interrupted"
        default: return status
        }
    }
}
