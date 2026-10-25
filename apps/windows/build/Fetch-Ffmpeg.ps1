param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $RuntimeIdentifier = 'win-arm64',
    [string] $ZipPath = $env:VOXCLIP_FFMPEG_ZIP,
    [switch] $TestTools
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$pin = Get-Content (Join-Path $PSScriptRoot 'ffmpeg.json') -Raw | ConvertFrom-Json
$cache = Join-Path $PSScriptRoot ".cache/ffmpeg/$RuntimeIdentifier"
New-Item -ItemType Directory -Force -Path $cache | Out-Null

if ($TestTools) {
    $tool = $pin.testTools.$RuntimeIdentifier
    if (-not $tool -or $tool.purpose -ne 'TEST ONLY; never ship') {
        throw 'Missing explicitly marked test-only FFmpeg tool pin.'
    }
    $archive = Join-Path $cache 'test-tools.zip'
    if (-not (Test-Path $archive)) {
        Invoke-WebRequest -Uri $tool.url -OutFile $archive
    }
    $expectedHash = $tool.sha256
} else {
    $build = $pin.builds.$RuntimeIdentifier
    if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw 'Supply a locally staged, pinned FFmpeg ZIP with -ZipPath or VOXCLIP_FFMPEG_ZIP.'
    }
    $archive = (Resolve-Path -LiteralPath $ZipPath).Path
    if ((Get-Item -LiteralPath $archive).Length -ne $build.size) {
        throw 'FFmpeg ZIP size differs from the schema-2 pin.'
    }
    $expectedHash = $build.sha256
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
    throw 'FFmpeg ZIP SHA-256 differs from the pinned manifest.'
}

$expected = @($pin.libraryMajors.PSObject.Properties | ForEach-Object {
    "$($_.Name)-$($_.Value).dll"
})
$native = Join-Path $cache $(if ($TestTools) { 'test-tools' } else { 'native' })
$expanded = Join-Path $cache $(if ($TestTools) { 'test-expanded' } else { 'expanded' })
if (Test-Path $expanded) { Remove-Item $expanded -Recurse -Force }
New-Item -ItemType Directory -Force -Path $expanded | Out-Null
try {
    if (-not $TestTools) {
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $actual = @($zip.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName })
            $wanted = @($expected | ForEach-Object { "bin/$_" })
            if (@(Compare-Object $actual $wanted).Count -ne 0 -or $actual.Count -ne $wanted.Count) {
                throw 'Pinned shipping ZIP must contain exactly the six ABI-named DLLs in bin/.'
            }
        } finally { $zip.Dispose() }
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
    if (Test-Path $native) { Remove-Item $native -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $native | Out-Null
    foreach ($name in $expected) {
        $matches = @(Get-ChildItem $expanded -Recurse -File -Filter $name)
        if ($matches.Count -ne 1) { throw "Expected exactly one $name in verified archive." }
        Copy-Item -LiteralPath $matches[0].FullName -Destination $native
    }
    if ($TestTools) {
        foreach ($name in @('avdevice-63.dll', 'ffmpeg.exe', 'ffprobe.exe')) {
            $matches = @(Get-ChildItem $expanded -Recurse -File -Filter $name)
            if ($matches.Count -ne 1) { throw "Expected exactly one test-only $name." }
            Copy-Item -LiteralPath $matches[0].FullName -Destination $native
        }
        Write-Output "Verified TEST-ONLY tools at $native. Never package this directory."
    } else {
        Write-Output "Verified self-built $($pin.version) for $RuntimeIdentifier at $native"
    }
} finally {
    if (Test-Path $expanded) { Remove-Item $expanded -Recurse -Force }
}
