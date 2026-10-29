param([ValidateSet('all', 'editor', 'home', 'settings')][string]$Screen = 'all', [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug', [switch]$Exercise, [string]$Root = 'C:\voxclip-build\win-ui', [ValidateSet('win-x64', 'win-arm64')][string]$RuntimeIdentifier = 'win-arm64', [string]$ManualState, [string]$RequiredName)
$ErrorActionPreference = 'Stop'
$root = $Root
$launcher = Join-Path $root 'apps\windows\tests\VoxClip.Core.Tests\Tracks\win-ui\launch-windows.ps1'
$script = Join-Path $root 'apps\windows\tests\VoxClip.Core.Tests\Tracks\win-ui\capture-windows.ps1'
$shots = Join-Path $root "screenshots\$RuntimeIdentifier"
New-Item -ItemType Directory -Force $shots | Out-Null
function Write-Catalog {
    $required = @('home', 'home-empty', 'home-dragover', 'editor-light', 'editor-dark', 'editor-1280-light', 'editor-compact-light', 'finding', 'suggested', 'exported', 'export-edited', 'exporting', 'export-failed', 'transcribing', 'focus', 'opaque-flyout', 'splitter', 'high-contrast-black', 'high-contrast-white')
    $items = foreach ($name in $required) { @{ name=$name; captured=(Test-Path (Join-Path $shots "$name-window.png")); visualReview='pending'; narrator='not observed' } }
    [IO.File]::WriteAllText((Join-Path $shots 'capture-catalog.json'), (ConvertTo-Json -Depth 6 -InputObject @{
        runtime=$RuntimeIdentifier; captures=@($items); mockupToleranceEpx=4; rewrite='deferred with checklist step 15, pending VoiceLabWordDiff';
        acceptance='A captured image or UIA witness is not a pixel, contrast, performance, or spoken Narrator pass.'
    }))
}
if ($ManualState) {
    & $script -Root $root -RuntimeIdentifier $RuntimeIdentifier -ManualState $ManualState -RequiredName $RequiredName
    Write-Catalog
    return
}
if ($Configuration -eq 'Release' -and ($Screen -ne 'home' -or $Exercise)) { throw 'Release probes support Home only; fixture exercises are debug-only.' }
$taskToken = [Guid]::NewGuid().ToString('N')
$appTask = 'VoxClipUiWinUi-' + $taskToken
$shotTask = 'VoxClipShotWinUi-' + $taskToken
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
$captureNames = @('terms', 'editor', 'home', 'settings', 'export', 'export-this-clip', 'editor-full-take', 'editor-find-clips', 'editor-manual-clip', 'editor-preview-end', 'editor-captions', 'editor-light', 'editor-1280-light', 'editor-compact-light', 'editor-compact-viewer', 'editor-compact-dark', 'settings-providers-keys', 'settings-local-models', 'settings-export', 'settings-accounts', 'settings-about', 'onboarding-1', 'onboarding-2', 'onboarding-3', 'settings-general-dark', 'editor-dark')
foreach ($name in $captureNames) {
    Remove-Item (Join-Path $shots "$name-window.png"), (Join-Path $shots "$name-window.jpg"), (Join-Path $shots "$name-self-check.json"), (Join-Path $shots "$name-interactions.json") -Force -ErrorAction SilentlyContinue
}
try {
    $screens = if ($Screen -eq 'all') { @('editor', 'home', 'settings', 'editor-1280-light', 'editor-compact-light') } else { @($Screen) }
    foreach ($capture in $screens) {
    $screen = if ($capture.StartsWith('editor-')) { 'editor' } else { $capture }
    $size = switch ($capture) { 'home' { '1280x800' }; 'editor-1280-light' { '1280x800' }; 'editor-compact-light' { '1024x700' }; default { '1440x900' } }
    Write-Output "Capturing $screen at $([DateTime]::UtcNow.ToString('O'))"
    Remove-Item (Join-Path $shots 'complete'), (Join-Path $shots 'error.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $shots "$screen.png"), (Join-Path $shots "$screen-window.png"), (Join-Path $shots "$screen-self-check.json") -Force -ErrorAction SilentlyContinue
    $ordinaryArgument = if ($Exercise -and $capture -eq 'editor') { ' -OrdinaryEditor' } else { '' }
    $appAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" -Screen $screen -Configuration $Configuration -RuntimeIdentifier $RuntimeIdentifier -WindowSize $size -Root `"$root`"$ordinaryArgument"
    Register-ScheduledTask -TaskName $appTask -Action $appAction -Principal $principal -Force | Out-Null
    $exerciseArgument = if ($Exercise -and $capture -notlike 'editor-*') { ' -Exercise' } else { '' }
    $shotAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Screen $screen$exerciseArgument -CaptureName $capture -RuntimeIdentifier $RuntimeIdentifier -Root `"$root`""
    Register-ScheduledTask -TaskName $shotTask -Action $shotAction -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $appTask
    Start-ScheduledTask -TaskName $shotTask
    for ($attempt = 0; $attempt -lt 75; $attempt++) {
        if (Test-Path (Join-Path $shots 'complete')) { break }
        Start-Sleep -Seconds 2
    }
    if (-not (Test-Path (Join-Path $shots 'complete'))) { throw 'Interactive screenshot task exceeded 150 seconds.' }
    if (Test-Path (Join-Path $shots 'error.txt')) { throw (Get-Content (Join-Path $shots 'error.txt') -Raw) }
    if (-not (Test-Path (Join-Path $shots "$capture-window.png"))) { throw "The $capture window was not captured." }
    Stop-ScheduledTask -TaskName $shotTask
    Stop-ScheduledTask -TaskName $appTask
    Start-Sleep -Seconds 2
    }
    if ($Screen -eq 'all') {
        $hashes = @('editor', 'home', 'settings') | ForEach-Object { (Get-FileHash (Join-Path $shots "$_-window.png")).Hash }
        if (@($hashes | Select-Object -Unique).Count -ne 3) {
            foreach ($screen in @('editor', 'home', 'settings')) { Remove-Item (Join-Path $shots "$screen.png"), (Join-Path $shots "$screen-window.png"), (Join-Path $shots "$screen-window.jpg") -Force -ErrorAction SilentlyContinue }
            throw 'Screen navigation did not change the captured image. Duplicate captures were discarded.'
        }
    }
    Write-Catalog
    Get-ChildItem $shots
} catch {
    [System.IO.File]::WriteAllText((Join-Path $shots 'error.txt'), $_.Exception.Message)
    throw
} finally {
    $ErrorActionPreference = 'Continue'
    Stop-ScheduledTask -TaskName $appTask -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $shotTask -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $appTask -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $shotTask -Confirm:$false -ErrorAction SilentlyContinue
    Get-Process VoxClip -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root\*\$RuntimeIdentifier\VoxClip.exe" } | Stop-Process -Force
}
