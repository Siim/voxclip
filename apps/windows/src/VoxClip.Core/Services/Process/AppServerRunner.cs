using System.Text;
using System.Text.Json.Nodes;

namespace VoxClip.Core.Services.Process;

internal interface IAppServerRunner
{
    Task<ProcessResult> RunAppServerAsync(ProcessRequest request, CancellationToken ct);
}

public sealed partial class ProcessRunner : IAppServerRunner
{
    async Task<ProcessResult> IAppServerRunner.RunAppServerAsync(ProcessRequest request, CancellationToken ct)
    {
        Validate(request, ct);
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(request.Timeout);
        using var child = OperatingSystem.IsMacOS() ? Child.StartMac(request) : Child.StartManaged(request);
        var errors = ReadAsync(child.Error, request.OutputLimitBytes, _ => { }, deadline.Token);
        var exit = child.WaitAsync();
        var output = new StringBuilder();
        long outputBytes = 0;
        using var reader = new StreamReader(child.Output, Encoding.UTF8, false, 4096, true);
        var commands = (request.StandardInput ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        async Task Send(string command) { await child.Input.WriteAsync(Encoding.UTF8.GetBytes(command + "\n"), deadline.Token).ConfigureAwait(false); await child.Input.FlushAsync(deadline.Token).ConfigureAwait(false); }
        async Task ReadUntil(int id)
        {
            var line = new StringBuilder();
            var character = new char[1];
            while (await reader.ReadAsync(character.AsMemory(), deadline.Token).ConfigureAwait(false) > 0)
            {
                output.Append(character[0]);
                outputBytes += character[0] < 0x80 ? 1 : character[0] < 0x800 ? 2 : char.IsLowSurrogate(character[0]) ? 1 : 3;
                if (outputBytes > request.OutputLimitBytes) throw new IOException("The app-server output limit was exceeded.");
                if (character[0] != '\n') { line.Append(character[0]); continue; }
                JsonNode? parsed;
                try { parsed = JsonNode.Parse(line.ToString()); } catch (System.Text.Json.JsonException) { parsed = null; }
                line.Clear();
                if (parsed?["id"] is JsonValue value && value.TryGetValue<int>(out var received) && received == id) return;
            }
            throw new IOException("The app server stopped before returning a response.");
        }
        async Task HandshakeAsync()
        {
            if (commands.Length != 3) throw new ArgumentException("An app-server handshake needs three messages.", nameof(request));
            await Send(commands[0]).ConfigureAwait(false);
            await ReadUntil(1).ConfigureAwait(false);
            await Send(commands[1]).ConfigureAwait(false);
            await Send(commands[2]).ConfigureAwait(false);
            await ReadUntil(2).ConfigureAwait(false);
        }
        var handshake = HandshakeAsync();
        try
        {
            await handshake.WaitAsync(deadline.Token).ConfigureAwait(false);
            return new(0, output.ToString(), "", stopwatch.Elapsed, false);
        }
        catch (Exception) when (ct.IsCancellationRequested) { throw new OperationCanceledException(ct); }
        catch (Exception) when (deadline.IsCancellationRequested) { throw new TimeoutException("The app server exceeded its time limit."); }
        finally
        {
            await child.StopAsync().ConfigureAwait(false);
            try { await Task.WhenAll(handshake, errors, exit).WaitAsync(TimeSpan.FromMilliseconds(500)).ConfigureAwait(false); } catch (Exception exception) when (exception is IOException or TimeoutException or OperationCanceledException) { }
        }
    }
}
