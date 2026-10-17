import SwiftUI

struct AppleIDSignInSheet: View {
    let onSubmit: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var appleID = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    private var trimmedAppleID: String { appleID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedAppleID.isEmpty && !password.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: Spacing.s) {
                        StatusSymbol(systemImage: "person.crop.circle.fill", tone: .accent)
                        Text("Sign in with the Apple Account you use to sign apps.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Email", text: $appleID)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                } footer: {
                    Text("Your password is stored in the iOS Keychain on this iPhone.")
                }
            }
            .navigationTitle("Add Apple Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SwiftUI.Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SwiftUI.Button("Sign In", action: submit)
                        .fontWeight(.semibold)
                        .disabled(!canSubmit)
                }
            }
            .onAppear { focusedField = .email }
        }
        .presentationDetents([.large])
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(trimmedAppleID, password)
        dismiss()
    }
}
