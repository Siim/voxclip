using System.Text.RegularExpressions;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Pure text redaction boundary; architecture §11.2 and AI §3.2. Does not emit or retain logs.</summary>
public interface IRedactor
{
    /// <summary>Return safe text without persisting or logging the input.</summary>
    string Redact(string message);
}

/// <summary>Pure redaction over an injected secret snapshot and home path; architecture §11.2. Register secrets in the logging service.</summary>
public sealed class Redactor(IEnumerable<string>? secrets = null, string? homeDirectory = null) : IRedactor
{
    private readonly string[] knownSecrets = (secrets ?? []).Where(secret => secret.Length >= 8).Distinct(StringComparer.Ordinal)
        .OrderByDescending(secret => secret.Length).ToArray();
    private static readonly Regex Fields = new("(authorization|x-api-key|xi-api-key|x-goog-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password|secret|token)([\\\"']?\\s*[:=]\\s*[\\\"']?)([^\\s\\\"',&]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Bearer = new(@"Bearer\s+[A-Za-z0-9._~+/=-]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Query = new(@"([?&](?:key|api_key|token|access_token|code|device_code|user_code|signature|sig)=)[^&#\s]*", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Shapes = new(@"sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|sk_[0-9a-f]{32,}|gh[pousr]_[A-Za-z0-9]{36,}", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    /// <summary>Redacts in the normative order; callers must never log the original on failure.</summary>
    public string Redact(string message)
    {
        ArgumentNullException.ThrowIfNull(message);
        try
        {
            foreach (var secret in knownSecrets) message = message.Replace(secret, "[REDACTED]", StringComparison.Ordinal);
            message = Fields.Replace(message, match => match.Groups[1].Value + match.Groups[2].Value +
                (match.Groups[1].Value.Equals("authorization", StringComparison.OrdinalIgnoreCase) &&
                 (match.Groups[3].Value.Equals("Bearer", StringComparison.OrdinalIgnoreCase) || match.Groups[3].Value.Equals("Basic", StringComparison.OrdinalIgnoreCase))
                    ? match.Groups[3].Value : "[REDACTED]"));
            message = Bearer.Replace(message, "Bearer [REDACTED]");
            message = Regex.Replace(message, @"(Authorization[\""']?\s*[:=]\s*[\""']?Basic\s+)[^\s\""',&]+", "$1[REDACTED]", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
            message = Query.Replace(message, "$1[REDACTED]");
            message = Shapes.Replace(message, "[REDACTED]");
            return string.IsNullOrEmpty(homeDirectory) ? message : message.Replace(homeDirectory, "~", StringComparison.Ordinal);
        }
        catch (RegexMatchTimeoutException) { return "[REDACTED]"; }
    }
}
