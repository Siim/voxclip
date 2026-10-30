param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$EvidenceDir,
    [ValidateSet('win-x64','win-arm64')][string]$RuntimeIdentifier='win-arm64')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Root).Path
New-Item -ItemType Directory -Path $EvidenceDir | Out-Null
$evidence = (Resolve-Path -LiteralPath $EvidenceDir).Path
$result = Join-Path $evidence 'transcript-frame-time.json'
$ready = Join-Path $evidence 'transcript-frame-ready.txt'
$start = Join-Path $evidence 'transcript-frame-start.txt'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$env:VOXCLIP_DATA_DIR = Join-Path $evidence 'data'
$env:VOXCLIP_SHARED_DIR = Join-Path $root 'shared'
$env:VOXCLIP_LIVE_TESTS = '0'
$env:VOXCLIP_TEST_DOWNLOAD = '0'
$platform = if ($RuntimeIdentifier -eq 'win-arm64') { 'ARM64' } else { 'x64' }
$exe = Join-Path $root "apps\windows\src\VoxClip.App\bin\$platform\Release\net10.0-windows10.0.26100.0\$RuntimeIdentifier\VoxClip.exe"
$app = $null
try {
    if (-not [Environment]::UserInteractive) { throw 'Run the Release probe on the owned interactive desktop.' }
    $app = Start-Process -FilePath $exe -ArgumentList "--transcript-frame-probe `"$evidence`"" -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) {
        if ($app.HasExited) { throw 'The Release probe exited before reporting frame time.' }
        $app.Refresh()
        if ($app.MainWindowHandle -ne [IntPtr]::Zero) {
            $window = [System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
            $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Accept and continue')
            $accept = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($accept) { $accept.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $ready)) { throw 'The main window did not become ready before sampling.' }
    $window = $null; $accept = $null; $condition = $null
    [IO.File]::WriteAllText($start, [DateTime]::UtcNow.ToString('O'))
    while (-not (Test-Path -LiteralPath $result) -and [DateTime]::UtcNow -lt $deadline) {
        $app.Refresh()
        if ($app.HasExited) { throw 'The Release probe exited before reporting frame time.' }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $result)) { throw 'No Release frame-time report within 60 seconds.' }
    $measured = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
    if ($measured.Status -ne 'ok' -or -not $measured.Release) { throw 'Release frame-time gate failed; inspect the retained report and realization profile.' }
    $measured | ConvertTo-Json -Depth 6
} finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force; [void]$app.WaitForExit(5000) }
}
