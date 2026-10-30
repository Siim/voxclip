param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$EvidenceDir,[Parameter(Mandatory=$true)][string]$OwnerToken)
$ErrorActionPreference='Stop'
if(-not $EvidenceDir.StartsWith($Root+'\')){throw 'Evidence must be owned'}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
$seen=@{}
$elapsed=[Diagnostics.Stopwatch]::StartNew()
while($elapsed.Elapsed.TotalMinutes -lt 30 -and -not (Test-Path -LiteralPath (Join-Path $Root 'stop-hit-observer'))) {
    if((Get-Content -LiteralPath C:\voxclip-build\vm.lock\owner.txt -Raw).Trim() -ne $OwnerToken){throw 'Wrong VM owner'}
    foreach($file in @(Get-ChildItem -LiteralPath $EvidenceDir -Filter caption-hits.jsonl -ErrorAction SilentlyContinue)) {
        try { $lines=[IO.File]::ReadAllLines($file.FullName) } catch [IO.IOException] {continue}
        for($index=0;$index -lt $lines.Count;$index++) {
            $key=$file.FullName+':'+$index
            if($seen.ContainsKey($key)){continue}
            try { $request=$lines[$index] | ConvertFrom-Json } catch {continue}
            $seen[$key]=$true
            $observed=[DateTimeOffset]::UtcNow
            try {
                $peer=[System.Windows.Automation.AutomationElement]::FromPoint([Windows.Point]::new($request.Screen.X,$request.Screen.Y))
                $parents=@()
                for($depth=0;$peer -and $depth -lt 8;$depth++) {
                    $parents+=@{name=$peer.Current.Name;id=$peer.Current.AutomationId;role=$peer.Current.ControlType.ProgrammaticName;pid=$peer.Current.ProcessId;bounds=$peer.Current.BoundingRectangle;offscreen=$peer.Current.IsOffscreen}
                    if($peer.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window){break}
                    $peer=[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($peer)
                }
                @{request=$request;observed=$observed.ToString('o');peers=$parents} | ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath (Join-Path $file.DirectoryName 'caption-hit-uia.jsonl') -Encoding ASCII
            } catch {
                @{request=$request;observed=$observed.ToString('o');error=$_.Exception.GetType().Name} | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath (Join-Path $file.DirectoryName 'caption-hit-uia.jsonl') -Encoding ASCII
            }
        }
    }
    Start-Sleep -Milliseconds 10
}
