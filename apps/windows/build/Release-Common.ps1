Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ReleasePrerequisite {
    param([Parameter(Mandatory = $true)][ValidateSet('win-x64', 'win-arm64')][string] $RuntimeIdentifier)
    return 'vcredist145-' + $RuntimeIdentifier.Substring(4)
}

function Assert-ReleaseVcRuntime {
    param([Parameter(Mandatory = $true)] $Runtime)
    if (-not $Runtime.installed -or -not $Runtime.version -or [version] $Runtime.version -lt [version] '14.44.0') {
        throw "Microsoft VC++ runtime 14.44 or newer is required for $($Runtime.architecture)."
    }
}

function Get-ReleaseVcRuntime {
    param([Parameter(Mandatory = $true)][ValidateSet('win-x64', 'win-arm64')][string] $RuntimeIdentifier)
    $architecture = $RuntimeIdentifier.Substring(4)
    $best = @{ architecture = $architecture; installed = $false; version = $null; registryView = $null }
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        $key = $null
        try {
            $key = $base.OpenSubKey("SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$architecture")
            if ($null -eq $key -or $key.GetValue('Installed', 0) -ne 1) { continue }
            $version = $null
            if (-not [version]::TryParse(([string] $key.GetValue('Version', '')).TrimStart('v'), [ref] $version)) { continue }
            if (-not $best.installed -or $version -gt [version] $best.version) {
                $best = @{ architecture = $architecture; installed = $true; version = $version.ToString(); registryView = $view.ToString() }
            }
        } finally {
            if ($null -ne $key) { $key.Dispose() }
            $base.Dispose()
        }
    }
    return $best
}

function ConvertTo-ReleaseNativeArgument {
    param([AllowEmptyString()][string] $Value)
    # Windows argv quoting: double backslashes before a quote or the closing
    # delimiter. ProcessStartInfo bypasses PowerShell 5.1's legacy re-quoting.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-ReleaseTool {
    param([string] $Executable, [string[]] $Arguments)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.WorkingDirectory = (Get-Location).Path
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Arguments = ($Arguments | ForEach-Object { ConvertTo-ReleaseNativeArgument $_ }) -join ' '
    $process = [Diagnostics.Process]::Start($start)
    try {
        $nativeErrorRead = $process.StandardError.ReadToEndAsync()
        while ($null -ne ($nativeLine = $process.StandardOutput.ReadLine())) { Write-Output $nativeLine }
        $process.WaitForExit()
        $nativeErrorText = $nativeErrorRead.GetAwaiter().GetResult()
        if ($nativeErrorText.Length) { Write-Output $nativeErrorText.TrimEnd("`r", "`n") }
        if ($process.ExitCode -ne 0) { throw "Native command failed ($($process.ExitCode)): $Executable" }
    } finally { $process.Dispose() }
}

function Get-ReleaseDeltaBase {
    param([string] $Vpk, [ValidateSet('win-x64', 'win-arm64')][string] $RuntimeIdentifier, [string] $OutputDirectory)
    foreach ($name in @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')) {
        if ([Environment]::GetEnvironmentVariable($name, 'Process')) { throw 'Delta download must run without signing credentials.' }
    }
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    & $Vpk download github --repoUrl https://github.com/Siim/voxclip --channel $RuntimeIdentifier -o $OutputDirectory
    if ($LASTEXITCODE -eq 0) { return }
    $downloadExitCode = $LASTEXITCODE
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'VoxClip-release'; 'X-GitHub-Api-Version' = '2022-11-28' }
    try {
        $null = Invoke-RestMethod -Uri 'https://api.github.com/repos/Siim/voxclip/releases/latest' -Headers $headers -TimeoutSec 30
    } catch {
        if ($_.Exception.Response -and [int] $_.Exception.Response.StatusCode -eq 404) {
            $null = Invoke-RestMethod -Uri 'https://api.github.com/repos/Siim/voxclip' -Headers $headers -TimeoutSec 30
            Write-Host "No prior published release for $RuntimeIdentifier; no delta base is available."
            return
        }
        throw 'Cannot establish whether a prior release exists; refusing to ignore delta download failure.'
    }
    throw "Velopack delta download failed ($downloadExitCode) despite an existing published release."
}

function New-ReleaseAggregateException {
    param([string] $Message, [Exception[]] $Errors)
    $details = ($Errors | ForEach-Object { $_.Message }) -join ' | '
    return [AggregateException]::new(($Message + ': ' + $details), $Errors)
}

