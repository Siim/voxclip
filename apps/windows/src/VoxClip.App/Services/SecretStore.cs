using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;

namespace VoxClip.App.Services;

internal sealed class SecretStore(string directory, ILog log) : IKeyProvider
{
    private readonly SemaphoreSlim access = new(1, 1);
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("com.voxconvo.voxclip");
    private static readonly HashSet<string> Accounts = ["elevenlabs-api-key", "llm-api-key-anthropic", "llm-api-key-openai", "llm-api-key-xai", "llm-api-key-gemini"];

    public async Task<string?> GetKeyAsync(string account, CancellationToken ct)
    {
        var path = AccountPath(account);
        await access.WaitAsync(ct);
        try
        {
            if (!File.Exists(path)) return null;
            var protectedBytes = await File.ReadAllBytesAsync(path, ct);
            var bytes = Transform(protectedBytes, false);
            try
            {
                var secret = Encoding.UTF8.GetString(bytes);
                log.RegisterSecret(secret);
                return secret;
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { access.Release(); }
    }

    public async Task SaveAsync(string account, string secret, CancellationToken ct)
    {
        var path = AccountPath(account);
        log.RegisterSecret(secret);
        await access.WaitAsync(ct);
        string? temporary = null;
        try
        {
            if (string.IsNullOrWhiteSpace(secret)) { File.Delete(path); return; }
            var bytes = Encoding.UTF8.GetBytes(secret.Trim());
            byte[] encrypted;
            try { encrypted = Transform(bytes, true); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
            Directory.CreateDirectory(directory);
            temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            await File.WriteAllBytesAsync(temporary, encrypted, ct);
            ct.ThrowIfCancellationRequested();
            File.Move(temporary, path, true);
        }
        finally
        {
            if (temporary is not null && File.Exists(temporary)) File.Delete(temporary);
            access.Release();
        }
    }

    private string AccountPath(string account)
    {
        if (!Accounts.Contains(account)) throw new ArgumentException("Unknown VoxClip key account.", nameof(account));
        return Path.Combine(directory, account + ".bin");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob { internal int Length; internal IntPtr Data; }

    private static byte[] Transform(byte[] bytes, bool protect)
    {
        var input = new DataBlob { Length = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) };
        var entropy = new DataBlob { Length = Entropy.Length, Data = Marshal.AllocHGlobal(Entropy.Length) };
        var output = new DataBlob();
        try
        {
            Marshal.Copy(bytes, 0, input.Data, bytes.Length);
            Marshal.Copy(Entropy, 0, entropy.Data, Entropy.Length);
            var success = protect ? CryptProtectData(ref input, null, ref entropy, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, ref entropy, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error());
            var result = new byte[output.Length];
            Marshal.Copy(output.Data, result, 0, result.Length);
            return result;
        }
        finally
        {
            for (var index = 0; index < input.Length; index++) Marshal.WriteByte(input.Data, index, 0);
            Marshal.FreeHGlobal(input.Data);
            Marshal.FreeHGlobal(entropy.Data);
            if (output.Data != IntPtr.Zero)
            {
                for (var index = 0; index < output.Length; index++) Marshal.WriteByte(output.Data, index, 0);
                _ = LocalFree(output.Data);
            }
        }
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string? description, ref DataBlob entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, ref DataBlob entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
