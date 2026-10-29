namespace VoxClip.App.ViewModels;

internal sealed class LocalRuntimeGuard(Func<string, Version?> readVersion)
{
    internal const string Message = "Local transcription needs the latest Microsoft Visual C++ Redistributable.";
    private readonly Lazy<bool> supported = new(() => Supports(readVersion("msvcp140.dll"), readVersion("vcruntime140.dll")));
    internal bool IsSupported => supported.Value;
    internal static bool Supports(Version? standardLibrary, Version? runtime) =>
        standardLibrary is not null && runtime is not null && standardLibrary >= new Version(14, 40) && runtime >= new Version(14, 40);
}
