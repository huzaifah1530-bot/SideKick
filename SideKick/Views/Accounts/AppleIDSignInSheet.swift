import SwiftUI

struct AppleIDSignInSheet: View {
    let onSubmit: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var appleID = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple Account email", text: $appleID)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Apple Account")
                } footer: {
                    Text("Your credentials are saved securely on this device after sign-in.")
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SwiftUI.Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SwiftUI.Button("Continue") {
                        onSubmit(appleID.trimmingCharacters(in: .whitespacesAndNewlines), password)
                        dismiss()
                    }
                    .disabled(appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
