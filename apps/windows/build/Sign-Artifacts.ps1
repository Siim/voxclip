param(
    [Parameter(Mandatory = $true)][string] $SignTool,
    [string] $Dlib,
    [string] $Metadata,
    [switch] $VerifyOnly,
    [string] $ReportPath,
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]] $Paths
)

. (Join-Path $PSScriptRoot 'Release-Common.ps1')
$oldDotnetRoot = $env:DOTNET_ROOT

try {
    if (-not $VerifyOnly) {
        if ($env:VOXCLIP_SIGNING_DOTNET_ROOT) { $env:DOTNET_ROOT = $env:VOXCLIP_SIGNING_DOTNET_ROOT }
        foreach ($name in @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')) {
            if (-not [Environment]::GetEnvironmentVariable($name, 'Process')) { throw "Missing signing variable: $name" }
        }
        foreach ($required in @($SignTool, $Dlib, $Metadata)) {
            if (-not $required -or -not (Test-Path -LiteralPath $required -PathType Leaf)) { throw 'Missing signing tool, dlib or metadata.' }
        }
        $pending = @(Get-ReleasePeFiles -Paths $Paths | Where-Object {
            Test-ReleaseSigningRequired -Path $_.FullName
        })
        Write-Host "PE signing inventory: $($pending.Count) files need a publisher signature."
        for ($offset = 0; $offset -lt $pending.Count; $offset += 50) {
            $last = [Math]::Min($offset + 49, $pending.Count - 1)
            $batch = @($pending[$offset..$last] | ForEach-Object { $_.FullName })
            $remaining = $batch
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $arguments = @('sign', '/fd', 'SHA256', '/tr', 'http://timestamp.acs.microsoft.com', '/td', 'SHA256', '/dlib', $Dlib, '/dmdf', $Metadata) + $remaining
                $previousPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    $output = (& $SignTool @arguments 2>&1 | Out-String)
                    $exitCode = $LASTEXITCODE
                } finally { $ErrorActionPreference = $previousPreference }
                foreach ($name in @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')) {
                    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
                    if ($value) { $output = $output.Replace($value, '[redacted]') }
                }
                $remaining = @($remaining | Where-Object { Test-ReleaseSigningRequired -Path $_ })
                if ($exitCode -eq 0 -and $remaining.Count -eq 0) { break }
                if ($exitCode -eq 0) { $output = 'Timestamp server returned no valid RFC 3161 timestamp.' }
                if ($attempt -eq 3 -or $output -notmatch '(?i)timestamp server|timed out|temporarily unavailable') {
                    Write-Host $output
                    throw "Artifact Signing failed ($exitCode). For AADSTS7000222 rotate the Entra client secret; for 403 check account/profile and signer role."
                }
                if ($remaining.Count -eq 0) { break }
                Write-Host "Transient signing/timestamp failure; retrying $($remaining.Count) files ($attempt/3)."
                Start-Sleep -Seconds (3 * $attempt)
            }
            Write-Host "Signed $($batch.Count) previously unverified PE files."
        }
    }
    Assert-ReleaseSignatures -Paths $Paths -SignTool $SignTool -ReportPath $ReportPath
} finally { $env:DOTNET_ROOT = $oldDotnetRoot }
