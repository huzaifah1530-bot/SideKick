"""Narrow source guards for VS-011/012/015; Apple runtime checks need Xcode/device."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1] / "Vendor/SideStore/SideStore"

class SideStoreRegressionGuards(unittest.TestCase):
    def test_ocsp_uses_authenticated_platform_evaluation(self):
        source = (ROOT / "Core/Certificates/OCSPValidator.swift").read_text(encoding="utf-8")
        self.assertNotIn("parseOCSPResponse", source)
        self.assertIn("SecTrustEvaluateWithError", source)
        self.assertIn("kSecRevocationRequirePositiveResponse", source)
        self.assertIn("SecPolicyCreateBasicX509(), revocationPolicy", source)

    def test_ocsp_errors_cannot_become_valid(self):
        source = (ROOT / "Core/Operations/PipelineOperations/VerifyCertificateOperation.swift").read_text(encoding="utf-8")
        fallback = source.split("private func ocspCheck", 1)[1].split("private func fetchInstalledAppInitialState", 1)[0]
        self.assertNotIn("Assuming cross-signed", fallback)
        self.assertIn("throw error", fallback)

    def test_upload_filename_is_not_a_filesystem_path(self):
        source = (ROOT / "Core/tvOS/TVWebFileTransferManager.swift").read_text(encoding="utf-8")
        body = source.split("private func processUploadedBody", 1)[1].split("private func sendHTMLResponse", 1)[0]
        self.assertNotIn("appendingPathComponent(filename)", body)
        self.assertIn("UUID().uuidString", body)
        self.assertIn("options: .withoutOverwriting", body)

    def test_batch_expiration_uses_customized_profile_identity(self):
        source = (ROOT / "Core/Operations/StandaloneOperations/InjectBatchProfilesOperation.swift").read_text(encoding="utf-8")
        self.assertIn("batch.profiles[batch.targetBundleIdentifier]", source)
        self.assertIn("batch.targetBundleIdentifier + extensionSuffix", source)

    def test_https_local_hostname_preserves_tls_identity(self):
        source = (ROOT / "Core/JIT/SideJITManager.swift").read_text(encoding="utf-8")
        self.assertIn('host.hasSuffix(".local"), components.scheme?.lowercased() != "https"', source)

if __name__ == "__main__":
    unittest.main()
