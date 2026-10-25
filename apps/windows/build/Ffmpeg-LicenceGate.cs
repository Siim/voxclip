using System.Runtime.InteropServices;
using System.Text.Json;

internal static class FfmpegLicenceGate
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr ReadText();

    private static int Main(string[] arguments)
    {
        if (arguments.Length != 1) return 2;
        var library = NativeLibrary.Load(Path.GetFullPath(arguments[0]));
        try
        {
            var configurationReader = Marshal.GetDelegateForFunctionPointer<ReadText>(NativeLibrary.GetExport(library, "avcodec_configuration"));
            var licenceReader = Marshal.GetDelegateForFunctionPointer<ReadText>(NativeLibrary.GetExport(library, "avcodec_license"));
            var configuration = Marshal.PtrToStringUTF8(configurationReader()) ?? "";
            var licence = Marshal.PtrToStringUTF8(licenceReader()) ?? "";
            Console.WriteLine(JsonSerializer.Serialize(new { configuration, licence }));
            return configuration.Contains("--enable-gpl", StringComparison.OrdinalIgnoreCase)
                || configuration.Contains("--enable-nonfree", StringComparison.OrdinalIgnoreCase)
                || !configuration.Contains("--enable-shared", StringComparison.Ordinal)
                || !licence.Contains("LGPL", StringComparison.OrdinalIgnoreCase) ? 1 : 0;
        }
        finally
        {
            NativeLibrary.Free(library);
        }
    }
}
