param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $RuntimeIdentifier = 'win-arm64'
)

$ErrorActionPreference = 'Stop'
$pin = Get-Content (Join-Path $PSScriptRoot 'ffmpeg.json') -Raw | ConvertFrom-Json
$build = $pin.builds.$RuntimeIdentifier
if ($build.url -notmatch '-lgpl-shared-9\.0\.zip$') {
    throw 'Only the pinned LGPL shared FFmpeg release is allowed.'
}
$cache = Join-Path $PSScriptRoot ".cache/ffmpeg/$RuntimeIdentifier"
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$archive = Join-Path $cache 'ffmpeg.zip'
if (-not (Test-Path $archive)) {
    Invoke-WebRequest -Uri $build.url -OutFile $archive
}
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $build.sha256) {
    throw "FFmpeg checksum mismatch. Remove $archive and retry; never use unverified DLLs."
}
$expanded = Join-Path $cache 'expanded'
Expand-Archive -Path $archive -DestinationPath $expanded -Force
$native = Join-Path $cache 'native'
New-Item -ItemType Directory -Force -Path $native | Out-Null
foreach ($library in $pin.dlls) {
    $matches = @(Get-ChildItem $expanded -Recurse -File -Filter "$library-*.dll")
    if ($matches.Count -ne 1) { throw "Expected exactly one $library DLL in the pinned archive." }
    Copy-Item $matches[0].FullName $native -Force
}
Write-Output "Verified $($pin.version) for $RuntimeIdentifier at $native"
Write-Output 'Retain the complete extracted distribution for its licence/source notices. Release packaging and the avcodec_configuration gate remain win-media work.'
