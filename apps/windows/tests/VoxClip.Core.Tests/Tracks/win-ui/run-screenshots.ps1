param([ValidateSet('all', 'editor', 'home', 'settings')][string]$Screen = 'all', [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug', [switch]$Exercise, [string]$Root = 'C:\voxclip-build\win-ui')
$ErrorActionPreference = 'Stop'
$root = $Root
$launcher = Join-Path $root 'apps\windows\tests\VoxClip.Core.Tests\Tracks\win-ui\launch-windows.ps1'
$script = Join-Path $root 'apps\windows\tests\VoxClip.Core.Tests\Tracks\win-ui\capture-windows.ps1'
$shots = Join-Path $root 'screenshots'
New-Item -ItemType Directory -Force $shots | Out-Null
if ($Configuration -eq 'Release' -and ($Screen -ne 'home' -or $Exercise)) { throw 'Release probes support Home only; fixture exercises are debug-only.' }
$captureNames = @('editor', 'home', 'settings', 'export', 'editor-clips', 'settings-providers-keys', 'settings-local-models', 'settings-export', 'settings-accounts', 'settings-about', 'onboarding-1', 'onboarding-2', 'onboarding-3', 'settings-general-dark', 'editor-dark')
foreach ($name in $captureNames) {
    Remove-Item (Join-Path $shots "$name-window.png"), (Join-Path $shots "$name-window.jpg"), (Join-Path $shots "$name-self-check.json"), (Join-Path $shots "$name-interactions.json") -Force -ErrorAction SilentlyContinue
}
try {
    $screens = if ($Screen -eq 'all') { @('editor', 'home', 'settings') } else { @($Screen) }
    foreach ($screen in $screens) {
    Write-Output "Capturing $screen at $([DateTime]::UtcNow.ToString('O'))"
    Remove-Item (Join-Path $shots 'complete'), (Join-Path $shots 'error.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $shots "$screen.png"), (Join-Path $shots "$screen-window.png"), (Join-Path $shots "$screen-self-check.json") -Force -ErrorAction SilentlyContinue
    & schtasks.exe /Create /TN VoxClipUiWinUi /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" -Screen $screen -Configuration $Configuration -Root `"$root`"" /SC ONCE /ST 00:00 /IT /F
    if ($LASTEXITCODE -ne 0) { throw 'Could not create app task.' }
    $exerciseArgument = if ($Exercise) { ' -Exercise' } else { '' }
    & schtasks.exe /Create /TN VoxClipShotWinUi /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Screen $screen$exerciseArgument -Root `"$root`"" /SC ONCE /ST 00:00 /IT /F
    if ($LASTEXITCODE -ne 0) { throw 'Could not create screenshot task.' }
    & schtasks.exe /Run /TN VoxClipUiWinUi
    & schtasks.exe /Run /TN VoxClipShotWinUi
    for ($attempt = 0; $attempt -lt 75; $attempt++) {
        if (Test-Path (Join-Path $shots 'complete')) { break }
        Start-Sleep -Seconds 2
    }
    if (-not (Test-Path (Join-Path $shots 'complete'))) { throw 'Interactive screenshot task exceeded 150 seconds.' }
    if (Test-Path (Join-Path $shots 'error.txt')) { throw (Get-Content (Join-Path $shots 'error.txt') -Raw) }
    if (-not (Test-Path (Join-Path $shots "$screen-window.png"))) { throw "The $screen window was not captured." }
    & schtasks.exe /End /TN VoxClipShotWinUi
    & schtasks.exe /End /TN VoxClipUiWinUi
    Start-Sleep -Seconds 2
    }
    if ($Screen -eq 'all') {
        $hashes = @('editor', 'home', 'settings') | ForEach-Object { (Get-FileHash (Join-Path $shots "$_-window.png")).Hash }
        if (@($hashes | Select-Object -Unique).Count -ne 3) {
            foreach ($screen in @('editor', 'home', 'settings')) { Remove-Item (Join-Path $shots "$screen.png"), (Join-Path $shots "$screen-window.png"), (Join-Path $shots "$screen-window.jpg") -Force -ErrorAction SilentlyContinue }
            throw 'Screen navigation did not change the captured image. Duplicate captures were discarded.'
        }
    }
    Get-ChildItem $shots
} catch {
    [System.IO.File]::WriteAllText((Join-Path $shots 'error.txt'), $_.Exception.Message)
    throw
} finally {
    $ErrorActionPreference = 'Continue'
    & schtasks.exe /End /TN VoxClipUiWinUi 2>$null
    & schtasks.exe /End /TN VoxClipShotWinUi 2>$null
    & schtasks.exe /Delete /TN VoxClipUiWinUi /F 2>$null
    & schtasks.exe /Delete /TN VoxClipShotWinUi /F 2>$null
    Get-Process VoxClip -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root\*" } | Stop-Process -Force
}
