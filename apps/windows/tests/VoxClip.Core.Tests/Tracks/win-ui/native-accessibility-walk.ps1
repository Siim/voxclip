param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$DataRoot, [Parameter(Mandatory=$true)][string]$EvidenceDir, [string]$NormalProject, [ValidateSet('win-x64','win-arm64')][string]$RuntimeIdentifier='win-arm64', [ValidateSet('Debug','Release')][string]$Configuration='Debug', [string]$VoiceLabStep, [switch]$Schedule)
if ($VoiceLabStep) {
    & (Join-Path $PSScriptRoot 'native-voicelab-walk.ps1') -Root $Root -AcceptedDataRoot $DataRoot -EvidenceDir $EvidenceDir -NormalProject $NormalProject -RuntimeIdentifier $RuntimeIdentifier -Configuration $Configuration -Step $VoiceLabStep -Schedule:$Schedule
    return
}
$ErrorActionPreference='Stop'
$root=(Resolve-Path $Root).Path
$shots=Join-Path $EvidenceDir $RuntimeIdentifier
New-Item -ItemType Directory -Force $shots | Out-Null
trap { [IO.File]::WriteAllText((Join-Path $shots 'error.txt'),($_ | Out-String)); break }
$env:VOXCLIP_DATA_DIR=$DataRoot
if(-not (Test-Path (Join-Path $DataRoot 'windows-runtime-agreement.txt'))){throw 'Accept the bundled Windows runtime terms explicitly in this isolated data root before the walk.'}
$env:VOXCLIP_SHARED_DIR=Join-Path $root 'shared'
$platform=if($RuntimeIdentifier -eq 'win-arm64'){'ARM64'}else{'x64'}
$exe=Join-Path $root "apps\windows\src\VoxClip.App\bin\$platform\Debug\net10.0-windows10.0.26100.0\$RuntimeIdentifier\VoxClip.exe"
$started=[DateTime]::UtcNow
$owned=@{}
$result=[ordered]@{homeRenderedSelfCheck=$false; homeLaunch=$false; editorRenderedSelfCheck=$false; editorUiAObserved=$false; editorScreenshotCaptured=$false; normalOpen=$false; paneRows=$false; keyboardClip=$false; correctionTextIsolated=$false; clipRowScope=$false; paneShortcuts=$false; escapeFullTake=$false; f6Order=$false; homeKeepsEditor=$false; findAction=$false; compactPane=$false; sameWindowReopen=$false; noArgumentReactivation=$false; fileActivationAfterNoArgument=$false; keyboardWalk=$false; providerDispatched=$false; exportStarted=$false}
function StartOwned([string]$arguments) {
 $start=New-Object System.Diagnostics.ProcessStartInfo($exe)
 $start.UseShellExecute=$false
 $start.Arguments=$arguments
 $process=[System.Diagnostics.Process]::Start($start)
 if(-not $process){throw 'App process did not start'}
 $script:owned[$process.Id]=$process.StartTime.ToUniversalTime().Ticks
 return $process
}
function ReadCheck([string]$path) {
 if(-not (Test-Path $path)){return $null}
 try {
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
  try {$reader=[IO.StreamReader]::new($stream);return ($reader.ReadToEnd() | ConvertFrom-Json)} finally {$stream.Dispose()}
 } catch {return $null}
}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class R1Native {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr w,out Rect r);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr w);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr w,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr w,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr w,out uint p);
 [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr w,int command);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr w,IntPtr a,int x,int y,int width,int height,uint f);
 [DllImport("user32.dll")] public static extern void keybd_event(byte k,byte s,uint f,UIntPtr e);
 public static void Key(byte k) {keybd_event(k,0,0,UIntPtr.Zero);keybd_event(k,0,2,UIntPtr.Zero);}
 public static void Chord(byte mod,byte k) {keybd_event(mod,0,0,UIntPtr.Zero);Key(k);keybd_event(mod,0,2,UIntPtr.Zero);}
}
'@
function AppProcess {
 for($i=0;$i -lt 100;$i++){
  $p=Get-Process -Id @($script:owned.Keys) -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe -and $_.StartTime.ToUniversalTime().Ticks -eq $script:owned[$_.Id] -and $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
  if($p){return $p};Start-Sleep -Milliseconds 200
 }
 throw 'Owned app did not present a window'
}
function FindName([IntPtr]$w,[string]$name) {
 $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$name)
 for($i=0;$i -lt 60;$i++){
  $x=[System.Windows.Automation.AutomationElement]::FromHandle($w).FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
  if($x -and -not $x.Current.IsOffscreen){return $x};Start-Sleep -Milliseconds 200
 }
 throw "Missing visible UIA name: $name"
}
function HasVisibleName([IntPtr]$w,[string]$name) {
 $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$name)
 $x=[System.Windows.Automation.AutomationElement]::FromHandle($w).FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
 return $null -ne $x -and -not $x.Current.IsOffscreen
}
function VisibleNotices([IntPtr]$w) {
 $all=[System.Windows.Automation.AutomationElement]::FromHandle($w).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
 $names=foreach($item in $all){
  try{
   if($item.Current.IsOffscreen -or ($item.Current.ClassName -notmatch 'InfoBar' -and $item.Current.AutomationId -notmatch 'Notice')){continue}
   $item.Current.Name
   $children=$item.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
   foreach($child in $children){if(-not $child.Current.IsOffscreen -and $child.Current.Name){$child.Current.Name}}
  }catch{}
 }
 return (@($names | Where-Object {$_} | Sort-Object -Unique) -join '|')
}
function Dump([IntPtr]$w,[string]$name){
 $all=$null
 for($attempt=0;$attempt -lt 5;$attempt++){
  try {$all=[System.Windows.Automation.AutomationElement]::FromHandle($w).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition);break}
  catch {if($attempt -eq 4){throw};Start-Sleep -Milliseconds 250}
 }
 $lines=foreach($x in $all){try{ if($x.Current.IsOffscreen){continue};$p=$null;$state='';if($x.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$p)){$state=' selected='+$p.Current.IsSelected};$p=$null;if($x.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern,[ref]$p)){$state+=' expanded='+$p.Current.ExpandCollapseState};$p=$null;if($x.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$p)){$state+=' toggle='+$p.Current.ToggleState}; "{0} | {1} | enabled={2} focus={3}{4}" -f $x.Current.ControlType.ProgrammaticName,$x.Current.Name,$x.Current.IsEnabled,$x.Current.HasKeyboardFocus,$state}catch{}}
 [IO.File]::WriteAllLines((Join-Path $shots "uia-$name.txt"),$lines)
}
# Windows refuses SetForegroundWindow from a background script while another window (often the taskbar) holds the
# foreground lock; an Alt tap releases the lock, as for any automation client. Capture still verifies the owner.
function Front([IntPtr]$w){
 for($attempt=0;$attempt -lt 4;$attempt++){
  if($attempt -gt 0){[R1Native]::Key(0x12)}
  [void][R1Native]::SetForegroundWindow($w);Start-Sleep -Milliseconds 250
  if([R1Native]::GetForegroundWindow() -eq $w){return}
 }
}
function Capture([IntPtr]$w,[string]$name){
 [void][R1Native]::SetWindowPos($w,[IntPtr](-1),0,0,0,0,0x43);Front $w;Start-Sleep -Milliseconds 850
 $b=New-Object R1Native+Rect
 if(-not [R1Native]::GetWindowRect($w,[ref]$b)){throw 'No bounds'}
 $foreground=[R1Native]::GetForegroundWindow()
 $title=New-Object System.Text.StringBuilder 256
 $class=New-Object System.Text.StringBuilder 256
 [void][R1Native]::GetWindowText($foreground,$title,256)
 [void][R1Native]::GetClassName($foreground,$class,256)
 [uint32]$foregroundPid=0
 [void][R1Native]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)
 [IO.File]::WriteAllText((Join-Path $shots "capture-$name.txt"),"expected=$w foreground=$foreground pid=$foregroundPid title=$title class=$class")
 [uint32]$expectedPid=0
 [void][R1Native]::GetWindowThreadProcessId($w,[ref]$expectedPid)
 if($foreground -ne $w -or $foregroundPid -ne $expectedPid -or -not $script:owned.ContainsKey([int]$expectedPid)){throw "Capture $name rejected: foreground does not match the owned window"}
 if($b.Right -le $b.Left -or $b.Bottom -le $b.Top){throw "Capture $name rejected: invalid window bounds"}
 $image=New-Object System.Drawing.Bitmap(($b.Right-$b.Left),($b.Bottom-$b.Top))
 $g=[System.Drawing.Graphics]::FromImage($image)
 try{$g.CopyFromScreen($b.Left,$b.Top,0,0,$image.Size);$image.Save((Join-Path $shots "$name.png"),[System.Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$image.Dispose()}
}
function FindPrefix([IntPtr]$w,[string]$prefix) {
 for($i=0;$i -lt 60;$i++){
  try{$all=[System.Windows.Automation.AutomationElement]::FromHandle($w).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}catch{$all=@()}
  foreach($x in $all){try{if($x.Current.Name.StartsWith($prefix) -and -not $x.Current.IsOffscreen){return $x}}catch{}}
  Start-Sleep -Milliseconds 200
 }
 throw "Missing visible UIA name starting with: $prefix"
}
function HasPrefix([IntPtr]$w,[string]$prefix) {
 try{$all=[System.Windows.Automation.AutomationElement]::FromHandle($w).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}catch{return $false}
 foreach($x in $all){try{if($x.Current.Name.StartsWith($prefix) -and -not $x.Current.IsOffscreen){return $true}}catch{}}
 return $false
}
function FindId([IntPtr]$w,[string]$id) {
 $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$id)
 for($i=0;$i -lt 40;$i++){
  $x=[System.Windows.Automation.AutomationElement]::FromHandle($w).FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
  if($x -and -not $x.Current.IsOffscreen){return $x};Start-Sleep -Milliseconds 200
 }
 throw "Missing visible automation id: $id"
}
function IsSelected($x){$p=$null;if($x.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$p)){return $p.Current.IsSelected};return $false}
function Focused{[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name}
function InCommandBar($e){$walker=[System.Windows.Automation.TreeWalker]::RawViewWalker;$found=$false;$chain=@();for($p=$e;$p -ne $null;$p=$walker.GetParent($p)){$chain+="$($p.Current.Name) | $($p.Current.ClassName) | $($p.Current.AutomationId)";if($p.Current.ClassName -eq 'CommandBar' -or ($p.Current.ClassName -eq 'ApplicationBar' -and $p.Current.AutomationId -eq 'Commands')){$found=$true}};[IO.File]::AppendAllText((Join-Path $shots 'f6-ancestors.txt'),(($chain -join "`n")+"`n---`n"));return $found}
function Choose($x){$x.SetFocus();Start-Sleep -Milliseconds 150;[R1Native]::Key(0x0D);Start-Sleep -Milliseconds 600}
$transcriptName='Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.'
try{
 if(Get-Process VoxClip -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $exe}){throw 'Exact app binary already has a process; refusing to attach to it'}
 $report=Join-Path $shots 'self-check.json'
 $fixture=Join-Path $root 'shared\fixtures\projects\interview-take.voxclip'
 if($NormalProject){$launchArgs='--self-check "'+$report+'"'}else{$launchArgs='--demo-project "'+$fixture+'" --self-check "'+$report+'"'}
 $launched=StartOwned $launchArgs
 [void][R1Native]::ShowWindow([R1Native]::GetConsoleWindow(),0)
 $app=AppProcess
 $w=[IntPtr]$app.MainWindowHandle
 if($NormalProject){
  [void](FindName $w 'Import video, Ctrl+O')
  Start-Sleep -Seconds 2
  for($i=0;$i -lt 30;$i++){$check=ReadCheck $report;if($check.status -eq 'ready'){break};if($check.status -eq 'failed'){throw 'Home rendered self-check failed'};Start-Sleep -Milliseconds 500}
  if($check.status -ne 'ready' -or $check.screen -ne 'home' -or !$check.rootLoaded -or !$check.rendered -or $check.processId -ne $app.Id -or $check.windowHandle -ne $w.ToInt64()){throw 'Home rendered self-check did not match owned PID/HWND'}
  $result.homeRenderedSelfCheck=$true
  if(-not (IsSelected (FindName $w 'Home'))){throw 'The Home row is not selected at launch'}
  if((HasVisibleName $w 'New clip from selection') -or (HasPrefix $w 'Full take, ')){throw 'A project section showed without a project'}
  $result.homeLaunch=$true
  Dump $w 'home';Capture $w 'home'
  $redirect=StartOwned ('"'+(Resolve-Path $NormalProject).Path+'"')
  [IO.File]::WriteAllText((Join-Path $shots 'activation.txt'),"homePid=$($app.Id) homeHwnd=$w redirectPid=$($redirect.Id)")
  [void](FindName $w $transcriptName)
  if($app.HasExited -or $app.MainWindowHandle -ne $w){throw 'Normal open did not retain Home process and HWND'}
  $result.normalOpen=$true
 }else{[void](FindName $w $transcriptName)}
 if(-not $NormalProject){Start-Sleep -Seconds 2;for($i=0;$i -lt 30;$i++){$check=ReadCheck $report;if($check.status -eq 'ready'){break};if($check.status -eq 'failed'){throw 'Rendered self-check failed'};Start-Sleep -Milliseconds 500}}
 if($check.status -ne 'ready' -or !$check.rootLoaded -or !$check.rendered -or $check.processId -ne $app.Id -or $check.windowHandle -ne $w.ToInt64() -or (!$NormalProject -and $check.screen -ne 'editor')){throw 'Rendered self-check did not complete for the owned PID/HWND'}
 if(-not $NormalProject){$result.editorRenderedSelfCheck=$true}
 Start-Sleep -Seconds 3
 if($NormalProject -and (HasVisibleName $w 'Preview unavailable. Your video and edits are still here.')){throw 'Normal project opened without a native media preview'}
 Dump $w 'editor';Capture $w 'editor'
 $result.editorUiAObserved=$true
 $result.editorScreenshotCaptured=$true
 # Pane rows carry the design section 3.4 names; Full take is selected after opening.
 $full=FindPrefix $w 'Full take, '
 $fullSuffix=if($NormalProject){' after cuts'}else{' after cuts, demo project, no video'}
 if(-not (IsSelected $full) -or -not $full.Current.Name.EndsWith($fullSuffix)){throw "Full take row is not selected or misnamed: $($full.Current.Name)"}
 [void](FindName $w 'Home')
 if((FindName $w 'New clip from selection').Current.IsEnabled){throw 'New clip from selection is enabled without selected words'}
 [void](FindName $w 'Find clips with AI')
 $result.paneRows=$true
 $transcript=FindName $w $transcriptName
 $transcript.SetFocus();Front $w
 [R1Native]::Key(0x24)
 [R1Native]::keybd_event(0x10,0,0,[UIntPtr]::Zero)
 for($k=0;$k -lt 5;$k++){[R1Native]::Key(0x27)}
 [R1Native]::keybd_event(0x10,0,2,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 300
 if(-not (FindName $w 'New clip from selection').Current.IsEnabled){throw 'New clip from selection stayed disabled with words selected'}
 Dump $w 'selected';Capture $w 'selected'
 [R1Native]::Chord(0x11,0x4B)
 [void](FindPrefix $w 'Clip 1, ')
 Dump $w 'clip';Capture $w 'clip'
 $result.keyboardClip=$true
 $transcript.SetFocus()
 [R1Native]::Key(0x43);Start-Sleep -Milliseconds 250
 $correction=[System.Windows.Automation.AutomationElement]::FocusedElement
 if($correction.Current.Name -ne 'Correct spelling. The audio stays the same.'){throw "Correction did not focus its text field: $($correction.Current.Name)"}
 foreach($key in @(0x4A,0x4B,0x4C,0x43,0x20)){[R1Native]::Key($key)}
 [R1Native]::Key(0x25);[R1Native]::Key(0x2E);[R1Native]::Chord(0x11,0x4B)
 Start-Sleep -Milliseconds 200
 $typed=[System.Windows.Automation.AutomationElement]::FocusedElement
 $value=[System.Windows.Automation.ValuePattern]$typed.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
 [IO.File]::WriteAllText((Join-Path $shots 'correction-typing.txt'),"focus=$($typed.Current.Name)`nvalue=$($value.Current.Value)")
 if($typed.Current.Name -ne 'Correct spelling. The audio stays the same.' -or $value.Current.Value -notmatch '(?i)jklc' -or (HasPrefix $w 'Clip 2, ')){throw 'Correction typing or Ctrl K escaped the text field'}
 [R1Native]::Key(0x0D);Start-Sleep -Milliseconds 250
 $result.correctionTextIsolated=$true
 # Choosing a clip row scopes the editor and keeps focus on the row (design C15).
 Choose (FindPrefix $w 'Clip 1, ')
 $clip=FindPrefix $w 'Clip 1, '
 $afterChoose=Focused
 [IO.File]::WriteAllText((Join-Path $shots 'clip-focus.txt'),"selected=$(IsSelected $clip)`nfocus=$afterChoose")
 if(-not (IsSelected $clip) -or -not $afterChoose.StartsWith('Clip 1, ')){throw "Choosing the clip row did not select it and keep focus: $afterChoose"}
 Dump $w 'clip-scope';Capture $w 'clip-scope'
 $result.clipRowScope=$true
 # Editor shortcuts act from the pane (design 11.1). Ctrl+E on the chosen clip row opens Export with only that clip. A demo
 # project has no video, so there Ctrl+E is refused: no dialog opens and the Export button carries the reason.
 [R1Native]::Chord(0x11,0x45);Start-Sleep -Milliseconds 800
 if($NormalProject){
  [void](FindPrefix $w 'This clip')
  Dump $w 'pane-export';Capture $w 'pane-export'
  [R1Native]::Key(0x1B);Start-Sleep -Milliseconds 600
  if(HasPrefix $w 'This clip'){throw 'Escape did not close Export'}
 }else{
  Start-Sleep -Milliseconds 1200
  if(HasPrefix $w 'This clip'){throw 'Ctrl+E opened Export for a demo project'}
  $export=FindId $w 'ExportButton'
  $reason=$export.Current.HelpText
  [IO.File]::WriteAllText((Join-Path $shots 'pane-export-blocked.txt'),"enabled=$($export.Current.IsEnabled)`nreason=$reason`nfocus=$(Focused)")
  if($export.Current.IsEnabled -or $reason -ne 'Demo projects have no video to export.'){throw "Ctrl+E in a demo project was not refused with its reason: $reason"}
  Dump $w 'pane-export-blocked'
 }
 # Delete on the row removes the clip, and Ctrl+Z with focus still in the pane brings it back.
 $clip=FindPrefix $w 'Clip 1, ';$clip.SetFocus();Start-Sleep -Milliseconds 200
 [R1Native]::Key(0x2E);Start-Sleep -Milliseconds 600
 if(HasPrefix $w 'Clip 1, '){throw 'Delete on the clip row did not remove the clip'}
 [R1Native]::Chord(0x11,0x5A);Start-Sleep -Milliseconds 600
 [void](FindPrefix $w 'Clip 1, ')
 [IO.File]::WriteAllText((Join-Path $shots 'pane-shortcuts.txt'),"focus=$(Focused)")
 $result.paneShortcuts=$true
 $transcript=FindName $w $transcriptName
 $transcript.SetFocus();Start-Sleep -Milliseconds 150;[R1Native]::Key(0x1B);Start-Sleep -Milliseconds 500
 if(-not (IsSelected (FindPrefix $w 'Full take, '))){throw 'Escape in the transcript did not return to Full take'}
 $result.escapeFullTake=$true
 # F6 walks the regions in design section 16 order and Shift+F6 walks back; F6 from the pane lands on the command row.
 $transcript=FindName $w $transcriptName
 $transcript.SetFocus();Start-Sleep -Milliseconds 200
 $walk=@()
 $focusEvidence=@()
 for($i=0;$i -lt 6;$i++){
  [R1Native]::Key(0x75);Start-Sleep -Milliseconds 300
  $e=[System.Windows.Automation.AutomationElement]::FocusedElement
  $walk+=,@($e.Current.Name,$e.Current.ControlType.ProgrammaticName,(InCommandBar $e))
  $bounds=$e.Current.BoundingRectangle
  [IO.File]::WriteAllText((Join-Path $shots 'f6-attempts.json'),(ConvertTo-Json -Depth 6 -InputObject @{walk=$walk;last=@{name=$e.Current.Name;offscreen=$e.Current.IsOffscreen;bounds=@{x=$bounds.X;y=$bounds.Y;width=$bounds.Width;height=$bounds.Height}}}))
  if($bounds.IsEmpty -or $e.Current.IsOffscreen){throw 'F6 focused an empty or offscreen element'}
  $name='focus-region-'+($i+1)
  Capture $w $name
  $focusEvidence+=@{image="$name.png";name=$e.Current.Name;bounds=@{x=$bounds.X;y=$bounds.Y;width=$bounds.Width;height=$bounds.Height};twoRingVisual='pending pixel review';blackRectangleAbsent='pending pixel review';narrator='not observed'}
 }
 [IO.File]::WriteAllText((Join-Path $shots 'f6-visual-evidence.json'),(ConvertTo-Json -Depth 6 -InputObject @{
  runtime=$RuntimeIdentifier;regions=$focusEvidence;acceptance='UIA order alone does not prove Fluent two-ring focus, absence of a black rectangle, or spoken Narrator output'
 }))
 [IO.File]::WriteAllText((Join-Path $shots 'f6-order.txt'),(($walk | ForEach-Object { $_ -join ' | ' }) -join "`n"))
 if($walk[0][0] -notin @('Play','Pause') -or ($walk[1][1] -notin @('ControlType.List','ControlType.ListItem') -and $walk[1][0] -ne 'Show captions') -or -not $walk[2][0].StartsWith('Playhead') -or -not $walk[3][0].StartsWith('Full take, ') -or -not $walk[4][2] -or $walk[5][0] -ne $transcriptName){throw 'F6 did not walk the viewer, Captions, timeline, sidebar, command row and transcript in order'}
 [R1Native]::Chord(0x10,0x75);Start-Sleep -Milliseconds 300
 if(-not (InCommandBar ([System.Windows.Automation.AutomationElement]::FocusedElement))){throw 'Shift+F6 from the transcript did not return to the command row'}
 $result.f6Order=$true
 if($NormalProject){
  $transcript=FindName $w $transcriptName
  $transcript.SetFocus();[R1Native]::Key(0x24);[R1Native]::Chord(0x10,0x27)
  [R1Native]::Chord(0x10,0x79)
  $make=FindName $w 'Make clip'
  if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -ne 'Make clip'){throw 'Shift+F10 did not focus Make clip'}
  [R1Native]::Key(0x1B)
  if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -ne $transcriptName){throw 'Escape did not restore transcript focus'}
  $result.selectionFlyoutKeyboard=$true
 }
 # Home keeps the open project in the sidebar and returns to the same editor.
 Choose (FindName $w 'Home')
 [void](FindName $w 'Import video, Ctrl+O')
 [void](FindPrefix $w 'Full take, ');[void](FindPrefix $w 'Clip 1, ')
 if(HasVisibleName $w 'New clip from selection'){throw 'Pane actions stayed visible on Home'}
 Dump $w 'home-with-project';Capture $w 'home-with-project'
 Choose (FindPrefix $w 'Full take, ')
 [void](FindName $w $transcriptName)
 if($app.HasExited -or $app.MainWindowHandle -ne $w){throw 'Home and Full take changed the owned window'}
 $transcript=FindName $w $transcriptName
 $transcript.SetFocus();[R1Native]::Chord(0x12,0x25)
 [void](FindName $w 'Import video, Ctrl+O')
 Choose (FindPrefix $w 'Full take, ')
 [void](FindName $w $transcriptName)
 $result.homeKeepsEditor=$true
 # With no connector, Find clips shows the callout under the actions, whose action is an enabled, named button (design section 13).
 Choose (FindName $w 'Find clips with AI')
 Start-Sleep -Milliseconds 600
 $setUpName='Set up AI'+[char]0x2026
 if(HasVisibleName $w $setUpName){if(-not (FindName $w $setUpName).Current.IsEnabled){throw 'The no-connector callout action is disabled'}}
 else{[void](FindName $w 'Find clips in this take')}
 Capture $w 'find'
 if(-not (HasVisibleName $w $setUpName)){[R1Native]::Key(0x1B);Start-Sleep -Milliseconds 300}
 $result.findAction=$true
 [void][R1Native]::SetWindowPos($w,[IntPtr]::Zero,32,32,[int](900*$check.rasterizationScale),[int](720*$check.rasterizationScale),0x40)
 Start-Sleep -Milliseconds 900
 if(HasPrefix $w 'Full take, '){throw 'The pane stayed open below the 960 breakpoint'}
 $toggle=FindId $w 'PART_PaneToggleButton'
 $toggleName=$toggle.Current.Name
 $pattern=$null;if($toggle.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke()}else{Choose $toggle}
 Start-Sleep -Milliseconds 700
 [void](FindPrefix $w 'Full take, ')
 Dump $w 'compact-pane';Capture $w 'compact-pane'
 [R1Native]::Key(0x1B);Start-Sleep -Milliseconds 500
 [IO.File]::WriteAllText((Join-Path $shots 'compact-pane.txt'),"toggleName=$toggleName`nafterEscape=$(Focused)")
 $result.compactPane=$true
 [void][R1Native]::SetWindowPos($w,[IntPtr]::Zero,32,32,[int](1280*$check.rasterizationScale),[int](800*$check.rasterizationScale),0x40)
 Start-Sleep -Milliseconds 900
 if($NormalProject){
  $transcript=FindName $w $transcriptName
  $transcript.SetFocus();[R1Native]::Chord(0x12,0x25)
  [void](FindName $w 'Import video, Ctrl+O')
  if($app.HasExited -or $app.MainWindowHandle -ne $w){throw 'Home navigation changed the owned HWND'}
  Dump $w 'home-recent';Capture $w 'home-recent'
  $projectName=[string](ReadCheck $NormalProject).title
  if([string]::IsNullOrWhiteSpace($projectName)){$projectName=[IO.Path]::GetFileNameWithoutExtension($NormalProject)}else{$projectName=$projectName.Trim()}
  $items=[System.Windows.Automation.AutomationElement]::FromHandle($w).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  $recent=$items | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and $_.Current.Name -eq $projectName} | Select-Object -First 1
  if(-not $recent){throw 'The open project was absent from the Home recent list'}
  Choose $recent
  [void](FindName $w $transcriptName)
  if($app.HasExited -or $app.MainWindowHandle -ne $w){throw 'Recent reopen changed the owned HWND'}
  if(HasVisibleName $w 'Preview unavailable. Your video and edits are still here.'){throw 'Recent reopen lost the native media preview'}
  Start-Sleep -Milliseconds 700
  Dump $w 'recent-reopened';Capture $w 'recent-reopened'
  $result.sameWindowReopen=$true
  [void](FindPrefix $w 'Clip 1, ')
  Start-Sleep -Seconds 1
  $noticesBefore=VisibleNotices $w
  $savedBefore=(Get-Item $NormalProject).LastWriteTimeUtc.Ticks
  $contentBefore=(Get-FileHash $NormalProject -Algorithm SHA256).Hash
  $noFile=StartOwned ''
  if(-not $noFile.WaitForExit(10000)){throw 'No-argument redirected process did not exit'}
  # The redirected process can exit before the original window handles its queued activation.
  # Let the UI dispatcher settle before checking the editor and saved project.
  Start-Sleep -Seconds 3
  [void](FindPrefix $w 'Clip 1, ')
  $app.Refresh()
  if($app.HasExited -or $app.Path -ne $exe -or $app.StartTime.ToUniversalTime().Ticks -ne $owned[$app.Id] -or $app.MainWindowHandle -ne $w -or (VisibleNotices $w) -ne $noticesBefore -or (Get-Item $NormalProject).LastWriteTimeUtc.Ticks -ne $savedBefore -or (Get-FileHash $NormalProject -Algorithm SHA256).Hash -ne $contentBefore){throw 'No-argument launch changed the project, window, saved file or notice'}
  Dump $w 'no-argument';Capture $w 'no-argument'
  [IO.File]::WriteAllText((Join-Path $shots 'no-argument-activation.txt'),"pid=$($app.Id) hwnd=$w redirectPid=$($noFile.Id) notices=$noticesBefore savedTicks=$savedBefore sha256=$contentBefore settledSeconds=3")
  $result.noArgumentReactivation=$true
  $transcript=FindName $w $transcriptName
  $transcript.SetFocus();[R1Native]::Chord(0x12,0x25)
  [void](FindName $w 'Import video, Ctrl+O')
  $fileLaunch=StartOwned ('"'+(Resolve-Path $NormalProject).Path+'"')
  if(-not $fileLaunch.WaitForExit(10000)){throw 'File-activation redirected process did not exit'}
  [void](FindName $w $transcriptName)
  [void](FindPrefix $w 'Clip 1, ')
  $savedProject=ReadCheck $NormalProject
  if($savedProject.edits.corrections.w1 -ne 'jklc' -or @($savedProject.edits.clips).Count -ne 1 -or !$savedProject.edits.clips[0].selected){throw 'File activation did not preserve the correction and the kept manual clip'}
  $app.Refresh()
  if($app.HasExited -or $app.Path -ne $exe -or $app.StartTime.ToUniversalTime().Ticks -ne $owned[$app.Id] -or $app.MainWindowHandle -ne $w){throw 'File activation after no-argument launch changed the owned window'}
  Dump $w 'file-after-no-argument';Capture $w 'file-after-no-argument'
  $result.fileActivationAfterNoArgument=$true
 }
 $result.keyboardWalk=$true
 }catch{[IO.File]::WriteAllText((Join-Path $shots 'error.txt'),$_.ToString());if($w -ne [IntPtr]::Zero){try{Dump $w 'failure'}catch{}};throw}finally{
 [IO.File]::WriteAllText((Join-Path $shots 'result.json'),($result | ConvertTo-Json -Depth 3))
 foreach($id in @($owned.Keys)) {Get-Process -Id $id -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $exe -and $_.StartTime.ToUniversalTime().Ticks -eq $owned[$id]} | Stop-Process -Force -ErrorAction SilentlyContinue}
 [IO.File]::WriteAllText((Join-Path $shots 'complete'),[DateTime]::UtcNow.ToString('O'))
}
