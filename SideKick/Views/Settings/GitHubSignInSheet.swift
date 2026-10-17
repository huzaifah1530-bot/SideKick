import SwiftUI
import UIKit

/// Device-flow sign-in: show a short code, open GitHub in Safari, wait for approval.
struct GitHubSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: GitHubAccountSession.DeviceCode?
    @State private var errorMessage: String?
    @State private var signedInAs: String?
    @State private var didCopy = false
    @State private var attempt = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.l) {
                    StatusSymbol(systemImage: signedInAs == nil ? "person.crop.circle.badge.checkmark" : "checkmark",
                                 tone: signedInAs == nil ? .accent : .success)
                    if let signedInAs {
                        Text(signedInAs.isEmpty ? "Signed In" : "Signed in as @\(signedInAs)")
                            .font(.title2.weight(.bold))
                        if let installURL = GitHubAppConfiguration.installURL {
                            Text("To use private repositories, choose which ones SideKick can read.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Link(destination: installURL) { Label("Choose Private Repositories", systemImage: "lock.open") }
                                .font(.body.weight(.semibold))
                        }
                    } else if let code {
                        Text("Enter this code on GitHub")
                            .font(.title2.weight(.bold))
                        Text(code.userCode)
                            .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                            .kerning(4)
                            .textSelection(.enabled)
                            .accessibilityLabel("Code \(code.userCode.map(String.init).joined(separator: " "))")
                        SwiftUI.Button {
                            UIPasteboard.general.string = code.userCode
                            didCopy = true
                        } label: {
                            Label(didCopy ? "Copied" : "Copy Code", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .font(.subheadline.weight(.semibold))
                        HStack(spacing: Spacing.xs) {
                            ProgressView()
                            Text("Waiting for you to approve on GitHub…").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    } else if let errorMessage {
                        Text("Couldn’t Sign In").font(.title2.weight(.bold))
                        Text(errorMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        ProgressView("Contacting GitHub…")
                    }
                    Text("SideKick asks only for read access. Your password never passes through SideKick.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: SideKickLayout.readableWidth)
                .padding(Spacing.l)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                BottomActionBar {
                    if signedInAs != nil {
                        SwiftUI.Button { dismiss() } label: { ActionLabel("Done") }.primaryActionStyle()
                    } else if let code {
                        SwiftUI.Button {
                            UIPasteboard.general.string = code.userCode
                            openURL(code.verificationURL)
                        } label: { ActionLabel("Copy Code & Open GitHub", systemImage: "safari") }
                        .primaryActionStyle()
                    } else if errorMessage != nil {
                        SwiftUI.Button { attempt = UUID() } label: { ActionLabel("Try Again") }.primaryActionStyle()
                    }
                }
            }
            .navigationTitle("Sign in with GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SwiftUI.Button("Cancel") { dismiss() } }
            }
            .task(id: attempt) { await signIn() }
        }
        .interactiveDismissDisabled(code != nil && signedInAs == nil)
    }

    @MainActor private func signIn() async {
        code = nil; errorMessage = nil; didCopy = false
        do {
            let deviceCode = try await GitHubAccountSession.requestCode()
            code = deviceCode
            signedInAs = try await GitHubAccountSession.completeSignIn(deviceCode)
            code = nil
        } catch is CancellationError {
        } catch {
            code = nil
            errorMessage = error.localizedDescription
        }
    }
}