function Invoke-ReleaseProcess {
    param([string] $Executable, [string] $Arguments, [int] $TimeoutSeconds, [string] $StandardOutput)
    $parameters = @{ FilePath = $Executable; ArgumentList = $Arguments; PassThru = $true }
    if ($StandardOutput) { $parameters.RedirectStandardOutput = $StandardOutput }
    $process = Start-Process @parameters
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        & taskkill.exe /PID $process.Id /T /F | Out-Null
        throw "Process exceeded $TimeoutSeconds seconds: $Executable"
    }
    $process.Refresh()
    return $process
}

function Get-ReleasePeMachine {
    param([string] $Path)
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw 'Invalid DOS header.' }
        $stream.Position = 0x3c
        $offset = $reader.ReadUInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw 'Invalid PE header offset.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Invalid PE signature.' }
        $machine = $reader.ReadUInt16()
        if ($machine -eq 0) { throw 'Missing PE machine type.' }
        return $machine
    } catch {
        throw "Signing prerequisite invalid PE image: $Path ($($_.Exception.Message))"
    } finally { if ($stream) { $stream.Dispose() } }
}

function Resolve-ReleaseSignTool {
    param([string] $Override, [string] $WindowsKitsRoot, [string] $UserProfile = $env:USERPROFILE, [string] $Dlib)
    $prerequisite = 'Signing prerequisite missing: set VOXCLIP_VM_SIGNTOOL to an x64 signtool.exe, install Windows Kits 10.0.26100 or newer with x64 signtool.exe, or install AzureTrustedSignTool 1.3.13 in the user profile tool store.'
    $selected = $Override
    if ($Override -and -not (Test-Path -LiteralPath $Override -PathType Leaf)) { throw "$prerequisite Override not found: $Override" }
    if (-not $selected) {
        if (-not $WindowsKitsRoot -and ${env:ProgramFiles(x86)}) {
            $WindowsKitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
        }
        if ($WindowsKitsRoot -and (Test-Path -LiteralPath $WindowsKitsRoot -PathType Container)) {
            $candidates = @(foreach ($directory in Get-ChildItem -LiteralPath $WindowsKitsRoot -Directory) {
                $version = $null
                if ([version]::TryParse($directory.Name, [ref] $version) -and $version -ge [version] '10.0.26100') {
                    $path = Join-Path $directory.FullName 'x64\signtool.exe'
                    if (Test-Path -LiteralPath $path -PathType Leaf) { [pscustomobject] @{ version = $version; path = $path } }
                }
            })
            $newest = $candidates | Sort-Object version -Descending | Select-Object -First 1
            if ($newest) { $selected = $newest.path }
        }
        if (-not $selected -and $UserProfile) {
            $bundled = Join-Path $UserProfile '.dotnet\tools\.store\azuretrustedsigntool\1.3.13\azuretrustedsigntool\1.3.13\tools\net8.0\any\Sdk\signtool.exe'
            if (Test-Path -LiteralPath $bundled -PathType Leaf) { $selected = $bundled }
        }
    }
    if (-not $selected) { throw $prerequisite }
    $file = Get-Item -LiteralPath $selected
    $machine = Get-ReleasePeMachine -Path $file.FullName
    $dlibMachine = $null
    if ($Dlib) {
        if (-not (Test-Path -LiteralPath $Dlib -PathType Leaf)) { throw "Signing prerequisite missing: dlib not found: $Dlib" }
        $dlibMachine = Get-ReleasePeMachine -Path $Dlib
        if ($machine -ne $dlibMachine) {
            throw ('Signing prerequisite PE machine mismatch: signtool=0x{0:x4}, dlib=0x{1:x4}. Select tools with the same architecture.' -f $machine, $dlibMachine)
        }
    }
    return [pscustomobject] @{ path = $file.FullName; fileVersion = $file.VersionInfo.FileVersion; machine = ('0x{0:x4}' -f $machine); dlibPath = $Dlib; dlibMachine = $(if ($null -ne $dlibMachine) { '0x{0:x4}' -f $dlibMachine } else { $null }) }
}

function Get-ReleaseInstallProcesses {
    param([string] $InstallRoot)
    $prefix = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([char[]] @('\', '/')) + [IO.Path]::DirectorySeparatorChar
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { $path = $process.Path } catch { continue }
        if ($path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $process }
    }
}

function Wait-ReleaseInstallProcesses {
    param([string] $InstallRoot, [int] $TimeoutSeconds = 60)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (@(Get-ReleaseInstallProcesses -InstallRoot $InstallRoot).Count -gt 0) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Installed processes did not exit within $TimeoutSeconds seconds: $InstallRoot" }
        Start-Sleep -Milliseconds 200
    }
}

