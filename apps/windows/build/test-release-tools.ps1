. (Join-Path $PSScriptRoot 'Release-Common.ps1')
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Add-Type -AssemblyName System.Security
}
$script:testCount = 0
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('voxclip-release-tools-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null

function Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected failure matching: $Pattern"
}

function Invoke-Test {
    param([string] $Name, [scriptblock] $Action)
    & $Action
    $script:testCount++
    Write-Host "PASS: $Name"
}

function New-TestSigningCredentials {
    return @{ AZURE_SIGNING_ACCOUNT = 'fixture-account'; AZURE_SIGNING_PROFILE = 'fixture-profile'; AZURE_SIGNING_ENDPOINT = 'https://neu.codesigning.azure.net'; AZURE_TENANT_ID = 'fixture'; AZURE_CLIENT_ID = 'fixture'; AZURE_CLIENT_SECRET = 'fixture'; AZURE_SIGNING_KVT = 'fixture-alias'; AZURE_SIGNING_KVI = 'fixture-alias'; AZURE_SIGNING_KVS = 'fixture-alias' }
}

function New-TestSignTool {
    param([string] $Root, [string] $Relative, [uint16] $Machine = 0x8664)
    $path = Join-Path $Root $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $stream = [IO.File]::Create($path)
    try {
        $writer = [IO.BinaryWriter]::new($stream)
        $writer.Write([byte[]]::new(128))
        $stream.Position = 0; $writer.Write([uint16] 0x5a4d)
        $stream.Position = 0x3c; $writer.Write([uint32] 64)
        $stream.Position = 64; $writer.Write([uint32] 0x00004550); $writer.Write($Machine)
    } finally { $stream.Dispose() }
    return $path
}

function Invoke-FakeVpk {
    $script:downloadArguments = $args
    $global:LASTEXITCODE = $script:downloadExitCode
}

function Invoke-RestMethod {
    param([string] $Uri, $Headers, [int] $TimeoutSec)
    $script:requests += $Uri
    Assert-Equal $TimeoutSec 30
    if ($Uri.EndsWith('/latest') -and $script:releaseStatus -ne 200) {
        $exception = New-Object Exception 'Simulated GitHub response'
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $script:releaseStatus })
        throw $exception
    }
    return @{ tag_name = 'v0.0.1' }
}

function New-TestCertificate {
    param([string] $Subject)
    $key = [Security.Cryptography.RSA]::Create(2048)
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new($Subject, $key, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    return $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(1))
}

function New-TestPe {
    param([string] $Path, [string] $TimestampOid)
    $content = [Security.Cryptography.Pkcs.ContentInfo]::new([byte[]]@(1, 2, 3))
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new($content)
    $signer = [Security.Cryptography.Pkcs.CmsSigner]::new($global:releaseOwnerCertificate)
    if ($TimestampOid) {
        $attribute = [Security.Cryptography.AsnEncodedData]::new([Security.Cryptography.Oid]::new($TimestampOid), [byte[]]@(0x30, 0))
        [void] $signer.UnsignedAttributes.Add($attribute)
    }
    $cms.ComputeSignature($signer)
    $encoded = $cms.Encode()
    $stream = [IO.File]::Create($Path)
    try {
        $writer = [IO.BinaryWriter]::new($stream)
        $writer.Write([byte[]]::new(512))
        $stream.Position = 0; $writer.Write([uint16] 0x5a4d)
        $stream.Position = 0x3c; $writer.Write([uint32] 64)
        $stream.Position = 64; $writer.Write([uint32] 0x00004550)
        $stream.Position = 88; $writer.Write([uint16] 0x20b)
        $stream.Position = 232; $writer.Write([uint32] 512); $writer.Write([uint32] ($encoded.Length + 8))
        $stream.Position = 512; $writer.Write([uint32] ($encoded.Length + 8)); $writer.Write([uint16] 0x200); $writer.Write([uint16] 2)
        $writer.Write($encoded)
    } finally { $stream.Dispose() }
}

function Get-AuthenticodeSignature {
    param([string] $LiteralPath)
    return $global:releaseSignatures[$LiteralPath]
}

function Invoke-FakeSignTool {
    $global:LASTEXITCODE = 0
}

