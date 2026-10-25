param([ValidateSet('Acquire', 'Check', 'Release', 'Describe')][string] $Operation, [string] $Path, [string] $RunId)
$ErrorActionPreference = 'Stop'
$ownerPath = Join-Path $Path 'owner'
if ($Operation -eq 'Acquire') {
    $candidate = "$Path.$RunId"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    New-Item -ItemType Directory -Path $candidate | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $candidate 'owner'), $RunId, [Text.Encoding]::ASCII)
        try { [IO.Directory]::Move($candidate, $Path) } catch {
            if (-not (Test-Path -LiteralPath $Path)) { throw }
            $owner = if (Test-Path -LiteralPath $ownerPath) { ([IO.File]::ReadAllText($ownerPath)).Trim() } else { '<missing>' }
            $age = [Math]::Round(([DateTime]::UtcNow - (Get-Item -LiteralPath $Path).CreationTimeUtc).TotalSeconds)
            Write-Host "VM lock held: owner=$owner; age=${age}s. No automatic takeover."
            exit 73
        }
    } finally {
        if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force }
    }
} elseif ($Operation -eq 'Describe') {
    if (Test-Path -LiteralPath $Path) {
        $owner = if (Test-Path -LiteralPath $ownerPath) { ([IO.File]::ReadAllText($ownerPath)).Trim() } else { '<missing>' }
        $age = [Math]::Round(([DateTime]::UtcNow - (Get-Item -LiteralPath $Path).CreationTimeUtc).TotalSeconds)
        Write-Host "VM lock held: owner=$owner; age=${age}s. A human must resolve it."
    }
} else {
    if (-not (Test-Path -LiteralPath $ownerPath) -or ([IO.File]::ReadAllText($ownerPath)).Trim() -cne $RunId) { exit 74 }
    if ($Operation -eq 'Release') { Remove-Item -LiteralPath $Path -Recurse -Force }
}