function Remove-ReleaseInstallDirectory {
    param([string] $InstallRoot, [int] $Attempts = 5, [int] $RetryDelaySeconds = 2)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (-not (Test-Path -LiteralPath $InstallRoot)) { return ($attempt - 1) }
        try {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction Stop
            return $attempt
        } catch {
            if (-not (Test-Path -LiteralPath $InstallRoot)) { return $attempt }
            if ($attempt -eq $Attempts) { throw }
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Invoke-ReleaseInstallCleanup {
    param([string] $InstallRoot)
    $errors = New-Object 'Collections.Generic.List[Exception]'
    $killed = New-Object 'Collections.Generic.List[int]'
    $cleanup = [ordered] @{ attempted = (Test-Path -LiteralPath $InstallRoot); uninstalled = $false; processesExited = $false; processesKilled = @(); removalAttempts = 0; directoryRemoved = $false; userDataPreserved = $true; errors = @() }
    foreach ($process in @(Get-ReleaseInstallProcesses -InstallRoot $InstallRoot)) {
        if ($process.ProcessName -ne 'VoxClip') { continue }
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $killed.Add($process.Id)
        } catch { $errors.Add($_.Exception) }
    }
    try {
        if ($cleanup.attempted) {
            $updater = Join-Path $InstallRoot 'Update.exe'
            if (-not (Test-Path -LiteralPath $updater)) { throw 'Partial smoke install has no uninstaller.' }
            $process = Invoke-ReleaseProcess -Executable $updater -Arguments '--uninstall --silent' -TimeoutSeconds 180
            if ($process.ExitCode -ne 0) { throw "Smoke-test uninstall failed ($($process.ExitCode))." }
            $cleanup.uninstalled = $true
        }
    } catch { $errors.Add($_.Exception) }
    try {
        Wait-ReleaseInstallProcesses -InstallRoot $InstallRoot
        $cleanup.processesExited = $true
    } catch {
        $errors.Add($_.Exception)
        foreach ($process in @(Get-ReleaseInstallProcesses -InstallRoot $InstallRoot)) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                $killed.Add($process.Id)
            } catch { $errors.Add($_.Exception) }
        }
        try {
            Wait-ReleaseInstallProcesses -InstallRoot $InstallRoot -TimeoutSeconds 10
            $cleanup.processesExited = $true
        } catch { $errors.Add($_.Exception) }
    }
    if (Test-Path -LiteralPath (Join-Path $InstallRoot 'current\VoxClip.exe')) {
        $cleanup.uninstalled = $false
        $errors.Add([Exception]::new('Uninstall left the application installed.'))
    }
    try {
        $cleanup.removalAttempts = Remove-ReleaseInstallDirectory -InstallRoot $InstallRoot
    } catch {
        $cleanup.removalAttempts = 5
        $errors.Add($_.Exception)
    }
    $cleanup.directoryRemoved = -not (Test-Path -LiteralPath $InstallRoot)
    $cleanup.processesKilled = $killed.ToArray()
    $cleanup.errors = @($errors | ForEach-Object { $_.Message })
    return [pscustomobject] @{ cleanup = $cleanup; errors = $errors.ToArray() }
}

function Remove-ReleasePendingInstalls {
    param([string] $RunDirectory)
    $evidence = Join-Path $RunDirectory 'out\evidence'
    if (-not (Test-Path -LiteralPath $evidence)) { return }
    $errors = New-Object 'Collections.Generic.List[Exception]'
    foreach ($marker in @(Get-ChildItem -LiteralPath $evidence -Recurse -File -Filter 'install-root.json')) {
        try {
            $record = Get-Content -LiteralPath $marker.FullName -Raw | ConvertFrom-Json
            $root = [IO.Path]::GetFullPath($record.installRoot)
            $parent = [IO.Path]::GetDirectoryName($root)
            $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]] @('\', '/'))
            if (-not $parent.Equals($temporary, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -cnotmatch '^voxclip-install-[0-9a-f]{32}$') {
                throw "Refusing invalid install root in run marker: $($marker.FullName)"
            }
            $result = Invoke-ReleaseInstallCleanup -InstallRoot $root
            if ($result.errors.Count) { throw (New-ReleaseAggregateException -Message "Pending install cleanup failed for $root" -Errors $result.errors) }
            Remove-Item -LiteralPath $marker.FullName -Force -ErrorAction Stop
        } catch { $errors.Add($_.Exception) }
    }
    if ($errors.Count) { throw (New-ReleaseAggregateException -Message 'Pending install cleanup failed' -Errors $errors.ToArray()) }
}