try {
    Invoke-Test 'VC++ prerequisite matches each package architecture' {
        Assert-Equal (Get-ReleasePrerequisite -RuntimeIdentifier win-x64) 'vcredist145-x64'
        Assert-Equal (Get-ReleasePrerequisite -RuntimeIdentifier win-arm64) 'vcredist145-arm64'
        Assert-Throws { Get-ReleasePrerequisite -RuntimeIdentifier win-x86 } 'ValidateSet|does not belong'
    }
    Invoke-Test 'VC++ verification rejects missing and pre-14.44 runtimes' {
        Assert-Throws { Assert-ReleaseVcRuntime @{architecture='x64';installed=$false;version=$null} } '14.44'
        Assert-Throws { Assert-ReleaseVcRuntime @{architecture='x64';installed=$true;version='14.30.30704'} } '14.44'
        Assert-ReleaseVcRuntime @{architecture='x64';installed=$true;version='14.44.35211.0'}
        Assert-ReleaseVcRuntime @{architecture='arm64';installed=$true;version='14.50.0.0'}
    }
    $matchRoot = Join-Path $temporary 'file-match'
    New-Item -ItemType Directory -Path $matchRoot | Out-Null
    $matchExpected = Join-Path $matchRoot 'expected.txt'
    $matchActual = Join-Path $matchRoot 'actual.txt'
    [IO.File]::WriteAllText($matchExpected, 'pinned notices')
    [IO.File]::WriteAllText($matchActual, 'pinned notices')
    Invoke-Test 'release file match accepts identical bytes and rejects missing or altered files' {
        Assert-ReleaseFileMatches -Expected $matchExpected -Actual $matchActual
        [IO.File]::WriteAllText($matchActual, 'changed notices')
        Assert-Throws { Assert-ReleaseFileMatches -Expected $matchExpected -Actual $matchActual } 'Release file differs from root source'
        Remove-Item -LiteralPath $matchActual
        Assert-Throws { Assert-ReleaseFileMatches -Expected $matchExpected -Actual $matchActual } 'Release file differs from root source'
        [IO.File]::WriteAllText($matchActual, 'pinned notices')
        Remove-Item -LiteralPath $matchExpected
        Assert-Throws { Assert-ReleaseFileMatches -Expected $matchExpected -Actual $matchActual } 'Release file differs from root source'
    }
    Invoke-Test 'release runtime folders cover every shared folder the sources read' {
        $repository = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        $read = @(Get-ChildItem -LiteralPath (Join-Path $repository 'apps/windows/src') -Recurse -File -Filter '*.cs' |
            Where-Object { $_.Name -notlike '*Probe*.cs' -and $_.FullName -notmatch '[\\/](obj|bin)[\\/]' } |
            Select-String -Pattern 'Path\.Combine\([^,()]*(?:\([^()]*\))?[^,()]*,\s*"([a-z-]+)"' -AllMatches -CaseSensitive |
            ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
            Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path $repository 'shared') $_) -PathType Container } |
            Sort-Object -Unique)
        foreach ($folder in @('caption-styles', 'catalog', 'data', 'fonts')) { if ($read -cnotcontains $folder) { throw "Source scan missed $folder." } }
        $runtimeFolders = Get-ReleaseRuntimeFolders
        foreach ($folder in $read) { if ($runtimeFolders -cnotcontains $folder) { throw "Release runtime folders omit $folder." } }
    }
    Invoke-Test 'current full package requires one exact Full entry for the RID' {
        $current = [pscustomobject]@{ Type = 'Full'; RelativeFileName = 'VoxClip-0.1.0-win-x64-full.nupkg' }
        $delta = [pscustomobject]@{ Type = 'Delta'; RelativeFileName = 'VoxClip-0.1.0-win-x64-delta.nupkg' }
        Assert-Equal (Get-ReleaseCurrentFullPackageName -Assets @($delta, $current) -Version 0.1.0 -RuntimeIdentifier win-x64) $current.RelativeFileName
        Assert-Throws { Get-ReleaseCurrentFullPackageName -Assets @($delta) -Version 0.1.0 -RuntimeIdentifier win-x64 } 'exactly one current full package'
        Assert-Throws { Get-ReleaseCurrentFullPackageName -Assets @([pscustomobject]@{ Type = 'Delta'; RelativeFileName = $current.RelativeFileName }) -Version 0.1.0 -RuntimeIdentifier win-x64 } 'exactly one current full package'
        Assert-Throws { Get-ReleaseCurrentFullPackageName -Assets @($current, $current) -Version 0.1.0 -RuntimeIdentifier win-x64 } 'exactly one current full package'
        Assert-Throws { Get-ReleaseCurrentFullPackageName -Assets @($current, [pscustomobject]@{ Type = 'Full'; RelativeFileName = 'VoxClip-0.1.0-win-arm64-full.nupkg' }) -Version 0.1.0 -RuntimeIdentifier win-x64 } 'exactly one current full package'
        Assert-Throws { Get-ReleaseCurrentFullPackageName -Assets @($current) -Version 0.1.0 -RuntimeIdentifier win-arm64 } 'exactly one current full package'
    }
    $script:vendorPinTable = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../doc/dependency-notices-audit.md')) {
        if ($line -match '^\| `((?:setup|update|stub)_(?:x64|arm64)\.exe)` \| `([a-f0-9]{64})` \|$') {
            $script:vendorPinTable[$Matches[1]] = $Matches[2]
        }
    }
    Assert-Equal $script:vendorPinTable.Count 6
    $toolFixture = Join-Path $temporary 'vpk-tool'
    $vendorFixture = Join-Path $toolFixture 'vpk/vendor'
    New-Item -ItemType Directory -Force -Path $vendorFixture | Out-Null
    foreach ($name in $script:vendorPinTable.Keys) {
        [IO.File]::WriteAllText((Join-Path $vendorFixture $name), "pinned $name")
    }
    Invoke-Test 'pinned Velopack input check covers all six documented identities' {
        $script:mockedVendorHashNames = @()
        function Get-FileHash {
            param([string] $LiteralPath, [string] $Algorithm)
            Assert-Equal $Algorithm 'SHA256'
            $name = Split-Path -Leaf $LiteralPath
            if (-not $script:vendorPinTable.ContainsKey($name)) { throw "Unexpected fake hash path: $name" }
            $script:mockedVendorHashNames += $name
            $hash = if ([IO.File]::ReadAllText($LiteralPath) -ceq "pinned $name") { $script:vendorPinTable[$name] } else { '0' * 64 }
            return [pscustomobject]@{ Hash = $hash }
        }
        Assert-PinnedVelopackInputs -ToolDirectory $toolFixture
        Assert-Equal (@($script:mockedVendorHashNames | Sort-Object -Unique).Count) 6
    }
    Invoke-Test 'pinned Velopack input check rejects each altered or missing vendor file' {
        function Get-FileHash {
            param([string] $LiteralPath, [string] $Algorithm)
            Assert-Equal $Algorithm 'SHA256'
            $name = Split-Path -Leaf $LiteralPath
            $hash = if ([IO.File]::ReadAllText($LiteralPath) -ceq "pinned $name") { $script:vendorPinTable[$name] } else { '0' * 64 }
            return [pscustomobject]@{ Hash = $hash }
        }
        foreach ($name in $script:vendorPinTable.Keys) {
            $path = Join-Path $vendorFixture $name
            [IO.File]::WriteAllText($path, "altered $name")
            Assert-Throws { Assert-PinnedVelopackInputs -ToolDirectory $toolFixture } ([regex]::Escape("Pinned Velopack payload differs: $name"))
            Remove-Item -LiteralPath $path
            $pattern = if ($name -eq 'setup_x64.exe') { 'Expected one pinned Velopack vendor directory' } else { [regex]::Escape("Pinned Velopack payload differs: $name") }
            Assert-Throws { Assert-PinnedVelopackInputs -ToolDirectory $toolFixture } $pattern
            [IO.File]::WriteAllText($path, "pinned $name")
        }
    }
    Invoke-Test 'pinned Velopack input check rejects missing and ambiguous vendor directories' {
        Assert-Throws { Assert-PinnedVelopackInputs -ToolDirectory (Join-Path $temporary 'no-vpk-tool') } 'cannot find|does not exist|Expected one pinned Velopack vendor directory'
        $secondVendor = Join-Path $toolFixture 'other/vendor'
        New-Item -ItemType Directory -Force -Path $secondVendor | Out-Null
        [IO.File]::WriteAllText((Join-Path $secondVendor 'setup_x64.exe'), 'duplicate')
        Assert-Throws { Assert-PinnedVelopackInputs -ToolDirectory $toolFixture } 'Expected one pinned Velopack vendor directory'
    }
    $vmAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'vm-release.ps1'), [ref] $null, [ref] $null)
    $validation = $vmAst.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Assert-ReleaseSigningCredentials' }, $true)
    . ([scriptblock]::Create($validation.Extent.Text))
    $ffmpegCopy = $vmAst.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Copy-ReleaseFfmpeg' }, $true)
    . ([scriptblock]::Create($ffmpegCopy.Extent.Text))
    Invoke-Test 'credential validation rejects whitespace canonical values with valid aliases' {
        foreach ($canonical in @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')) {
            $fixture = New-TestSigningCredentials
            $fixture[$canonical] = '   '
            Assert-Throws { Assert-ReleaseSigningCredentials -Credentials $fixture } $canonical
        }
    }
    Invoke-Test 'credential validation uses aliases only for empty canonical values' {
        $fixture = New-TestSigningCredentials
        $fixture['AZURE_TENANT_ID'] = ''; $fixture['AZURE_CLIENT_ID'] = ''; $fixture['AZURE_CLIENT_SECRET'] = ''
        Assert-ReleaseSigningCredentials -Credentials $fixture
        Assert-Equal $fixture['AZURE_TENANT_ID'] 'fixture-alias'
        Assert-Equal $fixture['AZURE_CLIENT_ID'] 'fixture-alias'
        Assert-Equal $fixture['AZURE_CLIENT_SECRET'] 'fixture-alias'
    }
    Invoke-Test 'VM metadata validation accepts exact account profile and region boundaries' {
        foreach ($region in @('aa', 'abcdefgh')) {
            $fixture = New-TestSigningCredentials
            $fixture['AZURE_SIGNING_ACCOUNT'] = 'A1'
            $fixture['AZURE_SIGNING_PROFILE'] = 'Z' * 64
            $fixture['AZURE_SIGNING_ENDPOINT'] = "https://$region.codesigning.azure.net"
            Assert-ReleaseSigningCredentials -Credentials $fixture
        }
    }
    Invoke-Test 'VM metadata validation reports only invalid variable names' {
        $invalid = @{
            AZURE_SIGNING_ACCOUNT = @('', ' ', 'a', '-fixture', 'fixture_name', ('a' * 65), "fixture-account`n")
            AZURE_SIGNING_PROFILE = @('', ' ', 'a', '-fixture', 'fixture_name', ('a' * 65), "fixture-profile`n")
            AZURE_SIGNING_ENDPOINT = @('', 'http://neu.codesigning.azure.net', 'https://NEU.codesigning.azure.net', 'https://n.codesigning.azure.net', 'https://abcdefghi.codesigning.azure.net', 'https://neu.codesigning.azure.net/', 'https://neu.codesigning.azure.net.evil', "https://neu.codesigning.azure.net`n")
        }
        foreach ($name in $invalid.Keys) {
            foreach ($value in $invalid[$name]) {
                $fixture = New-TestSigningCredentials
                $fixture[$name] = $value
                Assert-Throws { Assert-ReleaseSigningCredentials -Credentials $fixture } ('\A' + [regex]::Escape($name) + '\z')
            }
        }
    }
    $script:repository = Join-Path $temporary 'ffmpeg-repository'
    $script:runDirectory = Join-Path $temporary 'ffmpeg-run'
    $stage = Join-Path $runDirectory 'ffmpeg'
    $fakeFetch = Join-Path $repository 'apps/windows/build/Fetch-Ffmpeg.ps1'
    New-Item -ItemType Directory -Force -Path $stage, (Split-Path -Parent $fakeFetch) | Out-Null
    [IO.File]::WriteAllText($fakeFetch, "throw 'fetch-reached'", [Text.Encoding]::ASCII)
    $names = @('shipping-win-x64.zip', 'FFmpeg-LICENSE.txt', 'FFmpeg-LICENSE.md', 'win-x64-FFmpeg-NOTICES.txt', 'win-x64-audit.json', 'BUILD.txt')
    foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path $stage $name), "fixture $name", [Text.Encoding]::ASCII) }
    $files = @{}
    foreach ($name in $names) {
        $path = Join-Path $stage $name
        $files[$name] = @{ size = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $script:configuration = [pscustomobject]@{ Commit = 'fixture-commit' }
    $receipt = @{ schema = 'voxclip-ffmpeg/2'; commit = $configuration.Commit; buildInputsSha256 = 'fixture-inputs'; files = $files }
    $receiptPath = Join-Path $stage 'stage.json'
    $pin = @{ schema = 'voxclip-ffmpeg/2'; buildInputsSha256 = 'fixture-inputs';
              builds = @{ 'win-x64' = @{ name = $names[0]; size = $files[$names[0]].size; sha256 = $files[$names[0]].sha256 } };
              configure = @{ 'win-x64' = '--enable-shared' }; license = 'LGPL version 2.1 or later';
              testTools = @{ 'win-x64' = @{ sha256 = 'other-test-hash' } } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $app = Join-Path $temporary 'ffmpeg-app'
    New-Item -ItemType Directory -Force -Path $app | Out-Null
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath
    Invoke-Test 'matching FFmpeg stage reaches the mocked ZIP consumer' {
        Assert-Throws { Copy-ReleaseFfmpeg -Rid win-x64 -AppDirectory $app -Pin $pin } 'fetch-reached'
    }
    Invoke-Test 'VM rejects FFmpeg stage receipt commit and input digest mismatches' {
        foreach ($field in @('commit', 'buildInputsSha256')) {
            $saved = $receipt[$field]
            try {
                $receipt[$field] = 'wrong'
                $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath
                Assert-Throws { Copy-ReleaseFfmpeg -Rid win-x64 -AppDirectory $app -Pin $pin } 'stage does not match'
            } finally { $receipt[$field] = $saved }
        }
        $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath
    }
    Invoke-Test 'VM rejects altered staged FFmpeg files and ZIP pins' {
        $path = Join-Path $stage $names[1]
        try {
            [IO.File]::AppendAllText($path, 'changed')
            Assert-Throws { Copy-ReleaseFfmpeg -Rid win-x64 -AppDirectory $app -Pin $pin } 'staged evidence differs'
        } finally { [IO.File]::WriteAllText($path, "fixture $($names[1])", [Text.Encoding]::ASCII) }
        $saved = $pin.builds.'win-x64'.sha256
        try {
            $pin.builds.'win-x64'.sha256 = '0' * 64
            Assert-Throws { Copy-ReleaseFfmpeg -Rid win-x64 -AppDirectory $app -Pin $pin } 'ZIP differs from the self-built'
        } finally { $pin.builds.'win-x64'.sha256 = $saved }
    }
    Invoke-Test 'VM refuses a test-only FFmpeg ZIP even with matching stage evidence' {
        $pin.testTools.'win-x64'.sha256 = $pin.builds.'win-x64'.sha256
        Assert-Throws { Copy-ReleaseFfmpeg -Rid win-x64 -AppDirectory $app -Pin $pin } 'Test-only FFmpeg ZIP cannot ship'
    }
    Invoke-Test 'delta download uses the exact credential-free channel command' {
        $script:downloadExitCode = 0; $script:requests = @()
        Get-ReleaseDeltaBase -Vpk Invoke-FakeVpk -RuntimeIdentifier win-x64 -OutputDirectory $temporary
        Assert-Equal ($script:downloadArguments -join '|') "download|github|--repoUrl|https://github.com/Siim/voxclip|--channel|win-x64|-o|$temporary"
        Assert-Equal $script:requests.Count 0
    }
    Invoke-Test 'only a confirmed first release tolerates download failure' {
        $script:downloadExitCode = 1; $script:releaseStatus = 404; $script:requests = @()
        Get-ReleaseDeltaBase -Vpk Invoke-FakeVpk -RuntimeIdentifier win-arm64 -OutputDirectory $temporary
        Assert-Equal ($script:requests -join '|') 'https://api.github.com/repos/Siim/voxclip/releases/latest|https://api.github.com/repos/Siim/voxclip'
    }
    Invoke-Test 'a published release makes download failure fatal' {
        $script:downloadExitCode = 1; $script:releaseStatus = 200; $script:requests = @()
        Assert-Throws { Get-ReleaseDeltaBase -Vpk Invoke-FakeVpk -RuntimeIdentifier win-x64 -OutputDirectory $temporary } 'existing published release'
    }
    Invoke-Test 'GitHub errors are not treated as a first release' {
        $script:downloadExitCode = 1; $script:releaseStatus = 503; $script:requests = @()
        Assert-Throws { Get-ReleaseDeltaBase -Vpk Invoke-FakeVpk -RuntimeIdentifier win-x64 -OutputDirectory $temporary } 'Cannot establish'
    }
    $global:releaseOwnerCertificate = New-TestCertificate 'CN=Haugas Development OU'
    $otherCertificate = New-TestCertificate 'CN=Example Publisher'
    $global:releaseSignatures = @{}
    $rfcPath = Join-Path $temporary 'rfc3161.exe'
    $legacyPath = Join-Path $temporary 'legacy.exe'
    $unsignedPath = Join-Path $temporary 'untimestamped.exe'
    New-TestPe -Path $rfcPath -TimestampOid '1.3.6.1.4.1.311.3.3.1'
    New-TestPe -Path $legacyPath -TimestampOid '1.2.840.113549.1.9.6'
    New-TestPe -Path $unsignedPath
    foreach ($path in @($rfcPath, $legacyPath, $unsignedPath)) {
        $global:releaseSignatures[$path] = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $global:releaseOwnerCertificate; TimeStamperCertificate = $otherCertificate }
    }
    $global:releaseSignatures[$unsignedPath].TimeStamperCertificate = $null
    Invoke-Test 'RFC 3161 parser rejects legacy and absent timestamp attributes' {
        Assert-Equal (Test-ReleaseRfc3161Timestamp $rfcPath) $true
        Assert-Equal (Test-ReleaseRfc3161Timestamp $legacyPath) $false
        Assert-Equal (Test-ReleaseRfc3161Timestamp $unsignedPath) $false
    }
    Invoke-Test 'owned signatures require RFC 3161 even when Authenticode is Valid' {
        Assert-Equal (Test-ReleaseSignature $rfcPath Invoke-FakeSignTool) $true
        Assert-Equal (Test-ReleaseSignature $legacyPath Invoke-FakeSignTool) $false
        Assert-Equal (Test-ReleaseSignature $unsignedPath Invoke-FakeSignTool) $false
        Assert-Equal (Test-ReleaseSigningRequired $rfcPath) $false
        Assert-Equal (Test-ReleaseSigningRequired $unsignedPath) $true
    }
    Invoke-Test 'third-party signatures are never queued for replacement' {
        $global:releaseSignatures[$legacyPath].SignerCertificate = $otherCertificate
        $global:releaseSignatures[$legacyPath].TimeStamperCertificate = $null
        Assert-Equal (Test-ReleaseSigningRequired $legacyPath) $false
        Assert-Equal (Test-ReleaseSignature $legacyPath Invoke-FakeSignTool) $true
        $global:releaseSignatures[$legacyPath].Status = 'HashMismatch'
        Assert-Equal (Test-ReleaseSigningRequired $legacyPath) $false
        Assert-Equal (Test-ReleaseSignature $legacyPath Invoke-FakeSignTool) $false
    }
    Invoke-Test 'signature evidence records the timestamp subject and type' {
        $report = Join-Path $temporary 'signatures.json'
        Assert-ReleaseSignatures -Paths $rfcPath -SignTool Invoke-FakeSignTool -ReportPath $report
        $records = @(Get-Content $report -Raw | ConvertFrom-Json)
        Assert-Equal $records[0].timestampSubject $otherCertificate.Subject
        Assert-Equal $records[0].rfc3161Timestamp $true
        Assert-Throws { Assert-ReleaseSignatures -Paths $unsignedPath -SignTool Invoke-FakeSignTool } 'Signature verification failed'
    }
    Invoke-Test 'signer resumes an owned valid signature without replacing third-party files' {
        $fakeTool = Join-Path $temporary 'sign-tool.ps1'
        [IO.File]::WriteAllText($fakeTool, @'
if ($args[0] -eq 'sign') {
    foreach ($file in @($args | Where-Object { $_ -like '*.exe' })) {
        $global:releaseSignedPaths += $file
        [IO.File]::WriteAllBytes($file, $global:releaseTimestampedBytes)
        $global:releaseSignatures[$file].TimeStamperCertificate = $global:releaseOwnerCertificate
    }
}
$global:LASTEXITCODE = 0
'@)
        $global:releaseSignedPaths = @()
        $global:releaseTimestampedBytes = [IO.File]::ReadAllBytes($rfcPath)
        $global:releaseSignatures[$legacyPath].Status = 'Valid'
        $oldVariables = @{}
        try {
            foreach ($name in @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')) {
                $oldVariables[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, 'fixture-only', 'Process')
            }
            & (Join-Path $PSScriptRoot 'Sign-Artifacts.ps1') -SignTool $fakeTool -Dlib $fakeTool -Metadata $fakeTool -Paths @($unsignedPath, $legacyPath)
            Assert-Equal $global:releaseSignedPaths.Count 1
            Assert-Equal $global:releaseSignedPaths[0] $unsignedPath
        } finally {
            foreach ($name in $oldVariables.Keys) { [Environment]::SetEnvironmentVariable($name, $oldVariables[$name], 'Process') }
        }
    }
    Invoke-Test 'CLI version matches exactly for both installer architectures' {
        Assert-ReleaseCliVersion -Actual 'VoxClip 0.1.0 (windows-x64)' -Version '0.1.0' -RuntimeIdentifier win-x64
        Assert-ReleaseCliVersion -Actual 'VoxClip 0.1.0 (windows-arm64)' -Version '0.1.0' -RuntimeIdentifier win-arm64
        foreach ($actual in @('VoxClip 10.1.0 (windows-x64)', 'VoxClip 0.1.0-beta.1 (windows-x64)', 'VoxClip 0.1.0 (windows-arm64)')) {
            Assert-Throws { Assert-ReleaseCliVersion -Actual $actual -Version '0.1.0' -RuntimeIdentifier win-x64 } 'version/architecture'
        }
    }
    Invoke-Test 'signtool discovery selects the numerically newest supported x64 SDK' {
        $kits = Join-Path $temporary 'kits-newest'; $profile = Join-Path $temporary 'profile-newest'
        foreach ($version in @('10.0.26099.0', '10.0.26100.0', '10.0.90000.0', 'not-a-version')) {
            $null = New-TestSignTool $kits "$version/x64/signtool.exe"
        }
        $expected = New-TestSignTool $kits '10.0.100000.0/x64/signtool.exe'
        $null = New-TestSignTool $kits '11.0.0.0/x86/signtool.exe'
        $null = New-TestSignTool $profile '.dotnet/tools/.store/azuretrustedsigntool/1.3.13/azuretrustedsigntool/1.3.13/tools/net8.0/any/Sdk/signtool.exe'
        Assert-Equal (Resolve-ReleaseSignTool -WindowsKitsRoot $kits -UserProfile $profile).path $expected
    }
    Invoke-Test 'signtool override wins and a missing override never silently falls back' {
        $kits = Join-Path $temporary 'kits-override'
        $null = New-TestSignTool $kits '10.0.26100.0/x64/signtool.exe'
        $expected = New-TestSignTool $temporary 'override/signtool.exe'
        Assert-Equal (Resolve-ReleaseSignTool -Override $expected -WindowsKitsRoot $kits -UserProfile $temporary).path $expected
        Assert-Throws { Resolve-ReleaseSignTool -Override ($expected + '-missing') -WindowsKitsRoot $kits -UserProfile $temporary } 'Override not found'
    }
    Invoke-Test 'signtool falls back only to the pinned user-profile tool bundle' {
        $kits = Join-Path $temporary 'kits-fallback'; $profile = Join-Path $temporary 'profile-fallback'
        $null = New-TestSignTool $kits '10.0.26099.0/x64/signtool.exe'
        $null = New-TestSignTool $kits '10.0.26100.0/x86/signtool.exe'
        $other = New-TestSignTool $profile '.dotnet/tools/.store/azuretrustedsigntool/1.3.14/azuretrustedsigntool/1.3.14/tools/net8.0/any/Sdk/signtool.exe'
        Assert-Throws { Resolve-ReleaseSignTool -WindowsKitsRoot $kits -UserProfile $profile } 'Windows Kits 10.0.26100.*AzureTrustedSignTool 1.3.13'
        $expected = New-TestSignTool $profile '.dotnet/tools/.store/azuretrustedsigntool/1.3.13/azuretrustedsigntool/1.3.13/tools/net8.0/any/Sdk/signtool.exe'
        Assert-Equal (Resolve-ReleaseSignTool -WindowsKitsRoot $kits -UserProfile $profile).path $expected
        Assert-Equal (Test-Path -LiteralPath $other) $true
    }
    Invoke-Test 'signtool discovery uses the VM profile and Windows Kits environment roots' {
        $oldKits = ${env:ProgramFiles(x86)}; $oldProfile = $env:USERPROFILE
        try {
            ${env:ProgramFiles(x86)} = Join-Path $temporary 'programfiles-fixture'
            $env:USERPROFILE = Join-Path $temporary 'vm-profile-fixture'
            $expected = New-TestSignTool ${env:ProgramFiles(x86)} 'Windows Kits/10/bin/10.0.26100/x64/signtool.exe'
            Assert-Equal (Resolve-ReleaseSignTool).path $expected
            Remove-Item -LiteralPath $expected
            $expected = New-TestSignTool $env:USERPROFILE '.dotnet/tools/.store/azuretrustedsigntool/1.3.13/azuretrustedsigntool/1.3.13/tools/net8.0/any/Sdk/signtool.exe'
            Assert-Equal (Resolve-ReleaseSignTool).path $expected
        } finally {
            ${env:ProgramFiles(x86)} = $oldKits; $env:USERPROFILE = $oldProfile
        }
    }
    Invoke-Test 'signtool selection retains its chosen path and file version for VM evidence' {
        $expected = New-TestSignTool $temporary 'version-evidence/signtool.exe'
        function Get-Item {
            return [pscustomobject] @{ FullName = $expected; VersionInfo = [pscustomobject] @{ FileVersion = '10.0.26100.1234' } }
        }
        $selection = Resolve-ReleaseSignTool -Override $expected
        Assert-Equal $selection.path $expected
        Assert-Equal $selection.fileVersion '10.0.26100.1234'
        Assert-Equal $selection.machine '0x8664'
        $driver = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'vm-release.ps1'))
        Assert-Equal ($driver.Contains("'signing-tool.json'")) $true
        Assert-Equal ($driver.Contains('signTool = $signToolEvidence')) $true
        Assert-Equal ($driver.Contains('Resolve-ReleaseSignTool -Override $configuration.SignTool -Dlib $configuration.Dlib')) $true
    }
    Invoke-Test 'signtool and dlib evidence records matching x64 PE machines' {
        $tool = New-TestSignTool $temporary 'pe-evidence/signtool.exe'
        $dlib = New-TestSignTool $temporary 'pe-evidence/Azure.CodeSigning.Dlib.dll'
        $selection = Resolve-ReleaseSignTool -Override $tool -Dlib $dlib
        Assert-Equal $selection.machine '0x8664'
        Assert-Equal $selection.dlibMachine '0x8664'
        Assert-Equal $selection.dlibPath $dlib
    }
    Invoke-Test 'the pinned AzureTrustedSignTool bundle accepts the x64 dlib without an SDK' {
        $profile = Join-Path $temporary 'matching-store-profile'
        $tool = New-TestSignTool $profile '.dotnet/tools/.store/azuretrustedsigntool/1.3.13/azuretrustedsigntool/1.3.13/tools/net8.0/any/Sdk/signtool.exe'
        $dlib = New-TestSignTool $temporary 'matching-store-dlib/Azure.CodeSigning.Dlib.dll'
        $selection = Resolve-ReleaseSignTool -WindowsKitsRoot (Join-Path $temporary 'absent-kits') -UserProfile $profile -Dlib $dlib
        Assert-Equal $selection.path $tool
        Assert-Equal $selection.machine $selection.dlibMachine
        Assert-Equal $selection.dlibMachine '0x8664'
    }
    Invoke-Test 'signtool refuses mismatched ARM64 or x86 PE machines before signing' {
        $dlib = New-TestSignTool $temporary 'mismatched-dlib/Azure.CodeSigning.Dlib.dll'
        foreach ($machine in @(0xaa64, 0x014c)) {
            $tool = New-TestSignTool $temporary "mismatch-$machine/signtool.exe" -Machine $machine
            Assert-Throws { Resolve-ReleaseSignTool -Override $tool -Dlib $dlib } 'Signing prerequisite PE machine mismatch: signtool=0x[0-9a-f]+, dlib=0x8664'
        }
        $tool = New-TestSignTool $temporary 'x64-pair/signtool.exe'
        $armDlib = New-TestSignTool $temporary 'arm64-dlib/Azure.CodeSigning.Dlib.dll' -Machine 0xaa64
        Assert-Throws { Resolve-ReleaseSignTool -Override $tool -Dlib $armDlib } 'signtool=0x8664, dlib=0xaa64'
    }
    Invoke-Test 'PE prerequisite checks reject truncated headers and missing dlibs' {
        $tool = New-TestSignTool $temporary 'invalid-pe/signtool.exe'
        Assert-Throws { Resolve-ReleaseSignTool -Override $tool -Dlib (Join-Path $temporary 'missing-dlib.dll') } 'Signing prerequisite missing: dlib'
        foreach ($bytes in @([byte[]] @(0x4d, 0x5a), [byte[]]::new(128))) {
            [IO.File]::WriteAllBytes($tool, $bytes)
            Assert-Throws { Get-ReleasePeMachine -Path $tool } 'Signing prerequisite invalid PE image'
        }
        $tool = New-TestSignTool $temporary 'invalid-offset/signtool.exe'
        $bytes = [IO.File]::ReadAllBytes($tool)
        [BitConverter]::GetBytes([uint32] 4096).CopyTo($bytes, 0x3c)
        [IO.File]::WriteAllBytes($tool, $bytes)
        Assert-Throws { Get-ReleasePeMachine -Path $tool } 'Invalid PE header offset'
    }
    Invoke-Test 'install process matching includes updater and excludes neighboring roots' {
        $root = Join-Path $temporary 'process-fixture'
        function Get-Process {
            @([pscustomobject] @{ Id = 11; Path = (Join-Path $root 'Update.exe') },
              [pscustomobject] @{ Id = 12; Path = (Join-Path $root 'current/VoxClip.exe') },
              [pscustomobject] @{ Id = 13; Path = (Join-Path ($root + '-neighbor') 'Update.exe') })
        }
        Assert-Equal (@(Get-ReleaseInstallProcesses -InstallRoot $root).Id -join ',') '11,12'
    }
    Invoke-Test 'cleanup waits for a fake updater holding its own executable for three seconds' {
        $root = Join-Path $temporary 'updater-fixture'
        New-Item -ItemType Directory -Path $root | Out-Null
        $updater = Join-Path $root 'Update.exe'
        if ($env:OS -eq 'Windows_NT') {
            Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/ping.exe') -Destination $updater
            $arguments = '-n 4 127.0.0.1'
        } else {
            Copy-Item -LiteralPath '/bin/sleep' -Destination $updater
            $arguments = '3'
        }
        $process = Start-Process -FilePath $updater -ArgumentList $arguments -PassThru -RedirectStandardOutput (Join-Path $temporary 'updater-output.txt')
        try {
            $root = Split-Path -Parent (Get-Process -Id $process.Id).Path
            $timer = [Diagnostics.Stopwatch]::StartNew()
            Assert-Equal (@(Get-ReleaseInstallProcesses -InstallRoot $root).Count) 1
            Wait-ReleaseInstallProcesses -InstallRoot $root
            if ($timer.Elapsed.TotalSeconds -lt 2.5) { throw 'Cleanup did not wait for the fake updater.' }
            Assert-Equal (Remove-ReleaseInstallDirectory -InstallRoot $root) 1
            Assert-Equal (Test-Path -LiteralPath $root) $false
        } finally {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
            $process.WaitForExit()
            $process.Dispose()
        }
    }
    Invoke-Test 'install process waiting has a bounded deadline' {
        function Get-ReleaseInstallProcesses { [pscustomobject] @{ Id = 11 } }
        Assert-Throws { Wait-ReleaseInstallProcesses -InstallRoot $temporary -TimeoutSeconds 0 } 'did not exit within 0 seconds'
    }
    Invoke-Test 'bounded installer calls redirect stdout and kill timed-out process trees' {
        $script:boundedProcess = $null; $script:taskkillArguments = @()
        function Start-Process {
            param($FilePath, $ArgumentList, [switch] $PassThru, $RedirectStandardOutput)
            $script:boundedProcess = Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -RedirectStandardOutput $RedirectStandardOutput
            return $script:boundedProcess
        }
        function taskkill.exe {
            $script:taskkillArguments = $args
            Stop-Process -Id ([int] $args[1]) -Force
            $global:LASTEXITCODE = 0
        }
        $executable = if ($env:OS -eq 'Windows_NT') { Join-Path $env:SystemRoot 'System32/ping.exe' } else { '/bin/sleep' }
        $arguments = if ($env:OS -eq 'Windows_NT') { '-n 31 127.0.0.1' } else { '30' }
        try {
            Assert-Throws { Invoke-ReleaseProcess -Executable $executable -Arguments $arguments -TimeoutSeconds 0 -StandardOutput (Join-Path $temporary 'bounded-output.txt') } 'Process exceeded 0 seconds'
            Assert-Equal ($script:taskkillArguments -join ' ') ("/PID " + $script:boundedProcess.Id + ' /T /F')
            Assert-Equal (Test-Path -LiteralPath (Join-Path $temporary 'bounded-output.txt')) $true
        } finally {
            if ($script:boundedProcess) {
                if (-not $script:boundedProcess.HasExited) { Stop-Process -Id $script:boundedProcess.Id -Force }
                $script:boundedProcess.WaitForExit(); $script:boundedProcess.Dispose()
            }
        }
    }
    Invoke-Test 'install directory deletion retries five times two seconds apart' {
        $script:removeCount = 0; $script:retryDelays = @(); $script:removeFailures = 2
        function Test-Path { return $true }
        function Remove-Item {
            $script:removeCount++
            if ($script:removeCount -le $script:removeFailures) { throw 'Fixture file is locked.' }
        }
        function Start-Sleep { param([int] $Seconds); $script:retryDelays += $Seconds }
        Assert-Equal (Remove-ReleaseInstallDirectory -InstallRoot $temporary) 3
        Assert-Equal ($script:retryDelays -join ',') '2,2'
        $script:removeCount = 0; $script:retryDelays = @(); $script:removeFailures = 5
        Assert-Throws { Remove-ReleaseInstallDirectory -InstallRoot $temporary } 'Fixture file is locked'
        Assert-Equal $script:removeCount 5
        Assert-Equal ($script:retryDelays -join ',') '2,2,2,2'
    }
    Invoke-Test 'install removal succeeds when the updater removes the folder between attempts' {
        $script:removeCount = 0; $script:gone = $false
        function Test-Path { return (-not $script:gone) }
        function Remove-Item { $script:removeCount++; throw 'Fixture file is locked.' }
        function Start-Sleep { $script:gone = $true }
        Assert-Equal (Remove-ReleaseInstallDirectory -InstallRoot $temporary) 1
        Assert-Equal $script:removeCount 1
    }
    Invoke-Test 'a failed app kill cannot skip bounded uninstall or directory removal' {
        $root = Join-Path $temporary 'kill-failure'
        New-Item -ItemType Directory -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'Update.exe'), 'fixture')
        $script:uninstallCalled = $false
        function Get-ReleaseInstallProcesses { [pscustomobject] @{ Id = 11; ProcessName = 'VoxClip' } }
        function Stop-Process { throw 'Fixture kill failure.' }
        function Wait-ReleaseInstallProcesses { }
        function Invoke-ReleaseProcess {
            param($Executable, $Arguments, $TimeoutSeconds)
            Assert-Equal $Arguments '--uninstall --silent'
            Assert-Equal $TimeoutSeconds 180
            $script:uninstallCalled = $true
            return [pscustomobject] @{ ExitCode = 0 }
        }
        $result = Invoke-ReleaseInstallCleanup -InstallRoot $root
        Assert-Equal $script:uninstallCalled $true
        Assert-Equal $result.cleanup.directoryRemoved $true
        Assert-Equal $result.errors.Count 1
        Assert-Equal $result.errors[0].Message 'Fixture kill failure.'
    }
    Invoke-Test 'timed-out install processes are stopped and recorded before removal' {
        $root = Join-Path $temporary 'wait-failure'
        New-Item -ItemType Directory -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'Update.exe'), 'fixture')
        $script:stopped = $false; $script:waits = @()
        function Get-ReleaseInstallProcesses {
            if (-not $script:stopped) { [pscustomobject] @{ Id = 12; ProcessName = 'Update' } }
        }
        function Stop-Process { param($Id); Assert-Equal $Id 12; $script:stopped = $true }
        function Invoke-ReleaseProcess { return [pscustomobject] @{ ExitCode = 0 } }
        function Wait-ReleaseInstallProcesses {
            param($InstallRoot, $TimeoutSeconds = 60)
            $script:waits += $TimeoutSeconds
            if (-not $script:stopped) { throw 'Fixture updater did not exit within 60 seconds.' }
        }
        $result = Invoke-ReleaseInstallCleanup -InstallRoot $root
        Assert-Equal ($script:waits -join ',') '60,10'
        Assert-Equal ($result.cleanup.processesKilled -join ',') '12'
        Assert-Equal $result.cleanup.processesExited $true
        Assert-Equal $result.cleanup.directoryRemoved $true
        Assert-Equal $result.errors[0].Message 'Fixture updater did not exit within 60 seconds.'
    }
    Invoke-Test 'pending cleanup touches every marked root but not other runs or installs' {
        $run = Join-Path $temporary 'marker-run'
        $otherRun = Join-Path $temporary 'other-marker-run'
        $script:cleaned = @()
        function Invoke-ReleaseInstallCleanup {
            param($InstallRoot)
            $script:cleaned += $InstallRoot
            return [pscustomobject] @{ errors = @() }
        }
        foreach ($rid in @('win-x64', 'win-arm64')) {
            foreach ($directory in @($run, $otherRun)) {
                $report = Join-Path $directory "out/evidence/$rid"
                New-Item -ItemType Directory -Force -Path $report | Out-Null
                $root = Join-Path ([IO.Path]::GetTempPath()) ('voxclip-install-' + [Guid]::NewGuid().ToString('N'))
                [IO.File]::WriteAllText((Join-Path $report 'install-root.json'), (@{ installRoot = $root } | ConvertTo-Json))
            }
        }
        $expected = @(Get-ChildItem (Join-Path $run 'out/evidence') -Recurse -Filter 'install-root.json' |
            ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).installRoot })
        Remove-ReleasePendingInstalls -RunDirectory $run
        Assert-Equal ($script:cleaned -join ',') ($expected -join ',')
        Assert-Equal (@(Get-ChildItem $run -Recurse -Filter 'install-root.json').Count) 0
        Assert-Equal (@(Get-ChildItem $otherRun -Recurse -Filter 'install-root.json').Count) 2
    }
    Invoke-Test 'pending cleanup preserves failed markers and rejects invalid roots' {
        $run = Join-Path $temporary 'failed-marker-run'
        $report = Join-Path $run 'out/evidence/win-x64'
        New-Item -ItemType Directory -Force -Path $report | Out-Null
        $marker = Join-Path $report 'install-root.json'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('voxclip-install-' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($marker, (@{ installRoot = $root } | ConvertTo-Json))
        function Invoke-ReleaseInstallCleanup { return [pscustomobject] @{ errors = @([Exception]::new('Fixture pending cleanup failure.')) } }
        Assert-Throws { Remove-ReleasePendingInstalls -RunDirectory $run } 'Fixture pending cleanup failure'
        Assert-Equal (Test-Path -LiteralPath $marker) $true
        [IO.File]::WriteAllText($marker, (@{ installRoot = $temporary } | ConvertTo-Json))
        Assert-Throws { Remove-ReleasePendingInstalls -RunDirectory $run } 'Refusing invalid install root'
        Assert-Equal (Test-Path -LiteralPath $marker) $true
    }
    $installFixture = Join-Path $temporary 'install-script-fixture'
    New-Item -ItemType Directory -Path $installFixture | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-Install.ps1') -Destination $installFixture
    $common = (Join-Path $PSScriptRoot 'Release-Common.ps1').Replace("'", "''")
    [IO.File]::WriteAllText((Join-Path $installFixture 'Release-Common.ps1'), ". '$common'`n" + @'
function Join-Path {
    param([string] $Path, [string] $ChildPath)
    if ($ChildPath -like 'voxclip-install-*' -and $env:OS -ne 'Windows_NT') {
        Push-Location -LiteralPath $Path
        try { $Path = (& /bin/pwd -P).Trim() } finally { Pop-Location }
    }
    Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
}
$script:fixtureScenario = $null
function Get-ReleaseVcRuntime {
    param([string] $RuntimeIdentifier)
    $after = $null -ne $script:fixtureScenario
    return @{ architecture=$RuntimeIdentifier.Substring(4); installed=($after -and $script:fixtureScenario -ne 'vc-runtime-missing'); version=if($after){'14.50.0.0'}else{$null}; registryView='fixture' }
}
function Assert-ReleaseSignatures {
    if ($script:fixtureScenario -in @('verification-fail', 'both-fail')) { throw 'Fixture original verification failure.' }
}
function Invoke-ReleaseProcess {
    param([string] $Executable, [string] $Arguments, [int] $TimeoutSeconds, [string] $StandardOutput)
    if ($Arguments -like '--silent --installto *') {
        $script:fixtureScenario = $Executable
        $root = [regex]::Match($Arguments, '--installto "([^"]+)"').Groups[1].Value
        $script:fixtureRoot = $root
        $global:fixtureGateEvents = @()
        $pending = Get-Content -LiteralPath (Join-Path $ReportDirectory 'install-root.json') -Raw | ConvertFrom-Json
        Assert-Equal $pending.installRoot $root
        Assert-Equal $TimeoutSeconds 300
        if ($Executable -eq 'install-fail') { throw 'Fixture install failure.' }
        foreach ($relative in @('Update.exe', 'VoxClip.exe', 'current/VoxClip.exe', 'current/voxclip-cli.exe', 'current/LICENSE',
            'current/THIRD_PARTY_NOTICES.md', 'current/licenses/FFmpeg-LICENSE.txt', 'current/licenses/FFmpeg-BUILD.txt')) {
            $path = Join-Path $root $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            $contents = if (($script:fixtureScenario -in @('notices-mismatch', 'notices-and-cleanup-fail') -and $relative -eq 'current/THIRD_PARTY_NOTICES.md') -or
                ($script:fixtureScenario -eq 'updater-mismatch' -and $relative -eq 'Update.exe') -or
                ($script:fixtureScenario -eq 'stub-mismatch' -and $relative -eq 'VoxClip.exe')) { 'altered fixture' } else { 'fixture' }
            [IO.File]::WriteAllText($path, $contents)
        }
    } elseif ($Arguments -eq 'version') {
        Assert-Equal $TimeoutSeconds 60
        if ($script:fixtureScenario -eq 'cli-timeout') { throw 'Fixture CLI exceeded 60 seconds.' }
        [IO.File]::WriteAllText($StandardOutput, 'VoxClip 0.1.0 (windows-x64)')
    } elseif ($Arguments -eq '--runtime-terms --json' -or $Arguments -like '--accept-runtime-terms * --json' -or $Arguments -like 'probe * --json') {
        Assert-Equal $TimeoutSeconds 60
        Assert-Equal $env:VOXCLIP_DATA_DIR (Join-Path $script:fixtureRoot 'runtime-terms-smoke')
        Assert-Equal (Test-Path -LiteralPath $env:VOXCLIP_DATA_DIR -PathType Container) $true
        $hash = 'a' * 64
        $receipt = Join-Path $env:VOXCLIP_DATA_DIR 'windows-runtime-agreement.txt'
        $stamp = "format=voxclip-windows-runtime-agreement/1`nsha256=$hash`n"
        $exitCode = 0
        if ($Arguments -eq '--runtime-terms --json') {
            $global:fixtureGateEvents += 'terms'
            $shownHash = if ($script:fixtureScenario -eq 'terms-hash-invalid') { 'invalid-hash' } else { $hash }
            $body = @{ ok = $true; command = 'runtime-terms'; output = "$shownHash`nFixture terms"; version = '0.1.0' }
        } elseif ($Arguments -like '--accept-runtime-terms * --json') {
            $global:fixtureGateEvents += 'accept'
            Assert-Equal $Arguments "--accept-runtime-terms $hash --json"
            [IO.File]::WriteAllText($receipt, $stamp)
            $body = @{ ok = $true; command = 'accept-runtime-terms'; output = $hash; version = '0.1.0' }
        } else {
            $probeIndex = @($global:fixtureGateEvents | Where-Object { $_ -like 'probe:*' }).Count
            $accepted = (Test-Path -LiteralPath $receipt -PathType Leaf) -and ([IO.File]::ReadAllText($receipt) -ceq $stamp)
            if ($script:fixtureScenario -in @('terms-gate-bypass', 'terms-gate-and-cleanup-fail') -and $probeIndex -eq 0) { $accepted = $true }
            if ($script:fixtureScenario -eq 'terms-missing-recheck-bypass' -and $probeIndex -eq 2) { $accepted = $true }
            if ($script:fixtureScenario -eq 'terms-corrupt-recheck-bypass' -and $probeIndex -eq 3) { $accepted = $true }
            $exitCode = if ($accepted) { 3 } else { 7 }
            $code = if ($accepted) { 'mediaMissing' } else { 'runtimeTermsRequired' }
            $global:fixtureGateEvents += "probe:$exitCode"
            $body = @{ ok = $false; command = 'probe'; error = @{ code = $code; message = 'Fixture gate result.' }; version = '0.1.0' }
        }
        [IO.File]::WriteAllText($StandardOutput, ($body | ConvertTo-Json -Compress))
        return [pscustomobject] @{ ExitCode = $exitCode }
    } else {
        Assert-Equal $Arguments '--uninstall --silent'
        Assert-Equal $TimeoutSeconds 180
        Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $Executable) 'current') -Recurse -Force
        if ($script:fixtureScenario -in @('cleanup-fail', 'both-fail', 'notices-and-cleanup-fail', 'terms-gate-and-cleanup-fail')) { throw 'Fixture cleanup failure.' }
        if ($script:fixtureScenario -eq 'success') {
            if ($env:OS -eq 'Windows_NT') {
                Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/ping.exe') -Destination $Executable -Force
                $arguments = '-n 4 127.0.0.1'
            } else {
                Copy-Item -LiteralPath '/bin/sleep' -Destination $Executable -Force
                $arguments = '3'
            }
            $global:fixtureProcesses += Start-Process -FilePath $Executable -ArgumentList $arguments -PassThru -RedirectStandardOutput (Join-Path $ReportDirectory 'updater-output.txt')
        }
    }
    return [pscustomobject] @{ ExitCode = 0 }
}
'@, [Text.Encoding]::ASCII)
    $oldLocalAppData = $env:LOCALAPPDATA
    $oldDataDirectory = $env:VOXCLIP_DATA_DIR
    $global:fixtureProcesses = @()
    $expectedNotice = Join-Path $temporary 'expected-notices.txt'
    [IO.File]::WriteAllText($expectedNotice, 'fixture')
    $expectedPayloadHash = (Get-FileHash -LiteralPath $expectedNotice -Algorithm SHA256).Hash
    try {
        $env:LOCALAPPDATA = Join-Path $temporary 'user-data-fixture'
        foreach ($scenario in @('success', 'install-fail', 'verification-fail', 'cleanup-fail', 'both-fail', 'cli-timeout',
            'notices-mismatch', 'updater-mismatch', 'stub-mismatch', 'notices-and-cleanup-fail', 'terms-hash-invalid',
            'terms-gate-bypass', 'terms-missing-recheck-bypass', 'terms-corrupt-recheck-bypass', 'terms-gate-and-cleanup-fail', 'vc-runtime-missing')) {
            Invoke-Test "install evidence survives $scenario and preserves the first error" {
                $report = Join-Path $temporary ("install-report-" + $scenario)
                $failure = $null
                $script:fixtureScenario = $null
                $timer = [Diagnostics.Stopwatch]::StartNew()
                try {
                    & (Join-Path $installFixture 'Test-Install.ps1') -Setup $scenario -SignTool fixture -Version 0.1.0 -RuntimeIdentifier win-x64 -ReportDirectory $report -ExpectedNotices $expectedNotice -PackagedUpdaterHash $expectedPayloadHash -PackagedStubHash $expectedPayloadHash
                } catch { $failure = $_.Exception }
                $receipt = Get-Content -LiteralPath (Join-Path $report 'install-test.json') -Raw | ConvertFrom-Json
                Assert-Equal $receipt.success ($scenario -eq 'success')
                Assert-Equal ([bool] $failure) ($scenario -ne 'success')
                Assert-Equal $receipt.cleanup.directoryRemoved $true
                Assert-Equal $receipt.cleanup.userDataPreserved $true
                Assert-Equal $receipt.cleanup.processesExited $true
                Assert-Equal $receipt.cleanup.attempted ($scenario -ne 'install-fail')
                Assert-Equal $receipt.cleanup.removalAttempts $(if ($scenario -eq 'install-fail') { 0 } else { 1 })
                Assert-Equal $receipt.cleanup.errors.Count $(if ($scenario -in @('cleanup-fail', 'both-fail', 'notices-and-cleanup-fail', 'terms-gate-and-cleanup-fail')) { 1 } else { 0 })
                Assert-Equal (Test-Path -LiteralPath (Join-Path $report 'install-root.json')) ($scenario -in @('cleanup-fail', 'both-fail', 'notices-and-cleanup-fail', 'terms-gate-and-cleanup-fail'))
                if ($scenario -eq 'success' -and $timer.Elapsed.TotalSeconds -lt 2.5) { throw 'Test-Install did not wait for its updater.' }
                if ($scenario -eq 'success') { Assert-Equal ($global:fixtureGateEvents -join '|') 'terms|probe:7|accept|probe:3|probe:7|accept|probe:7' }
                Assert-Equal $env:VOXCLIP_DATA_DIR $oldDataDirectory
                if ($scenario -eq 'vc-runtime-missing') { Assert-Equal $receipt.error 'Microsoft VC++ runtime 14.44 or newer is required for x64.' }
                if ($scenario -eq 'success') { Assert-Equal $receipt.vcRuntimeBefore.installed $false; Assert-Equal $receipt.vcRuntimeAfter.version '14.50.0.0' }
                if ($scenario -eq 'cli-timeout') { Assert-Equal $failure.Message 'Fixture CLI exceeded 60 seconds.' }
                $mismatchErrors = @{
                    'notices-mismatch' = 'Release file differs from root source'
                    'updater-mismatch' = 'Installed Update.exe differs from packaged Squirrel.exe.'
                    'stub-mismatch' = 'Installed execution stub differs from the full package.'
                    'notices-and-cleanup-fail' = 'Release file differs from root source'
                }
                if ($mismatchErrors.ContainsKey($scenario)) {
                    Assert-Equal ($receipt.error.StartsWith($mismatchErrors[$scenario], [StringComparison]::Ordinal)) $true
                    Assert-Equal ($failure.Message.Contains($mismatchErrors[$scenario])) $true
                    Assert-Equal $receipt.cleanup.attempted $true
                    Assert-Equal $receipt.cleanup.directoryRemoved $true
                }
                if ($scenario -eq 'both-fail') {
                    $expected = "Installer verification or cleanup failed for win-x64 (install root $($receipt.installRoot)): Fixture original verification failure. | Fixture cleanup failure."
                    Assert-Equal ($failure.Message.StartsWith($expected, [StringComparison]::Ordinal)) $true
                    Assert-Equal $failure.InnerExceptions.Count 2
                    Assert-Equal $failure.InnerExceptions[0].Message 'Fixture original verification failure.'
                    Assert-Equal $failure.InnerExceptions[1].Message 'Fixture cleanup failure.'
                    Assert-Equal $receipt.error 'Fixture original verification failure.'
                }
                if ($scenario -eq 'notices-and-cleanup-fail') {
                    Assert-Equal $failure.InnerExceptions.Count 2
                    Assert-Equal ($failure.InnerExceptions[0].Message.StartsWith('Release file differs from root source', [StringComparison]::Ordinal)) $true
                    Assert-Equal $failure.InnerExceptions[1].Message 'Fixture cleanup failure.'
                }
                if ($scenario -eq 'terms-hash-invalid') { Assert-Equal $receipt.error 'Packaged CLI runtime terms output lacks a SHA-256 first line.' }
                if ($scenario -in @('terms-gate-bypass', 'terms-missing-recheck-bypass', 'terms-corrupt-recheck-bypass')) {
                    Assert-Equal $receipt.error 'Packaged CLI runtime gate returned an unexpected status for probe.'
                }
                if ($scenario -eq 'terms-gate-and-cleanup-fail') {
                    Assert-Equal $failure.InnerExceptions.Count 2
                    Assert-Equal $failure.InnerExceptions[0].Message 'Packaged CLI runtime gate returned an unexpected status for probe.'
                    Assert-Equal $failure.InnerExceptions[1].Message 'Fixture cleanup failure.'
                    Assert-Equal $receipt.error $failure.InnerExceptions[0].Message
                }
            }
        }
    } finally {
        $env:LOCALAPPDATA = $oldLocalAppData
        foreach ($process in $global:fixtureProcesses) {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
            $process.WaitForExit(); $process.Dispose()
        }
    }
    Invoke-Test 'atomic VM locks never remove another owner or ownerless locks' {
        $engine = (Get-Process -Id $PID).Path
        if ([IO.Path]::GetFileNameWithoutExtension($engine) -eq 'dotnet') { $engine = (Get-Command pwsh -ErrorAction Stop).Source }
        $lockScript = Join-Path $PSScriptRoot 'Release-Lock.ps1'
        $lockPath = Join-Path $temporary 'vm.lock'
        & $engine -NoProfile -NonInteractive -File $lockScript -Operation Acquire -Path $lockPath -RunId alpha
        Assert-Equal $LASTEXITCODE 0
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $lockPath 'owner'))) 'alpha'
        & $engine -NoProfile -NonInteractive -File $lockScript -Operation Acquire -Path $lockPath -RunId beta
        Assert-Equal $LASTEXITCODE 73
        Assert-Equal (Test-Path -LiteralPath "$lockPath.beta") $false
        & $engine -NoProfile -NonInteractive -File $lockScript -Operation Release -Path $lockPath -RunId beta
        Assert-Equal $LASTEXITCODE 74
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $lockPath 'owner'))) 'alpha'
        & $engine -NoProfile -NonInteractive -File $lockScript -Operation Release -Path $lockPath -RunId alpha
        Assert-Equal $LASTEXITCODE 0
        Assert-Equal (Test-Path -LiteralPath $lockPath) $false
        New-Item -ItemType Directory -Path $lockPath | Out-Null
        & $engine -NoProfile -NonInteractive -File $lockScript -Operation Release -Path $lockPath -RunId alpha
        Assert-Equal $LASTEXITCODE 74
        Assert-Equal (Test-Path -LiteralPath $lockPath) $true
    }
    Invoke-Test 'all release PowerShell scripts parse and stay ASCII-only' {
        foreach ($file in Get-ChildItem $PSScriptRoot -File -Filter '*.ps1') {
            if (@([IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count) { throw "Non-ASCII PowerShell: $($file.Name)" }
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
            if ($errors.Count) { throw "PowerShell parse failure: $($file.Name): $errors" }
        }
    }
    Write-Host "Release tooling: $script:testCount tests passed."
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
