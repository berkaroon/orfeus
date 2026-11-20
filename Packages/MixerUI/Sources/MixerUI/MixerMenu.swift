import AppKit
import MixerModel
import SwiftUI

/// The contents of the mixer's compact status-item popover.
@MainActor
public struct MixerMenu: View {
    private let model: MixerModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Creates the menu around the application's shared model.
    public init(model: MixerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sources.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "speaker.wave.2")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No audio apps are open", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else if model.sources.count > 6 {
                ScrollView {
                    rows.padding(.trailing, 2)
                }
                .frame(height: 310)
            } else {
                rows
            }

            if let issue = model.issue {
                Divider()
                recovery(issue)
            }

            Divider()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label {
                    Text("Quit Orfeus", bundle: .module)
                } icon: {
                    Image(systemName: "power")
                }
            }
            .keyboardShortcut("q", modifiers: .command)
            .buttonStyle(.borderless)
            .accessibilityHint(Text("Closes the mixer and restores normal app volume.", bundle: .module))
        }
        .padding(14)
        .frame(width: 310)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .task { await model.refresh() }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.sources) { source in
                HStack(spacing: 8) {
                    applicationIcon(for: source)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(verbatim: source.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(source.name)
                        .accessibilityHidden(true)
                    Slider(value: Binding(
                        get: { model.volume(for: source) },
                        set: { model.setVolume($0, for: source) }
                    ), in: 0...1) {
                        Text(verbatim: source.name)
                    }
                    .labelsHidden()
                    .frame(width: 132)
                    .accessibilityLabel(Text(verbatim: source.name))
                    .accessibilityValue(Text(model.volume(for: source),
                                             format: .percent.precision(.fractionLength(0))))
                    .accessibilityHint(Text("Adjusts this app’s volume. Zero is muted.", bundle: .module))
                }
            }
        }
    }

    @ViewBuilder
    private func applicationIcon(for source: ActiveSource) -> some View {
        let app = NSRunningApplication(processIdentifier: source.applicationPID)
        if let icon = app?.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else if let url = app?.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
        }
    }

    private func recovery(_ issue: MixerModel.Issue) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            switch issue {
            case .captureUnavailable:
                Text("Audio access is unavailable. Check System Audio Recording in Privacy & Security, then move the slider again.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text("Open System Settings", bundle: .module)
                    }
                    .accessibilityHint(Text("Opens audio recording permissions.", bundle: .module))
                    dismissButton
                }
            case .unsupportedRoute:
                Text("This output device can’t be adjusted separately. The app is playing at its normal volume.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                dismissButton
            }
        }
    }

    private var dismissButton: some View {
        Button {
            model.dismissIssue()
        } label: {
            Text("Dismiss", bundle: .module)
        }
        .buttonStyle(.borderless)
        .accessibilityHint(Text("Closes this notice.", bundle: .module))
    }
}
