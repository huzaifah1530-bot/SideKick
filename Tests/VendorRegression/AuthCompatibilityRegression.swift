import Foundation

private enum ProbeError: Error { case rejected, unavailable }
private final class Attempts: @unchecked Sendable { var blobs: [Data?] = [] }

@main struct AuthCompatibilityRegression {
    static func main() async throws {
        precondition(AuthCompatibility.authType(statusType: nil, responseType: nil, statusCode: 409) == "pushedCode")
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
        print("Auth compatibility: pushed-code selection and bounded provisioning recovery passed")
    }
}
