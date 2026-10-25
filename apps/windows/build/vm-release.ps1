param([Parameter(Mandatory = $true)][string] $Config, [switch] $ResumeSkeletonTest)

. (Join-Path $PSScriptRoot 'Release-Common.ps1')
$configuration = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$runDirectory = Split-Path -Parent $Config
if (-not $runDirectory.StartsWith(($configuration.BuildRoot.TrimEnd('\') + '\runs\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing a build outside the win-release VM directory.' }
$signingDirectory = Join-Path $runDirectory 'private'
$repository = Join-Path $runDirectory 'source'
$out = Join-Path $runDirectory 'out'
$evidence = Join-Path $out 'evidence'
$upload = Join-Path $out 'upload'
$credentials = @{}
$skeletonTest = $configuration.PSObject.Properties['SkeletonTest'] -and $configuration.SkeletonTest
if ($skeletonTest -and -not $configuration.AllowDirty) { throw 'Skeleton verification must be a non-uploadable test build.' }
if ($ResumeSkeletonTest -and -not $skeletonTest) { throw 'Only non-uploadable skeleton tests may reuse a publish.' }
$credentialNames = @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')
$oldDotnetRoot = $env:DOTNET_ROOT
$oldPath = $env:PATH
$env:MSBUILDDISABLENODEREUSE = '1'
$env:DOTNET_CLI_USE_MSBUILD_SERVER = '0'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_ROOT = Split-Path -Parent $configuration.Dotnet
$env:PATH = "$env:DOTNET_ROOT;$env:PATH"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$PSDefaultParameterValues['Invoke-WebRequest:UseBasicParsing'] = $true
$ProgressPreference = 'SilentlyContinue'

function Assert-ReleaseSigningCredentials {
    param([hashtable] $Credentials)
    $patterns = @{
        AZURE_SIGNING_ACCOUNT = '\A[A-Za-z0-9][A-Za-z0-9-]{1,63}\z'
        AZURE_SIGNING_PROFILE = '\A[A-Za-z0-9][A-Za-z0-9-]{1,63}\z'
        AZURE_SIGNING_ENDPOINT = '\Ahttps://[a-z]{2,8}\.codesigning\.azure\.net\z'
    }
    foreach ($name in @('AZURE_SIGNING_ACCOUNT', 'AZURE_SIGNING_PROFILE', 'AZURE_SIGNING_ENDPOINT')) {
        if (-not $Credentials[$name] -or $Credentials[$name] -cnotmatch $patterns[$name]) { throw $name }
    }
    foreach ($mapping in @(@('AZURE_TENANT_ID', 'AZURE_SIGNING_KVT'), @('AZURE_CLIENT_ID', 'AZURE_SIGNING_KVI'), @('AZURE_CLIENT_SECRET', 'AZURE_SIGNING_KVS'))) {
        if (-not $Credentials[$mapping[0]]) { $Credentials[$mapping[0]] = $Credentials[$mapping[1]] }
        if (-not $Credentials[$mapping[0]] -or -not $Credentials[$mapping[0]].Trim()) { throw "Signing credentials missing: $($mapping[0])" }
    }
}

function Copy-ReleaseFfmpeg {
    param([string] $Rid, [string] $AppDirectory, [object] $Pin)
    $windows = Join-Path $repository 'apps\windows'
    if ($Pin.schema -ne 'voxclip-ffmpeg/2' -or $Pin.PSObject.Properties['btbnCommit']) {
        throw 'Shipping FFmpeg requires a schema-2 self-built pin.'
    }
    $build = $Pin.builds.PSObject.Properties[$Rid].Value
    $configured = $Pin.configure.PSObject.Properties[$Rid].Value
    if (-not $build -or -not $configured) { throw "FFmpeg schema-2 pin is missing $Rid." }
    $testTool = if ($Pin.testTools) { $Pin.testTools.PSObject.Properties[$Rid].Value } else { $null }
    if ($testTool -and $build.sha256 -eq $testTool.sha256) {
        throw "Test-only FFmpeg ZIP cannot ship for $Rid."
    }
    $stage = Join-Path $runDirectory 'ffmpeg'
    $receipt = Get-Content -LiteralPath (Join-Path $stage 'stage.json') -Raw | ConvertFrom-Json
    if ($receipt.schema -ne $Pin.schema -or $receipt.commit -ne $configuration.Commit -or
        $receipt.buildInputsSha256 -ne $Pin.buildInputsSha256) {
        throw 'FFmpeg stage does not match the release commit and build inputs.'
    }
    $required = @($build.name, 'FFmpeg-LICENSE.txt', 'FFmpeg-LICENSE.md', "$Rid-FFmpeg-NOTICES.txt", "$Rid-audit.json", 'BUILD.txt')
    foreach ($name in $required) {
        $record = $receipt.files.PSObject.Properties[$name]
        $path = Join-Path $stage $name
        if (-not $record -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Item -LiteralPath $path).Length -ne $record.Value.size -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.Value.sha256) {
            throw "FFmpeg staged evidence differs from the release pin: $name"
        }
    }
    $zipRecord = $receipt.files.PSObject.Properties[$build.name].Value
    if ($zipRecord.size -ne $build.size -or $zipRecord.sha256 -ne $build.sha256) {
        throw "FFmpeg ZIP differs from the self-built $Rid pin."
    }
    & (Join-Path $windows 'build\Fetch-Ffmpeg.ps1') -RuntimeIdentifier $Rid -ZipPath (Join-Path $stage $build.name)
    if (-not $?) { throw "FFmpeg local ZIP verification failed for $Rid." }
    $cache = Join-Path $windows "build\.cache\ffmpeg\$Rid"
    Copy-Item -Path (Join-Path $cache 'native\*.dll') -Destination $AppDirectory -Force
    $licences = Join-Path $AppDirectory 'licenses'
    New-Item -ItemType Directory -Force -Path $licences | Out-Null
    foreach ($name in @('FFmpeg-LICENSE.txt', 'FFmpeg-LICENSE.md', 'BUILD.txt')) {
        $destination = if ($name -eq 'BUILD.txt') { 'FFmpeg-BUILD.txt' } else { $name }
        Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $licences $destination)
    }
    Copy-Item -LiteralPath (Join-Path $stage "$Rid-FFmpeg-NOTICES.txt") -Destination (Join-Path $licences 'FFmpeg-NOTICES.txt')
    $gateProject = Join-Path $runDirectory "gate\$Rid"
    New-Item -ItemType Directory -Force -Path $gateProject | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Ffmpeg-LicenceGate.cs') -Destination $gateProject
    [IO.File]::WriteAllText((Join-Path $gateProject 'Gate.csproj'), '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><EnableDefaultCompileItems>true</EnableDefaultCompileItems></PropertyGroup></Project>', [Text.Encoding]::ASCII)
    $gateOutput = Join-Path $gateProject 'publish'
    Invoke-ReleaseTool -Executable $configuration.Dotnet -Arguments @('publish', (Join-Path $gateProject 'Gate.csproj'), '-c', 'Release', '-r', $Rid, '--self-contained', '-nodeReuse:false', '-p:UseSharedCompilation=false', '-o', $gateOutput)
    $codec = @(Get-ChildItem $AppDirectory -File -Filter 'avcodec-*.dll')
    if ($codec.Count -ne 1) { throw 'Expected exactly one shipped avcodec DLL.' }
    $env:PATH = "$AppDirectory;$env:PATH"
    $gateText = (& (Join-Path $gateOutput 'Gate.exe') $codec[0].FullName | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "LGPL avcodec_configuration/avcodec_license gate failed for $Rid." }
    $gate = $gateText | ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $evidence "$Rid-ffmpeg.json"), $gateText, [Text.Encoding]::ASCII)
    if ($gate.configuration -ne $configured -or $gate.licence -ne $Pin.license) {
        throw 'FFmpeg configure/licence does not match the self-built source pin.'
    }
    if ($gate.licence -match 'version 3') { throw 'LGPLv3 binary requires separately staged corresponding licence texts.' }
}

