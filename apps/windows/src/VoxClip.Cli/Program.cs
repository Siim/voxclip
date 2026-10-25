using VoxClip.Cli;
using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, args) => { args.Cancel = true; cancellation.Cancel(); };
return await CliApplication.RunAsync(args, cancellation.Token).ConfigureAwait(false);
