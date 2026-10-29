param(
    [Parameter(Mandatory = $true)][string] $Vpk,
    [Parameter(Mandatory = $true)][string] $AppDirectory,
    [Parameter(Mandatory = $true)][string] $OutputDirectory,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][ValidateSet('win-x64', 'win-arm64')][string] $RuntimeIdentifier,
    [Parameter(Mandatory = $true)][ValidateSet('vcredist143-x64', 'vcredist143-arm64')][string] $Framework,
    [Parameter(Mandatory = $true)][string] $Icon,
    [Parameter(Mandatory = $true)][string] $SignTool,
    [Parameter(Mandatory = $true)][string] $Dlib,
    [Parameter(Mandatory = $true)][string] $Metadata,
    [string] $ReleaseNotes
)

. (Join-Path $PSScriptRoot 'Release-Common.ps1')

if ($Framework -cne (Get-ReleasePrerequisite -RuntimeIdentifier $RuntimeIdentifier)) { throw 'VC++ prerequisite architecture does not match the package.' }
if (-not (Test-Path -LiteralPath $Icon -PathType Leaf)) { throw "Missing release ICO: $Icon (win-ui owns this asset)." }
$wrapper = Join-Path $PSScriptRoot 'Sign-Artifacts.ps1'
$signTemplate = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -SignTool "{1}" -Dlib "{2}" -Metadata "{3}" -Paths {{file}}' -f $wrapper, $SignTool, $Dlib, $Metadata
$signTemplate = $signTemplate.Replace('{file}', '{{file}}')
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$arguments = @(
    'pack', '--packId', 'VoxClip', '--packVersion', $Version,
    '--packTitle', 'VoxClip', '--packAuthors', 'Haugas Development OU',
    '--packDir', $AppDirectory, '--mainExe', 'VoxClip.exe', '--icon', $Icon,
    '--channel', $RuntimeIdentifier, '--runtime', $RuntimeIdentifier,
    '--framework', $Framework,
    '--noPortable', '--signTemplate', $signTemplate, '-o', $OutputDirectory
)
if ($ReleaseNotes) { $arguments += @('--releaseNotes', $ReleaseNotes) }
Invoke-ReleaseTool -Executable $Vpk -Arguments $arguments
$setup = Join-Path $OutputDirectory "VoxClip-$RuntimeIdentifier-Setup.exe"
& $wrapper -SignTool $SignTool -Dlib $Dlib -Metadata $Metadata -Paths $setup
if (-not $?) { throw 'Installer post-sign failed.' }
$signature = Get-AuthenticodeSignature -LiteralPath $setup
$publisher = $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
$publisher = $publisher.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
if ($publisher -ine 'Haugas Development OU') { throw 'Unexpected installer publisher.' }
