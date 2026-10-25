using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace VoxClip.Tests.Support;

internal static class LoopbackTls
{
    internal static X509Certificate2 CreateCertificate()
    {
        using var privateKey = RSA.Create(2048);
        var request = new CertificateRequest("CN=voxclip-loopback", privateKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(1));
        return X509CertificateLoader.LoadPkcs12(certificate.Export(X509ContentType.Pfx), null);
    }
}