function Assert-ReleaseCliVersion {
    param([string] $Actual, [string] $Version, [ValidateSet('win-x64', 'win-arm64')][string] $RuntimeIdentifier)
    $architecture = $RuntimeIdentifier.Substring(4)
    if ($Actual -cne "VoxClip $Version (windows-$architecture)") { throw 'Installed CLI version/architecture check failed.' }
}

function Get-ReleasePeFiles {
    param([string[]] $Paths)
    foreach ($path in $Paths) {
        $files = if (Test-Path -LiteralPath $path -PathType Container) {
            Get-ChildItem -LiteralPath $path -Recurse -File
        } else { Get-Item -LiteralPath $path }
        foreach ($file in $files) {
            $stream = [IO.File]::OpenRead($file.FullName)
            try {
                if ($stream.Length -lt 64) { continue }
                $reader = New-Object IO.BinaryReader($stream)
                if ($reader.ReadUInt16() -ne 0x5a4d) { continue }
                $stream.Position = 0x3c
                $offset = $reader.ReadUInt32()
                if ($offset -gt ($stream.Length - 4)) { continue }
                $stream.Position = $offset
                if ($reader.ReadUInt32() -eq 0x00004550) { $file }
            } finally { $stream.Dispose() }
        }
    }
}

function Test-ReleaseOwnedSignature {
    param($Signature)
    if (-not $Signature.SignerCertificate) { return $false }
    $publisher = $Signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    $publisher = $publisher.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    return ($publisher -ieq 'Haugas Development OU')
}

function Test-ReleaseRfc3161Timestamp {
    param([string] $Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        $stream.Position = 0x3c
        $header = $reader.ReadUInt32()
        $stream.Position = $header + 24
        $magic = $reader.ReadUInt16()
        $directoryOffset = if ($magic -eq 0x10b) { 96 } elseif ($magic -eq 0x20b) { 112 } else { return $false }
        $stream.Position = $header + 24 + $directoryOffset + 32
        $certificateOffset = $reader.ReadUInt32()
        $certificateSize = $reader.ReadUInt32()
        if ($certificateOffset -eq 0 -or $certificateSize -lt 8 -or $certificateOffset + [long] $certificateSize -gt $stream.Length) { return $false }
        $stream.Position = $certificateOffset
        $length = $reader.ReadUInt32()
        $revision = $reader.ReadUInt16()
        $certificateType = $reader.ReadUInt16()
        if ($length -lt 8 -or $length -gt $certificateSize -or $revision -ne 0x200 -or $certificateType -ne 2) { return $false }
        Add-Type -AssemblyName System.Security
        $cms = New-Object Security.Cryptography.Pkcs.SignedCms
        $cms.Decode($reader.ReadBytes($length - 8))
        foreach ($signer in $cms.SignerInfos) {
            foreach ($attribute in $signer.UnsignedAttributes) {
                if ($attribute.Oid.Value -eq '1.3.6.1.4.1.311.3.3.1') { return $true }
            }
        }
        return $false
    } catch { return $false } finally { $stream.Dispose() }
}

function Test-ReleaseSigningRequired {
    param([string] $Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $owned = Test-ReleaseOwnedSignature -Signature $signature
    if ($signature.SignerCertificate -and -not $owned) { return $false }
    return ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate -or -not (Test-ReleaseRfc3161Timestamp -Path $Path))
}

function Test-ReleaseSignature {
    param([string] $Path, [string] $SignTool)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') { return $false }
    if ((Test-ReleaseOwnedSignature -Signature $signature) -and (-not $signature.TimeStamperCertificate -or -not (Test-ReleaseRfc3161Timestamp -Path $Path))) { return $false }
    & $SignTool verify /pa /all $Path *> $null
    return ($LASTEXITCODE -eq 0)
}

