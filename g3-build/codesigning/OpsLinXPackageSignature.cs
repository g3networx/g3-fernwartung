using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using System.Text;

internal static class OpsLinXPackageSignature
{
    private const string CodeSigningOid = "1.3.6.1.5.5.7.3.3";
    private const string Sha256Oid = "2.16.840.1.101.3.4.2.1";
    internal const int MaximumSignatureSize = 4096;

    private static X509Certificate2 ReadCertificate(string resource)
    {
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
        using (var data = new MemoryStream())
        {
            if (stream == null) throw new CryptographicException("Missing built-in CA certificate.");
            stream.CopyTo(data);
            return new X509Certificate2(data.ToArray());
        }
    }

    internal static byte[] PackageIdentity(string file, string expectedName)
    {
        if (String.IsNullOrEmpty(expectedName) || expectedName != Path.GetFileName(expectedName) ||
            expectedName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            throw new CryptographicException("Invalid package name.");
        using (var stream = File.OpenRead(file))
        using (var sha = SHA256.Create())
        {
            var digest = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            return Encoding.ASCII.GetBytes("opslinx-release-v1\n" + expectedName + "\n" + digest + "\n");
        }
    }

    internal static void Verify(string file, string expectedName, byte[] signature)
    {
        if (signature == null || signature.Length == 0 || signature.Length > MaximumSignatureSize)
            throw new CryptographicException("Missing or oversized OpsLinX signature.");

        var cms = new SignedCms(new ContentInfo(PackageIdentity(file, expectedName)), true);
        cms.Decode(signature);
        if (!cms.Detached || cms.SignerInfos.Count != 1)
            throw new CryptographicException("Expected one detached OpsLinX signer.");
        var signer = cms.SignerInfos[0];
        var certificate = signer.Certificate;
        if (certificate == null || signer.DigestAlgorithm.Value != Sha256Oid ||
            !certificate.Extensions.OfType<X509EnhancedKeyUsageExtension>().Any(
                extension => extension.EnhancedKeyUsages.Cast<Oid>().Any(oid => oid.Value == CodeSigningOid)))
            throw new CryptographicException("Invalid OpsLinX signing certificate.");
        signer.CheckSignature(true);

        using (var root = ReadCertificate("g3.signing.root"))
        using (var issuer = ReadCertificate("g3.signing.issuer"))
        using (var chain = new X509Chain())
        {
            chain.ChainPolicy.ExtraStore.Add(root);
            chain.ChainPolicy.ExtraStore.Add(issuer);
            chain.ChainPolicy.ApplicationPolicy.Add(new Oid(CodeSigningOid));
            chain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
            // The CA's public revocation policy has not been defined for external devices.
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            chain.ChainPolicy.UrlRetrievalTimeout = TimeSpan.FromSeconds(1);
            if (!chain.Build(certificate) || chain.ChainElements.Count != 3 ||
                !chain.ChainElements[1].Certificate.RawData.SequenceEqual(issuer.RawData) ||
                !chain.ChainElements[2].Certificate.RawData.SequenceEqual(root.RawData) ||
                chain.ChainStatus.Any(status =>
                    (status.Status & ~X509ChainStatusFlags.UntrustedRoot) != X509ChainStatusFlags.NoError))
                throw new CryptographicException("OpsLinX signer does not chain to the built-in CA.");
        }
    }
}
