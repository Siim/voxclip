param(
    [Parameter(Mandatory=$true)][ValidateSet('Backup','Run')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$LeaseToken,
    [string]$HostBackupSha256,
    [string]$InventoryPath,
    [string]$Dotnet = 'C:\Program Files\dotnet\dotnet.exe',
    [string]$TestAssembly = 'C:\voxclip-build\win-ui\apps\windows\tests\VoxClip.Media.Tests\bin\Debug\net10.0\win-arm64\VoxClip.Media.Tests.dll'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ((Get-Content -LiteralPath 'C:\voxclip-build\vm.lock\owner' -Raw).Trim() -ne $LeaseToken) { throw 'Owned VM lease is required.' }
if ((Get-PSDrive C).Free -lt 7.5GB) { throw 'N5 is owed: 6 GiB reserve plus 1.5 GiB headroom required.' }
$registry = 'HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged'
if ($Mode -eq 'Backup') {
    if (Test-Path -LiteralPath 'C:\voxclip-build\win-ui\microphone-privacy.reg') { throw 'Preserve the existing privacy backup; reconcile it before starting another N5.' }
    & reg.exe export $registry 'C:\voxclip-build\win-ui\microphone-privacy.reg'
    if ($LASTEXITCODE -ne 0) { throw 'N5 is owed: microphone ConsentStore export failed. No setting was changed.' }
    (Get-FileHash -LiteralPath 'C:\voxclip-build\win-ui\microphone-privacy.reg' -Algorithm SHA256).Hash
    Write-Output 'Copy this backup to the host before Run. Pass the hash computed from that host copy.'
    exit 0
}
$originalHash = (Get-FileHash -LiteralPath 'C:\voxclip-build\win-ui\microphone-privacy.reg' -Algorithm SHA256).Hash
if (!$HostBackupSha256 -or $originalHash -ne $HostBackupSha256) { throw 'N5 is owed: a matching host backup SHA256 is required.' }
if (!$InventoryPath) { throw 'N5 is owed: supply this architecture N1 inventory evidence first.' }
$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
if ($inventory.Step -ne 'N1' -or $inventory.Result.CaptureCount -lt 1 -or !$inventory.Result.HasDefaultCapture) { throw 'N5 is owed: N1 found no default capture endpoint.' }
& reg.exe export $registry 'C:\voxclip-build\win-ui\microphone-privacy-before.reg' /y
if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath 'C:\voxclip-build\win-ui\microphone-privacy-before.reg' -Algorithm SHA256).Hash -ne $originalHash) { throw 'ConsentStore changed since backup; reconcile without changing privacy.' }
if ($env:VOXCLIP_DEBUG_MIC) { throw 'N5 must use the real capture endpoint, never a DEBUG scenario.' }
$keyExisted = Test-Path -LiteralPath $key
$valueExisted = $false
if ($keyExisted) { $valueExisted = (Get-Item -LiteralPath $key).GetValueNames() -contains 'Value' }
$oldHarness = $env:VOXCLIP_MIC_PRIVACY_HARNESS
$oldInput = $env:VOXCLIP_REQUIRE_AUDIO_INPUT
$restored = $false
try {
    if (!$keyExisted) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -LiteralPath $key -Name Value -Value Deny -PropertyType String -Force | Out-Null
    $env:VOXCLIP_MIC_PRIVACY_HARNESS = 'backed-up'
    $env:VOXCLIP_REQUIRE_AUDIO_INPUT = '1'
    & $Dotnet $TestAssembly -class '*MicrophoneNativeTests' -method '*N5*'
    if ($LASTEXITCODE -ne 0) { throw 'N5 failed; restoration still runs.' }
} finally {
    $env:VOXCLIP_MIC_PRIVACY_HARNESS = $oldHarness
    $env:VOXCLIP_REQUIRE_AUDIO_INPUT = $oldInput
    if (!$keyExisted) {
        Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged' -Recurse -Force
    } elseif (!$valueExisted) {
        Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged' -Name Value -ErrorAction SilentlyContinue
    }
    & reg.exe import 'C:\voxclip-build\win-ui\microphone-privacy.reg'
    if ($LASTEXITCODE -ne 0) { throw 'STOP: microphone registry restoration failed. Preserve the lease and backups for recovery.' }
    & reg.exe export $registry 'C:\voxclip-build\win-ui\microphone-privacy-restored.reg' /y
    if ($LASTEXITCODE -eq 0) {
        $restored = (Get-FileHash -LiteralPath 'C:\voxclip-build\win-ui\microphone-privacy-restored.reg' -Algorithm SHA256).Hash -eq $originalHash
    }
    if (!$restored) { throw 'STOP: microphone registry restoration is unverified. Preserve the lease and backups for recovery.' }
    Write-Output 'N5 registry restoration verified against the host-backed export.'
}
