using System.Globalization;
using System.Runtime.InteropServices;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Pipeline;

internal static unsafe class WindowsAdapterIdentity
{
    internal static EncoderCacheKey Read()
    {
        if (!OperatingSystem.IsWindows()) return new("unknown", "unknown", "");
        nint factory = 0;
        try
        {
            var factoryId = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            Marshal.ThrowExceptionForHR(CreateDXGIFactory1(in factoryId, out factory));
            var table = *(nint**)factory;
            var enumerate = (delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)table[12];
            for (uint index = 0; index < 16; index++)
            {
                nint adapter = 0;
                var result = enumerate(factory, index, &adapter);
                if (result == unchecked((int)0x887A0002)) break;
                Marshal.ThrowExceptionForHR(result);
                try
                {
                    var adapterTable = *(nint**)adapter;
                    var describe = (delegate* unmanaged[Stdcall]<nint, AdapterDescription*, int>)adapterTable[10];
                    var description = new AdapterDescription();
                    Marshal.ThrowExceptionForHR(describe(adapter, &description));
                    if ((description.Flags & 2) != 0) continue;
                    var deviceId = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
                    long driverVersion = 0;
                    var check = (delegate* unmanaged[Stdcall]<nint, Guid*, long*, int>)adapterTable[9];
                    Marshal.ThrowExceptionForHR(check(adapter, &deviceId, &driverVersion));
                    return new(string.Create(CultureInfo.InvariantCulture, $"{description.LuidHigh:X8}{description.LuidLow:X8}"),
                        driverVersion.ToString("X16", CultureInfo.InvariantCulture), "");
                }
                finally { Release(adapter); }
            }
        }
        catch (Exception exception) when (exception is COMException or DllNotFoundException or EntryPointNotFoundException or BadImageFormatException) { }
        finally { Release(factory); }
        return new("unknown", "unknown", "");
    }

    private static void Release(nint value)
    {
        if (value == 0) return;
        var release = (delegate* unmanaged[Stdcall]<nint, uint>)(*(nint**)value)[2];
        release(value);
    }

    [DllImport("dxgi.dll", ExactSpelling = true)]
    private static extern int CreateDXGIFactory1(in Guid interfaceId, out nint factory);

    [StructLayout(LayoutKind.Sequential)]
    private struct AdapterDescription
    {
        internal fixed char Description[128];
        internal uint VendorId;
        internal uint DeviceId;
        internal uint SubsystemId;
        internal uint Revision;
        internal nuint DedicatedVideoMemory;
        internal nuint DedicatedSystemMemory;
        internal nuint SharedSystemMemory;
        internal uint LuidLow;
        internal int LuidHigh;
        internal uint Flags;
    }
}
