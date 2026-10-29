"""Add accountless certificate signing to pinned vendor sources after shipping patches."""
from pathlib import Path
import sys
root = Path(sys.argv[1])
def edit(relative, old, new):
    path = root / relative
    source = path.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit(f"Expected one integration anchor in {relative}: {old!r}")
    path.write_text(source.replace(old, new), encoding="utf-8")

edit("AltStore/Core/Model/Team.swift", "    public init(_ team: ALTTeam, account: Account, context: NSManagedObjectContext)",
     """    public init(certificateTeam: ALTTeam, context: NSManagedObjectContext) {
        super.init(entity: Team.entity(), insertInto: context)
        self.update(team: certificateTeam)
    }

    public init(_ team: ALTTeam, account: Account, context: NSManagedObjectContext)""")
edit("SideStore/Core/Auth/AuthManager.swift", "    public func getAuthenticatedTeam() async throws -> ALTTeam {",
     """    public func getAuthenticatedTeam() async throws -> ALTTeam {
        if let identity = await StandaloneCertificateSigning.current { return identity.team }""")
edit("SideStore/Core/Operations/PipelineRunner.swift", "        context.isCellularRefreshGroup = group.isCellularRefreshGroup",
     """        if let identity = await StandaloneCertificateSigning.current {
            context.overrideSigningCertificate = identity.certificate
            context.overrideProvisioningProfile = identity.profile
            context.appendTeamID = false
        }
        context.isCellularRefreshGroup = group.isCellularRefreshGroup""")
edit("SideStore/Core/Operations/PipelineOperations/UpdateAppCertificateOperation.swift",
     "        let targetBundleID = self.context.installedApp?.bundleIdentifier ?? self.context.targetBundleIdentifier",
     """        if await StandaloneCertificateSigning.current != nil {
            self.setProgress(100)
            return
        }
        let targetBundleID = self.context.installedApp?.bundleIdentifier ?? self.context.targetBundleIdentifier""")
edit("SideStore/Core/Operations/PipelineOperations/VerifyCertificateOperation.swift",
     "        let team = try await AuthManager.shared.getAuthenticatedTeam()",
     """        if let identity = await StandaloneCertificateSigning.current {
            let certificate = self.willResign ? self.context.targetSigningCertificate?.x509
                : self.context.installedApp.flatMap { CertificateManager.shared.getSigningCertificate(for: $0) }
            guard let certificate else { throw OperationError.invalidParameters("The imported signing certificate is missing.") }
            let result = try await self.ocspCheck(certificate)
            self.context.targetCertStatus = result
            try self.processValidationResult(result, certificate: certificate, allowsCustomCertificateMessage: true,
                description: "Imported signing certificate", appName: self.context.targetBundleIdentifier, team: identity.team)
            self.setProgress(100)
            return
        }
        let team = try await AuthManager.shared.getAuthenticatedTeam()""")