function Assert-ReleaseSignatures {
    param([string[]] $Paths, [string] $SignTool, [string] $ReportPath)
    $records = @()
    $files = @(Get-ReleasePeFiles -Paths $Paths)
    if ($files.Count -eq 0) { throw 'No PE files found for signature verification.' }
    foreach ($file in $files) {
        if (-not (Test-ReleaseSignature -Path $file.FullName -SignTool $SignTool)) {
            throw "Signature verification failed: $($file.FullName)"
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        $records += [ordered]@{
            path = $file.FullName
            subject = $signature.SignerCertificate.Subject
            thumbprint = $signature.SignerCertificate.Thumbprint
            timestampSubject = if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Subject } else { $null }
            rfc3161Timestamp = Test-ReleaseRfc3161Timestamp -Path $file.FullName
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    if ($ReportPath) {
        [IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $records -Depth 5), (New-Object Text.UTF8Encoding($false)))
    }
    Write-Host "Verified $($records.Count) PE signatures with signtool verify /pa /all."
}

function Set-ReleasePrivateAcl {
    param([string] $Path)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void] $acl.RemoveAccessRuleAll($rule) }
    $inheritance = if (Test-Path -LiteralPath $Path -PathType Container) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    foreach ($principal in @($identity, 'NT AUTHORITY\SYSTEM')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($principal, 'FullControl', $inheritance, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-ReleaseRuntimeFolders {
    # The shared folders a release ships; test-release-tools.ps1 checks they cover every folder the sources read.
    return @('caption-styles', 'catalog', 'data', 'design', 'fonts', 'prompts', 'schemas')
}

function Assert-ReleaseResources {
    param([string] $Repository, [string] $AppDirectory)
    $runtimeFolders = Get-ReleaseRuntimeFolders
    $destination = Join-Path $AppDirectory 'shared'
    if (Test-Path $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    New-Item -ItemType Directory -Path $destination | Out-Null
    foreach ($folder in $runtimeFolders) {
        $source = Join-Path $Repository "shared\$folder"
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
        foreach ($file in Get-ChildItem $source -Recurse -File) {
            $relative = $file.FullName.Substring($source.Length).TrimStart('\')
            $copy = Join-Path (Join-Path $destination $folder) $relative
            if ((Get-FileHash $file.FullName).Hash -ne (Get-FileHash $copy).Hash) {
                throw "Shared resource copy differs: $folder\$relative"
            }
        }
    }
    foreach ($notice in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) {
        Copy-Item -LiteralPath (Join-Path $Repository $notice) -Destination $AppDirectory -Force
    }
}

function Assert-ReleaseFileMatches {
    param([string] $Expected, [string] $Actual)
    if (-not (Test-Path -LiteralPath $Expected -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Actual -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Expected -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $Actual -Algorithm SHA256).Hash) {
        throw "Release file differs from root source: $Actual"
    }
}

function Get-ReleaseCurrentFullPackageName {
    param([object[]] $Assets, [string] $Version, [string] $RuntimeIdentifier)
    $expected = "VoxClip-$Version-$RuntimeIdentifier-full.nupkg"
    $full = @($Assets | Where-Object { $_.Type -eq 'Full' })
    $named = @($Assets | Where-Object { $_.RelativeFileName -ceq $expected })
    if ($full.Count -ne 1 -or $named.Count -ne 1 -or
        $full[0].RelativeFileName -cne $expected -or $named[0].Type -cne 'Full') {
        throw "Expected exactly one current full package in assets.$RuntimeIdentifier.json."
    }
    return $expected
}

function Assert-PinnedVelopackInputs {
    param([string] $ToolDirectory)
    # SHA-256 of the six Windows payload inputs in the vpk 1.2.161 NuGet archive.
    $pins = @{
        'setup_x64.exe' = 'b4bac7fed188b173d36bac27f59376dfcac59c8db3f830858772b244c2308cab'
        'setup_arm64.exe' = '390662ca2c1b4277c7200447a27ea1ba10fe7c5201d64f4dd5b11e00529066ee'
        'update_x64.exe' = 'acefb4a2cb46cc77ed3c2364db17f8bd2a25e2197cfeae56cd85e88a7ac21ac5'
        'update_arm64.exe' = '260fb897a8c2c3a23fc7ab71d52938d5c757d585b26a496981d549d51c78c5ff'
        'stub_x64.exe' = '405517cdd4fb8d106ada4ce1fd834b583b46c3a3e2a9da12b2d3c4b6d69999b5'
        'stub_arm64.exe' = '51c7db95ae8c85e8edbd92c328c0a468ec4fdbec55bd675e9445afcf3789b2ae'
    }
    $vendorCandidates = @(Get-ChildItem -LiteralPath $ToolDirectory -Filter 'setup_x64.exe' -Recurse -File -Force)
    if ($vendorCandidates.Count -ne 1 -or (Split-Path -Leaf $vendorCandidates[0].DirectoryName) -ne 'vendor') {
        throw 'Expected one pinned Velopack vendor directory in the installed vpk tool.'
    }
    foreach ($name in $pins.Keys) {
        $file = Join-Path $vendorCandidates[0].DirectoryName $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $pins[$name]) {
            throw "Pinned Velopack payload differs: $name"
        }
    }
}
