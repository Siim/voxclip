using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace VoxClip.Core.Services.Process;

public sealed partial class ProcessRunner
{
    private static readonly HashSet<string> ProtectedEnvironment = new(StringComparer.OrdinalIgnoreCase)
    {
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"
    };

    private static async Task<ProcessResult> RunCoreAsync(ProcessRequest request, IProgress<ProcessProgress>? progress, CancellationToken ct)
    {
        Validate(request, ct);
        var stopwatch = Stopwatch.StartNew();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(request.Timeout);
        using var child = OperatingSystem.IsMacOS() ? Child.StartMac(request) : Child.StartManaged(request);
        using var drain = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token);
        long stdoutBytes = 0;
        long stderrBytes = 0;
        var output = ReadAsync(child.Output, request.OutputLimitBytes, bytes =>
        {
            Interlocked.Exchange(ref stdoutBytes, bytes);
            progress?.Report(new("Running", bytes, Interlocked.Read(ref stderrBytes)));
        }, drain.Token);
        var error = ReadAsync(child.Error, request.OutputLimitBytes, bytes =>
        {
            Interlocked.Exchange(ref stderrBytes, bytes);
            progress?.Report(new("Running", Interlocked.Read(ref stdoutBytes), bytes));
        }, drain.Token);
        var input = WriteAsync(child.Input, request.StandardInput, deadline.Token);
        var exit = child.WaitAsync();
        try
        {
            await exit.WaitAsync(deadline.Token).ConfigureAwait(false);
            var pipes = Task.WhenAll(output, error, input);
            try { await pipes.WaitAsync(TimeSpan.FromMilliseconds(500), deadline.Token).ConfigureAwait(false); }
            catch (TimeoutException)
            {
                await child.StopAsync().ConfigureAwait(false);
                drain.Cancel();
                try { await pipes.WaitAsync(TimeSpan.FromMilliseconds(500)).ConfigureAwait(false); } catch (OperationCanceledException) { }
            }
            return new(await exit.ConfigureAwait(false), (await output.ConfigureAwait(false)).Text, (await error.ConfigureAwait(false)).Text,
                stopwatch.Elapsed, (await output.ConfigureAwait(false)).Truncated || (await error.ConfigureAwait(false)).Truncated);
        }
        catch
        {
            await child.StopAsync().ConfigureAwait(false);
            try { await Task.WhenAll(output, error, input, exit).WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); } catch (Exception exception) when (exception is IOException or OperationCanceledException or TimeoutException) { }
            if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
            if (deadline.IsCancellationRequested) throw new TimeoutException("The process exceeded its time limit.");
            throw;
        }
    }

    private static void Validate(ProcessRequest request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Path.IsPathFullyQualified(request.Executable)) throw new ArgumentException("The executable must be an absolute path.", nameof(request));
        if (request.OutputLimitBytes <= 0 || request.Timeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(request));
        if (request.Environment?.Keys.Any(ProtectedEnvironment.Contains) == true) throw new ArgumentException("CLI authentication environment must be inherited unchanged.", nameof(request));
        if (OperatingSystem.IsWindows() && !Path.GetExtension(request.Executable).Equals(".exe", StringComparison.OrdinalIgnoreCase))
            throw new IOException("The executable must be a native application.");
    }

    private static async Task WriteAsync(Stream stream, string? input, CancellationToken ct)
    {
        try
        {
            if (input is not null) await stream.WriteAsync(Encoding.UTF8.GetBytes(input), ct).ConfigureAwait(false);
            await stream.FlushAsync(ct).ConfigureAwait(false);
        }
        catch (IOException) { }
        finally { stream.Dispose(); }
    }

    private static async Task<(string Text, bool Truncated)> ReadAsync(Stream stream, int limit, Action<long> progress, CancellationToken ct = default)
    {
        using var saved = new MemoryStream();
        var buffer = new byte[8192];
        long count = 0;
        while (true)
        {
            int received;
            try { received = await stream.ReadAsync(buffer, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            if (received == 0) break;
            var remaining = (int)Math.Max(0, limit - saved.Length);
            if (remaining > 0) saved.Write(buffer, 0, Math.Min(remaining, received));
            count += received;
            progress(count);
        }
        return (Encoding.UTF8.GetString(saved.GetBuffer(), 0, (int)saved.Length), count > limit);
    }

    private sealed class Child(Stream input, Stream output, Stream error, int pid, System.Diagnostics.Process? managed, SafeFileHandle? job) : IDisposable
    {
        private readonly object stopGate = new();
        private Task? stopping;
        internal Stream Input { get; } = input;
        internal Stream Output { get; } = output;
        internal Stream Error { get; } = error;
        internal static Child StartManaged(ProcessRequest request)
        {
            var start = new ProcessStartInfo(request.Executable)
            {
                WorkingDirectory = request.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            foreach (var argument in request.Arguments) start.ArgumentList.Add(argument);
            foreach (var pair in request.Environment ?? new Dictionary<string, string?>())
                if (pair.Value is null) start.Environment.Remove(pair.Key); else start.Environment[pair.Key] = pair.Value;
            var process = new System.Diagnostics.Process { StartInfo = start };
            SafeFileHandle? job = OperatingSystem.IsWindows() ? NativeWindows.CreateJob() : null;
            try
            {
                if (!process.Start()) throw new IOException("Could not start the process.");
                if (job is not null) NativeWindows.AttachJob(job, process.Handle);
                return new(process.StandardInput.BaseStream, process.StandardOutput.BaseStream, process.StandardError.BaseStream, process.Id, process, job);
            }
            catch (Exception exception)
            {
                try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { }
                job?.Dispose(); process.Dispose();
                if (exception is System.ComponentModel.Win32Exception or UnauthorizedAccessException) throw new IOException("Could not start the process.");
                throw;
            }
        }

        internal static Child StartMac(ProcessRequest request)
        {
            var descriptors = new List<int>();
            var actions = Marshal.AllocHGlobal(1024);
            var attributes = Marshal.AllocHGlobal(1024);
            var allocations = new List<IntPtr>();
            var actionsInitialized = false;
            var attributesInitialized = false;
            try
            {
                static void Check(int result) { if (result != 0) throw new IOException("Could not create an isolated process."); }
                Check(NativeMac.posix_spawn_file_actions_init(actions));
                actionsInitialized = true;
                Check(NativeMac.posix_spawnattr_init(attributes));
                attributesInitialized = true;
                int[] Pipe()
                {
                    var ends = new int[2];
                    Check(NativeMac.pipe(ends));
                    descriptors.AddRange(ends);
                    foreach (var descriptor in ends) if (NativeMac.fcntl(descriptor, 2, 1) < 0) throw new IOException("Could not isolate a process pipe.");
                    return ends;
                }
                var input = Pipe(); var output = Pipe(); var error = Pipe();
                Check(NativeMac.posix_spawn_file_actions_adddup2(actions, input[0], 0));
                Check(NativeMac.posix_spawn_file_actions_adddup2(actions, output[1], 1));
                Check(NativeMac.posix_spawn_file_actions_adddup2(actions, error[1], 2));
                foreach (var descriptor in descriptors) Check(NativeMac.posix_spawn_file_actions_addclose(actions, descriptor));
                Check(NativeMac.posix_spawn_file_actions_addchdir_np(actions, request.WorkingDirectory));
                Check(NativeMac.posix_spawnattr_setpgroup(attributes, 0));
                uint signalMask = 0;
                uint signalDefaults = uint.MaxValue;
                Check(NativeMac.posix_spawnattr_setsigmask(attributes, ref signalMask));
                Check(NativeMac.posix_spawnattr_setsigdefault(attributes, ref signalDefaults));
                Check(NativeMac.posix_spawnattr_setflags(attributes, 0x400e));
                IntPtr Strings(IEnumerable<string> strings)
                {
                    var pointers = strings.Select(text => { var pointer = Marshal.StringToCoTaskMemUTF8(text); allocations.Add(pointer); return pointer; }).Append(IntPtr.Zero).ToArray();
                    var array = Marshal.AllocCoTaskMem(pointers.Length * IntPtr.Size); allocations.Add(array);
                    Marshal.Copy(pointers, 0, array, pointers.Length); return array;
                }
                var argv = Strings(new[] { request.Executable }.Concat(request.Arguments));
                var nativeEnvironment = Marshal.ReadIntPtr(NativeMac._NSGetEnviron());
                var environment = nativeEnvironment;
                if (request.Environment is { Count: > 0 } overrides)
                {
                    var inherited = new Dictionary<string, string>(StringComparer.Ordinal);
                    for (var index = 0; ; index++)
                    {
                        var pointer = Marshal.ReadIntPtr(nativeEnvironment, index * IntPtr.Size);
                        if (pointer == IntPtr.Zero) break;
                        var variable = Marshal.PtrToStringUTF8(pointer)!;
                        var separator = variable.IndexOf('=');
                        if (separator >= 0) inherited[variable[..separator]] = variable[(separator + 1)..];
                    }
                    foreach (var pair in overrides) if (pair.Value is null) inherited.Remove(pair.Key); else inherited[pair.Key] = pair.Value;
                    environment = Strings(inherited.Select(pair => pair.Key + "=" + pair.Value));
                }
                Check(NativeMac.posix_spawnp(out var pid, request.Executable, actions, attributes, argv, environment));
                NativeMac.close(input[0]); descriptors.Remove(input[0]);
                NativeMac.close(output[1]); descriptors.Remove(output[1]);
                NativeMac.close(error[1]); descriptors.Remove(error[1]);
                foreach (var descriptor in new[] { output[0], error[0] })
                    if (NativeMac.fcntl(descriptor, 4, NativeMac.fcntl(descriptor, 3, 0) | 4) < 0) throw new IOException("Could not configure a process pipe.");
                var child = new Child(new FileStream(new SafeFileHandle(input[1], true), FileAccess.Write), new MacOutputStream(new SafeFileHandle(output[0], true)),
                    new MacOutputStream(new SafeFileHandle(error[0], true)), pid, null, null);
                descriptors.Clear();
                return child;
            }
            finally
            {
                foreach (var descriptor in descriptors) NativeMac.close(descriptor);
                if (actionsInitialized) NativeMac.posix_spawn_file_actions_destroy(actions);
                if (attributesInitialized) NativeMac.posix_spawnattr_destroy(attributes);
                Marshal.FreeHGlobal(actions); Marshal.FreeHGlobal(attributes);
                foreach (var allocation in allocations) Marshal.FreeCoTaskMem(allocation);
            }
        }

        internal async Task<int> WaitAsync()
        {
            if (managed is not null) { await managed.WaitForExitAsync().ConfigureAwait(false); return managed.ExitCode; }
            while (true)
            {
                var waited = NativeMac.waitpid(pid, out var status, 1);
                if (waited == pid) return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f);
                if (waited < 0) throw new IOException("Could not wait for the process.");
                await Task.Delay(20).ConfigureAwait(false);
            }
        }

        internal Task StopAsync() { lock (stopGate) return stopping ??= StopCoreAsync(); }

        private async Task StopCoreAsync()
        {
            if (managed is not null)
            {
                if (job is not null) job.Dispose();
                else try { managed.Kill(true); } catch (InvalidOperationException) { }
                return;
            }
            NativeMac.kill(-pid, 15);
            var until = Stopwatch.StartNew();
            while (until.Elapsed < TimeSpan.FromSeconds(3) && NativeMac.kill(-pid, 0) == 0) await Task.Delay(50).ConfigureAwait(false);
            NativeMac.kill(-pid, 9);
        }

        public void Dispose() { if (managed is null) NativeMac.kill(-pid, 9); job?.Dispose(); Input.Dispose(); Output.Dispose(); Error.Dispose(); managed?.Dispose(); }
    }

    private sealed class MacOutputStream(SafeFileHandle handle) : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var bytes = new byte[buffer.Length];
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var count = NativeMac.read(handle, bytes, (nuint)bytes.Length);
                if (count >= 0) { bytes.AsMemory(0, (int)count).CopyTo(buffer); return (int)count; }
                var error = Marshal.GetLastPInvokeError();
                if (error is not (4 or 35)) throw new IOException("Could not read a process pipe.");
                await Task.Delay(10, cancellationToken).ConfigureAwait(false);
            }
        }
        public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        protected override void Dispose(bool disposing) { if (disposing) handle.Dispose(); base.Dispose(disposing); }
    }

    private static class NativeMac
    {
        private const string Library = "/usr/lib/libSystem.B.dylib";
        [DllImport(Library)] internal static extern int pipe([Out] int[] descriptors);
        [DllImport(Library)] internal static extern int close(int descriptor);
        internal static int fcntl(int descriptor, int command, int flags) => RuntimeInformation.ProcessArchitecture == Architecture.Arm64
            ? FcntlArm64(descriptor, command, 0, 0, 0, 0, 0, 0, flags) : FcntlX64(descriptor, command, flags);
        [DllImport(Library, EntryPoint = "fcntl")] private static extern int FcntlArm64(int descriptor, int command, nint unused1, nint unused2, nint unused3, nint unused4, nint unused5, nint unused6, int flags);
        [DllImport(Library, EntryPoint = "fcntl")] private static extern int FcntlX64(int descriptor, int command, int flags);
        [DllImport(Library, SetLastError = true)] internal static extern nint read(SafeFileHandle descriptor, [Out] byte[] buffer, nuint count);
        [DllImport(Library)] internal static extern int kill(int pid, int signal);
        [DllImport(Library)] internal static extern int waitpid(int pid, out int status, int options);
        [DllImport(Library)] internal static extern IntPtr _NSGetEnviron();
        [DllImport(Library)] internal static extern int posix_spawn_file_actions_init(IntPtr actions);
        [DllImport(Library)] internal static extern int posix_spawn_file_actions_destroy(IntPtr actions);
        [DllImport(Library)] internal static extern int posix_spawn_file_actions_adddup2(IntPtr actions, int source, int target);
        [DllImport(Library)] internal static extern int posix_spawn_file_actions_addclose(IntPtr actions, int descriptor);
        [DllImport(Library)] internal static extern int posix_spawn_file_actions_addchdir_np(IntPtr actions, [MarshalAs(UnmanagedType.LPUTF8Str)] string directory);
        [DllImport(Library)] internal static extern int posix_spawnattr_init(IntPtr attributes);
        [DllImport(Library)] internal static extern int posix_spawnattr_destroy(IntPtr attributes);
        [DllImport(Library)] internal static extern int posix_spawnattr_setpgroup(IntPtr attributes, int group);
        [DllImport(Library)] internal static extern int posix_spawnattr_setflags(IntPtr attributes, short flags);
        [DllImport(Library)] internal static extern int posix_spawnattr_setsigmask(IntPtr attributes, ref uint signals);
        [DllImport(Library)] internal static extern int posix_spawnattr_setsigdefault(IntPtr attributes, ref uint signals);
        [DllImport(Library)] internal static extern int posix_spawnp(out int pid, [MarshalAs(UnmanagedType.LPUTF8Str)] string executable, IntPtr actions, IntPtr attributes, IntPtr argv, IntPtr environment);
    }

    private static class NativeWindows
    {
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
        {
            internal long ProcessTime, JobTime; internal uint Flags; internal UIntPtr MinimumWorkingSet, MaximumWorkingSet;
            internal uint ActiveProcessLimit; internal UIntPtr Affinity; internal uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters { internal ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits
        {
            internal BasicLimits Basic; internal IoCounters Io; internal UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        internal static SafeFileHandle CreateJob()
        {
            var job = CreateJobObjectW(IntPtr.Zero, null);
            if (job.IsInvalid) { job.Dispose(); throw new IOException("Could not create a process job."); }
            var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 } };
            if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>()))
            { job.Dispose(); throw new IOException("Could not isolate the process job."); }
            return job;
        }
        internal static void AttachJob(SafeFileHandle job, IntPtr process)
        {
            if (!AssignProcessToJobObject(job, process)) throw new IOException("Could not isolate the process job.");
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateJobObjectW(IntPtr security, string? name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(SafeFileHandle job, int informationClass, ref ExtendedLimits limits, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
    }
}
