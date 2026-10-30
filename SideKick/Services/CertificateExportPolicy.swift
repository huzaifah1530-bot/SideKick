import Foundation

enum CertificateExportPolicy {
    enum ExportError: LocalizedError {
        case missingSigner, differentSigner
        var errorDescription: String? {
            switch self {
            case .missingSigner:
                "SideKick cannot verify which certificate signed this LiveContainer installation. Re-sign LiveContainer in SideKick, then import its certificate again."
            case .differentSigner:
                "The saved certificate does not match the one that signed LiveContainer. Re-sign LiveContainer with the certificate you want to use, then import it again. Exporting a different certificate can cause invalid code signatures."
            }
        }
    }

    static func validate(candidate: String, recorded: String?, cachedSigner: String?, profileSerials: [String]) throws {
        let normalize = ImportedCertificateCatalog.normalizedSerial
        // The cached signer is read from the certificate actually used by the pipeline.
        if let recorded, let cachedSigner, normalize(recorded) != normalize(cachedSigner) {
            throw ExportError.differentSigner
        }
        let expected = recorded ?? cachedSigner ?? (profileSerials.count == 1 ? profileSerials.first : nil)
        guard let expected, !expected.isEmpty else { throw ExportError.missingSigner }
        guard normalize(candidate) == normalize(expected) else { throw ExportError.differentSigner }
    }
}
