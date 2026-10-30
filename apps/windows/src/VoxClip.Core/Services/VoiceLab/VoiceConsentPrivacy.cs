using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace VoxClip.Core.Services.VoiceLab;

internal static class VoiceConsentPrivacy
{
    internal static void CreateDirectory(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            return;
        }
        CreateWindowsDirectory(path);
    }
    internal static void Validate(string path, bool directory)
    {
        if (!OperatingSystem.IsWindows()) return;
        ValidateWindows(path, directory);
    }
    internal static void ProtectNewFile(string path)
    {
        if (OperatingSystem.IsWindows()) ProtectWindowsFile(path);
    }
    [SupportedOSPlatform("windows")]
    private static void ProtectWindowsFile(string path)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var owner = identity.User ?? throw VoiceConsentStore.Invalid();
        var security = new FileSecurity();
        security.SetOwner(owner);
        security.SetAccessRuleProtection(true, false);
        foreach (var principal in new[] { owner, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            security.AddAccessRule(new(principal, FileSystemRights.FullControl, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }
    [SupportedOSPlatform("windows")]
    private static void CreateWindowsDirectory(string path)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var owner = identity.User ?? throw VoiceConsentStore.Invalid();
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        var security = new DirectorySecurity();
        security.SetOwner(owner);
        security.SetAccessRuleProtection(true, false);
        foreach (var principal in new[] { owner, system })
            security.AddAccessRule(new(principal, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).Create(security);
        ValidateWindows(path, true);
    }
    [SupportedOSPlatform("windows")]
    private static void ValidateWindows(string path, bool directory)
    {
        for (var ancestor = new DirectoryInfo(directory ? path : Path.GetDirectoryName(path)!); ancestor is not null; ancestor = ancestor.Parent)
            if (ancestor.Exists && (ancestor.Attributes & FileAttributes.ReparsePoint) != 0) throw VoiceConsentStore.Invalid();
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw VoiceConsentStore.Invalid();
        using var identity = WindowsIdentity.GetCurrent();
        var owner = identity.User ?? throw VoiceConsentStore.Invalid();
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        FileSystemSecurity security = directory ? new DirectoryInfo(path).GetAccessControl() : new FileInfo(path).GetAccessControl();
        if (directory && !security.AreAccessRulesProtected || !owner.Equals(security.GetOwner(typeof(SecurityIdentifier)))) throw VoiceConsentStore.Invalid();
        var hasOwner = false;
        var hasSystem = false;
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow || rule.FileSystemRights != FileSystemRights.FullControl ||
                rule.PropagationFlags != PropagationFlags.None || directory && rule.IsInherited ||
                !rule.IdentityReference.Equals(owner) && !rule.IdentityReference.Equals(system)) throw VoiceConsentStore.Invalid();
            if (rule.IdentityReference.Equals(owner)) hasOwner = true;
            if (rule.IdentityReference.Equals(system)) hasSystem = true;
        }
        if (!hasOwner || !hasSystem) throw VoiceConsentStore.Invalid();
    }
}
