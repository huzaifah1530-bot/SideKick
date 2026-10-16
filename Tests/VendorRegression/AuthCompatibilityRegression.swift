import Foundation

private enum ProbeError: Error { case rejected, unavailable }
private final class Attempts: @unchecked Sendable { var blobs: [Data?] = [] }
private final class ResyncAttempts { var sends: [String] = []; var syncs = 0 }

@main struct AuthCompatibilityRegression {
    static func main() async throws {
        let identifier = Array(UInt8(0)...UInt8(15))
        let encodedIdentifier = AuthCompatibility.remoteIdentifier(identifier)
        precondition(encodedIdentifier == "AAECAwQFBgcICQoLDA0ODw==")
        precondition(Data(base64Encoded: encodedIdentifier) == Data(identifier))
        let challenge = Data([1, 2, 3])
        let challengeStatus: [String: any Sendable] = ["ec": -22421, "hsc": 434, "X-Apple-I-MD-DATA": challenge]
        precondition(AuthCompatibility.resyncPayload(status: challengeStatus) == challenge)
        precondition(AuthCompatibility.resyncPayload(status: ["ec": -22421, "hsc": 434, "X-Apple-I-MD-DATA": "AQID"]) == challenge)
        for status in [
            ["ec": -22421, "hsc": 434],
            ["ec": -22421, "hsc": 434, "X-Apple-I-MD-DATA": "invalid"],
            ["ec": -22421, "hsc": 434, "X-Apple-I-MD-DATA": Data()],
            ["ec": -90010, "hsc": 200, "X-Apple-I-MD-DATA": challenge],
            ["ec": -22406, "hsc": 434, "X-Apple-I-MD-DATA": challenge]
        ] as [[String: any Sendable]] {
            precondition(AuthCompatibility.resyncPayload(status: status) == nil)
            do {
                try responsePolicy(status: status, dictionary: ["Status": status], requestParameters: ["o": "init"], allowAnisetteResync: true)
                preconditionFailure("Invalid challenges and unrelated errors must still fail")
            } catch { }
        }
        let wire = AuthCompatibility.resyncRequest(identifier: identifier, adiBlob: Data([4]), deviceID: "device", localUserID: "local", challenge: challenge)
        precondition(wire == ["identifier": encodedIdentifier, "adi_pb": "BA==", "sim": "AQID", "device_id": "device", "md_lu": "local"])
        // Exercise the production gate together with the real bounded orchestration.
        let recovery = ResyncAttempts()
        let recovered = try await AuthCompatibility.withResynchronization(initial: "old", request: { state, allow in
            recovery.sends.append(state)
            let status: [String: any Sendable] = state == "old" ? challengeStatus : ["ec": 0]
            return try responsePolicy(status: status, dictionary: ["Status": status], requestParameters: ["o": "init", "A2k": Data([9])], allowAnisetteResync: allow)
        }, resynchronize: { state, payload in
            precondition(state == "old" && payload == challenge)
            recovery.syncs += 1
            return "fresh"
        })
        precondition(recovered.data == "fresh" && recovery.sends == ["old", "fresh"] && recovery.syncs == 1)
        let repeated = ResyncAttempts()
        do {
            _ = try await AuthCompatibility.withResynchronization(initial: "old", request: { state, allow in
                repeated.sends.append(state)
                return try responsePolicy(status: challengeStatus, dictionary: ["Status": challengeStatus], requestParameters: ["o": "init"], allowAnisetteResync: allow)
            }, resynchronize: { _, _ in repeated.syncs += 1; return "fresh" })
            preconditionFailure("A repeated challenge must fail, not loop")
        } catch { }
        precondition(repeated.sends == ["old", "fresh"] && repeated.syncs == 1)
        let failed = ResyncAttempts()
        do {
            _ = try await AuthCompatibility.withResynchronization(initial: "old", request: { state, allow in
                failed.sends.append(state)
                return try responsePolicy(status: challengeStatus, dictionary: ["Status": challengeStatus], requestParameters: ["o": "init"], allowAnisetteResync: allow)
            }, resynchronize: { _, _ in failed.syncs += 1; throw ProbeError.unavailable })
            preconditionFailure("A failed resync must not retry Apple")
        } catch ProbeError.unavailable { }
        precondition(failed.sends == ["old"] && failed.syncs == 1)
        for operation in ["init", "complete", "apptokens"] {
            do {
                try responsePolicy(status: challengeStatus, dictionary: ["Status": challengeStatus], requestParameters: ["o": operation], allowAnisetteResync: operation != "init")
                preconditionFailure("No callback, or any later-stage challenge, must retain the Apple error")
            } catch { }
        }
        precondition(AuthCompatibility.authType(statusType: nil, responseType: nil, statusCode: 409) == "pushedCode")
        precondition(AuthCompatibility.authType(statusType: "", responseType: nil, statusCode: 409) == "pushedCode")
        precondition(AuthCompatibility.authType(statusType: "", responseType: "sms", statusCode: 409) == "sms")
        precondition(AuthCompatibility.authType(statusType: "repair", responseType: nil, statusCode: 409) == "repair")
        precondition(AuthCompatibility.authType(statusType: nil, responseType: "sms", statusCode: 409) == "sms")
        precondition(AuthCompatibility.authType(statusType: nil, responseType: nil, statusCode: 200) == nil)
        let proof: [String: any Sendable] = ["spd": Data([1]), "M2": Data([2])]
        try responsePolicy(status: ["ec": 0, "hsc": 409], dictionary: proof, requestParameters: ["o": "complete"])
        for code in [-99999, -22406, -20101, -20209, -21669, -20102, -21668, -22411, -80045] {
            do {
                try responsePolicy(status: ["ec": code, "hsc": 409], dictionary: proof, requestParameters: ["o": "complete"])
                preconditionFailure("Every nonzero authentication error must escape, even with challenge status and proof")
            } catch { }
        }
        for operation in ["init", "apptokens"] {
            do {
                try responsePolicy(status: ["ec": -99999, "hsc": 409], dictionary: proof, requestParameters: ["o": operation])
                preconditionFailure("Only complete challenges may continue")
            } catch { }
        }
        do {
            try responsePolicy(status: ["ec": -99999, "hsc": 409], dictionary: [:], requestParameters: ["o": "complete"])
            preconditionFailure("Missing proof must fail")
        } catch { }
        do {
            try responsePolicy(status: ["ec": -99999, "hsc": 200], dictionary: proof, requestParameters: ["o": "complete"])
            preconditionFailure("Non-challenge errors must fail")
        } catch { }
        let attempts = Attempts()
        let blob = Data([1])
        let value: Int = try await AuthCompatibility.withProvisioningRecovery(existingBlob: blob, isRemote: true, isProvisioningError: { if case ProbeError.rejected = $0 { return true }; return false }) { candidate in
            attempts.blobs.append(candidate)
            if candidate != nil { throw ProbeError.rejected }
            return 42
        }
        precondition(value == 42 && attempts.blobs == [blob, nil])
        for remote in [true, false] {
            let failed = Attempts()
            do {
                let _: Int = try await AuthCompatibility.withProvisioningRecovery(existingBlob: blob, isRemote: remote, isProvisioningError: { _ in true }) { candidate in
                    failed.blobs.append(candidate)
                    throw ProbeError.rejected
                }
                preconditionFailure("Repeated provisioning rejection must escape")
            } catch ProbeError.rejected { }
            precondition(failed.blobs.count == (remote ? 2 : 1))
        }
        let unavailable = Attempts()
        do {
            let _: Int = try await AuthCompatibility.withProvisioningRecovery(existingBlob: blob, isRemote: true, isProvisioningError: { _ in false }) { candidate in
                unavailable.blobs.append(candidate)
                throw ProbeError.unavailable
            }
            preconditionFailure("Unrelated errors must escape")
        } catch ProbeError.unavailable { }
        precondition(unavailable.blobs.count == 1)
        print("Auth compatibility: pushed-code selection, bounded resynchronization and provisioning recovery passed")
    }
}
