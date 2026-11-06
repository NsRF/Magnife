import MagnifeKit
import SwiftUI

/// Settings > Agents (S-035, docs/ux.md): pick a coding agent, copy the one
/// command or configuration that connects it to this copy's MCP server. The
/// setup block is S-003's: segmented picker, code, note, one copy button.
struct AgentSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let server = model.agentServer
        Section("Coding Agents") {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Let Claude Code, Codex or another coding agent read your traces, spans, logs and findings. It can only read them.")
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = server.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(StatusColors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if server.state != .missing {
                    Picker("Agent", selection: $model.agentClient) {
                        ForEach(AgentClient.allCases) { client in
                            Text(client.title).tag(client)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .frame(maxWidth: .infinity)
                    .gridProbe("agent-picker", area: "agent-setup")
                    EnvironmentCode(text: model.agentSetupText, wraps: true)
                        .gridProbe("agent-code", area: "agent-setup")
                    Text(model.agentClient.note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.copyAgentSetup()
                    } label: {
                        // Both titles hidden underneath keep the width while it reads "Copied".
                        ZStack {
                            Text("Copy Configuration").hidden()
                            Text("Copy Command").hidden()
                            Text(model.agentSetupCopied ? "Copied" : model.agentClient.copyTitle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(model.agentSetupCopied ? "Copied" : model.agentClient.copyTitle)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, Space.xs)
            .gridArea("agent-setup", inset: 0)
            if server.state != .missing {
                Text("Then ask your agent: “What failed in my last request?”")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Help > Connect a Coding Agent… (S-035): Settings, on Agents.
struct ConnectAgentMenuItem: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Connect a Coding Agent…") {
            model.showAgentSettings()
            openSettings()
        }
    }
}