try {
    $process = Get-Process -Id $PID
    [IO.File]::WriteAllText((Join-Path $runDirectory 'process.json'), (@{ id = $PID; started = $process.StartTime.ToUniversalTime().ToString('o') } | ConvertTo-Json), [Text.Encoding]::ASCII)
    foreach ($name in $credentialNames) {
        if ([Environment]::GetEnvironmentVariable($name, 'Process')) { throw 'Build session must start without Azure signing credentials in its environment.' }
    }
    Set-ReleasePrivateAcl -Path $signingDirectory
    try {
        $raw = [Console]::In.ReadToEnd()
        $allowed = @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_SIGNING_KVT', 'AZURE_SIGNING_KVI', 'AZURE_SIGNING_KVS', 'AZURE_SIGNING_ENDPOINT', 'AZURE_SIGNING_ACCOUNT', 'AZURE_SIGNING_PROFILE')
        foreach ($line in ($raw -split '\r?\n')) {
            if ($line -match '^\s*(?:export\s+)?([A-Z_]+)\s*=\s*(.*?)\s*$' -and $matches[1] -in $allowed) {
                $name = $matches[1]
                $value = $matches[2]
                if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) { $value = $value.Substring(1, $value.Length - 2) }
                if ($credentials.ContainsKey($name)) { throw "Duplicate signing variable: $name" }
                $credentials[$name] = $value
            }
        }
    } finally {
        $raw = $null; $value = $null; $line = $null; $matches = $null
    }
    Assert-ReleaseSigningCredentials -Credentials $credentials
    $metadata = Join-Path $signingDirectory 'metadata.json'
    $metadataValues = [ordered]@{ Endpoint = $credentials['AZURE_SIGNING_ENDPOINT']; CodeSigningAccountName = $credentials['AZURE_SIGNING_ACCOUNT']; CertificateProfileName = $credentials['AZURE_SIGNING_PROFILE'] }
    [IO.File]::WriteAllText($metadata, (ConvertTo-Json -InputObject $metadataValues -Compress), [Text.Encoding]::ASCII)
    Write-Host 'Signing credentials: present in memory from SSH stdin.'
    if ($ResumeSkeletonTest) {
        foreach ($relative in @('upload', 'win-x64\releases', 'win-arm64\releases', 'win-x64\verify-package', 'win-arm64\verify-package')) {
            $stale = Join-Path $out $relative
            if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force }
        }
    }
    foreach ($directory in @($repository, $evidence, $upload)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    if (-not $ResumeSkeletonTest) {
        Invoke-ReleaseTool -Executable 'tar.exe' -Arguments @('-xzf', (Join-Path $runDirectory 'source.tar.gz'), '-C', $repository)
    }
    $sdk = (& $configuration.Dotnet --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $sdk -notlike '10.*') { throw 'A .NET 10 SDK is required.' }
    $signToolEvidence = Resolve-ReleaseSignTool -Override $configuration.SignTool -Dlib $configuration.Dlib
    $configuration.SignTool = $signToolEvidence.path
    [IO.File]::WriteAllText((Join-Path $evidence 'signing-tool.json'), ($signToolEvidence | ConvertTo-Json), [Text.Encoding]::ASCII)
    foreach ($path in @($configuration.SignTool, $configuration.Dlib)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Signing prerequisite missing: $path" }
    }
    $windows = Join-Path $repository 'apps\windows'
    $releaseNotes = $null
    $changelog = Join-Path $repository 'CHANGELOG.md'
    if (Test-Path -LiteralPath $changelog) {
        $pattern = '(?ms)^## ' + [regex]::Escape($configuration.Version) + '(?: - [^\r\n]*)?\r?\n(.*?)(?=^## |\z)'
        $notesMatch = [regex]::Match([IO.File]::ReadAllText($changelog), $pattern)
        if (-not $notesMatch.Success) { throw 'CHANGELOG.md has no notes for the release version.' }
        $releaseNotes = Join-Path $runDirectory 'release-notes.md'
        [IO.File]::WriteAllText($releaseNotes, $notesMatch.Groups[1].Value.Trim(), (New-Object Text.UTF8Encoding($false)))
    } elseif (-not $skeletonTest) { throw 'CHANGELOG.md is required for production release notes.' }
    $pin = Get-Content (Join-Path $windows 'build\ffmpeg.json') -Raw | ConvertFrom-Json
    $failures = @()
    foreach ($rid in @('win-x64', 'win-arm64')) {
        $app = Join-Path $out "$rid\app"
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        foreach ($project in @('VoxClip.Cli', 'VoxClip.App')) {
            if ($ResumeSkeletonTest) {
                $executable = if ($project -eq 'VoxClip.Cli') { 'voxclip-cli.exe' } else { 'VoxClip.exe' }
                if (-not (Test-Path -LiteralPath (Join-Path $app $executable))) { throw 'Cannot resume an incomplete skeleton publish.' }
                continue
            }
            try {
                $arguments = @('publish', (Join-Path $windows "src\$project\$project.csproj"), '-c', 'Release', '-r', $rid, '--self-contained', '-nodeReuse:false', '-p:UseSharedCompilation=false', '-m:1', '-o', $app)
                if ($project -eq 'VoxClip.App') {
                    $platform = if ($rid -eq 'win-x64') { 'x64' } else { 'ARM64' }
                    $arguments += "-p:Platform=$platform"
                }
                Invoke-ReleaseTool -Executable $configuration.Dotnet -Arguments $arguments
            } catch { $failures += "$rid $project : $($_.Exception.Message)" }
        }
        try {
            Assert-ReleaseResources -Repository $repository -AppDirectory $app
            Copy-ReleaseFfmpeg -Rid $rid -AppDirectory $app -Pin $pin
        } catch { $failures += "$rid resources/FFmpeg : $($_.Exception.Message)" }
    }
    Invoke-ReleaseTool -Executable $configuration.Dotnet -Arguments @('build-server', 'shutdown')
    if ($failures.Count) { throw ($failures -join "`n") }
    [xml] $packages = Get-Content (Join-Path $windows 'Directory.Packages.props') -Raw
    $vpkVersion = @($packages.Project.ItemGroup.PackageVersion | Where-Object { $_.Include -eq 'Velopack' })[0].Version
    $toolDirectory = Join-Path (Join-Path $configuration.BuildRoot 'tools') $vpkVersion
    $vpk = Join-Path $toolDirectory 'vpk.exe'
    if (-not (Test-Path -LiteralPath $vpk)) {
        Invoke-ReleaseTool -Executable $configuration.Dotnet -Arguments @('tool', 'install', 'vpk', '--tool-path', $toolDirectory, '--version', $vpkVersion)
    }
    foreach ($rid in @('win-x64', 'win-arm64')) {
        Get-ReleaseDeltaBase -Vpk $vpk -RuntimeIdentifier $rid -OutputDirectory (Join-Path $out "$rid\releases")
    }
    try {
        Write-Host 'Signing credentials: present (values never logged).'
        foreach ($name in $credentialNames) { [Environment]::SetEnvironmentVariable($name, $credentials[$name], 'Process') }
        $env:VOXCLIP_SIGNING_DOTNET_ROOT = if ($configuration.SigningDotnetRoot) { $configuration.SigningDotnetRoot } else { Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet' }
        foreach ($rid in @('win-x64', 'win-arm64')) {
            $app = Join-Path $out "$rid\app"
            & (Join-Path $PSScriptRoot 'Sign-Artifacts.ps1') -SignTool $configuration.SignTool -Dlib $configuration.Dlib -Metadata $metadata -Paths $app
            if (-not $?) { throw "Payload signing failed for $rid." }
            $icon = Join-Path $windows 'src\VoxClip.App\Assets\VoxClip.ico'
            if ($skeletonTest -and -not (Test-Path $icon)) {
                $icon = Join-Path $repository 'shared\brand\windows\app.ico'
                Write-Host 'WARNING: SKELETON TEST ONLY: using shared brand ICO; win-ui must provide the release ICO path.'
            }
            & (Join-Path $PSScriptRoot 'Pack-Velopack.ps1') -Vpk $vpk -AppDirectory $app -OutputDirectory (Join-Path $out "$rid\releases") -Version $configuration.Version -RuntimeIdentifier $rid -Icon $icon -SignTool $configuration.SignTool -Dlib $configuration.Dlib -Metadata $metadata -ReleaseNotes $releaseNotes
            if (-not $?) { throw "Velopack packaging failed for $rid." }
        }
    } finally {
        foreach ($name in $credentialNames) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        $credentials.Clear()
        Remove-Item Env:VOXCLIP_SIGNING_DOTNET_ROOT -ErrorAction SilentlyContinue
        $env:DOTNET_ROOT = Split-Path -Parent $configuration.Dotnet
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($rid in @('win-x64', 'win-arm64')) {
        $ridEvidence = Join-Path $evidence $rid
        New-Item -ItemType Directory -Force -Path $ridEvidence | Out-Null
        Assert-ReleaseSignatures -Paths (Join-Path $out "$rid\app") -SignTool $configuration.SignTool -ReportPath (Join-Path $ridEvidence 'payload-signatures.json')
        $releases = Join-Path $out "$rid\releases"
        $setup = Join-Path $releases "VoxClip-$rid-Setup.exe"
        Assert-ReleaseSignatures -Paths $setup -SignTool $configuration.SignTool -ReportPath (Join-Path $ridEvidence 'setup-signatures.json')
        $assets = Get-Content (Join-Path $releases "assets.$rid.json") -Raw | ConvertFrom-Json
        $packageNames = @($assets | Where-Object { $_.Type -in @('Full', 'Delta') } | ForEach-Object { $_.RelativeFileName })
        if (-not ($packageNames | Where-Object { $_ -like '*-full.nupkg' })) { throw "No full package in assets.$rid.json." }
        foreach ($name in $packageNames) {
            if ([IO.Path]::GetFileName($name) -ne $name -or $name -notmatch '\.nupkg$') { throw 'Invalid package name in Velopack metadata.' }
            $package = Join-Path $releases $name
            if ($name -like '*-full.nupkg') {
                $expanded = Join-Path $out "$rid\verify-package"
                [IO.Compression.ZipFile]::ExtractToDirectory($package, $expanded)
                Assert-ReleaseSignatures -Paths $expanded -SignTool $configuration.SignTool -ReportPath (Join-Path $ridEvidence 'package-signatures.json')
                Remove-Item -LiteralPath $expanded -Recurse -Force
            }
            Copy-Item -LiteralPath $package -Destination $upload
        }
        Copy-Item -LiteralPath $setup -Destination $upload
        Copy-Item -LiteralPath (Join-Path $releases "releases.$rid.json") -Destination $upload
        & (Join-Path $PSScriptRoot 'Test-Install.ps1') -Setup $setup -SignTool $configuration.SignTool -Version $configuration.Version -RuntimeIdentifier $rid -ReportDirectory $ridEvidence
        if (-not $?) { throw "Install smoke test failed for $rid." }
    }
    $sums = @(Get-ChildItem $upload -File | Sort-Object Name | ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name })
    [IO.File]::WriteAllText((Join-Path $upload 'SHA256SUMS-windows.txt'), (($sums -join "`n") + "`n"), [Text.Encoding]::ASCII)
    $receipt = @{ version = $configuration.Version; commit = $configuration.Commit; testBuild = $configuration.AllowDirty; sdk = $sdk; vpk = $vpkVersion; signTool = $signToolEvidence; verified = $true }
    [IO.File]::WriteAllText((Join-Path $evidence 'verification.json'), ($receipt | ConvertTo-Json), [Text.Encoding]::ASCII)
    Write-Host "Build, sign, pack, signature verification and install tests passed: $out"
} finally {
    foreach ($name in $credentialNames) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    $credentials.Clear()
    $env:DOTNET_ROOT = $oldDotnetRoot
    $env:PATH = $oldPath
    try {
        if (Test-Path -LiteralPath $signingDirectory) { Remove-Item -LiteralPath $signingDirectory -Recurse -Force }
    } finally {
        $archive = Join-Path $runDirectory 'source.tar.gz'
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        Remove-Item -LiteralPath (Join-Path $runDirectory 'process.json') -Force -ErrorAction SilentlyContinue
    }
}
