extension AppState {
    fileprivate func performSideKickCredentialTransfer() async {
        operationError = nil
        currentOperation = .backup
        progressFraction = 0
        progressText = "Close the app in LiveContainer, then select its active SideKickData folder. Login credentials stay on this phone."
        do {
            guard let request = Bundle.main.object(forInfoDictionaryKey: "SideKickCredentialTransfer") as? [String: Any],
                  let groups = request["sourceGroups"] as? [String],
                  let group = request["group"] as? String,
                  let container = request["container"] as? String,
                  let team = request["team"] as? String,
                  let identity = Bundle.main.bundleIdentifier else { throw AppCredentialTransferError.permissions }
            let url = try await SideKickTransferPicker.chooseFolder(title: "Choose active SideKickData folder")
            guard url.startAccessingSecurityScopedResource() else { throw AppCredentialTransferError.configuration }
            defer { url.stopAccessingSecurityScopedResource() }
            let manifest = try AppDataTransfer.readIdentity(at: url)
            guard manifest.bundleIdentifier == identity,
                  manifest.version == Bundle.main.object(forInfoDictionaryKey: "SideKickSourceVersion") as? String,
                  manifest.build == Bundle.main.object(forInfoDictionaryKey: "SideKickSourceBuild") as? String else {
                throw AppDataTransferError.identityMismatch
            }
            let destination = try AppCredentialDestination.read(folder: url, appID: identity, team: team)
            guard destination == AppCredentialDestination(container: container, group: group) else { throw AppCredentialTransferError.configuration }
            progressText = "Copying and verifying login credentials…"
            // Keep secrets local to this operation; never include them in process errors.
            try AppCredentialTransfer.copy(groups: groups, destination: destination, store: SideKickCredentialStore())
            process(.success(()), errorTitle: "")
        } catch {
            process(.failure(error), errorTitle: "Login transfer did not finish")
        }
    }
}
