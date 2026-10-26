param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$DataRoot, [Parameter(Mandatory=$true)][string]$EvidenceDir, [string]$NormalProject)
$ErrorActionPreference='Stop'
$root=(Resolve-Path $Root).Path
$shots=$EvidenceDir
New-Item -ItemType Directory -Force $shots | Out-Null
trap { [IO.File]::WriteAllText((Join-Path $shots 'error.txt'),($_ | Out-String)); break }
$env:VOXCLIP_DATA_DIR=$DataRoot
if(-not (Test-Path (Join-Path $DataRoot 'windows-runtime-agreement.txt'))){throw 'Accept the bundled Windows runtime terms explicitly in this isolated data root before the walk.'}
$env:VOXCLIP_SHARED_DIR=Join-Path $root 'shared'
$exe=Join-Path $root 'apps\windows\src\VoxClip.App\bin\ARM64\Debug\net10.0-windows10.0.26100.0\win-arm64\VoxClip.exe'
$started=[DateTime]::UtcNow
$owned=@{}
$result=[ordered]@{homeRenderedSelfCheck=$false; editorRenderedSelfCheck=$false; editorUiAObserved=$false; editorScreenshotCaptured=$false; normalOpen=$false; sameWindowReopen=$false; noArgumentReactivation=$false; fileActivationAfterNoArgument=$false; keyboardWalk=$false; correctionTextIsolated=$false; f6Descendants=$false; previewFocused=$false; previewEscapeReturn=$false; exportDialog=$false; exportCancelled=$false; findSetup=$false; compactReturn=$false; providerDispatched=$false; exportStarted=$false}
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
function Capture([IntPtr]$w,[string]$name){
 [void][R1Native]::SetWindowPos($w,[IntPtr](-1),0,0,0,0,0x43);[void][R1Native]::SetForegroundWindow($w);Start-Sleep -Milliseconds 850
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
  Dump $w 'home';Capture $w 'home'
  $redirect=StartOwned ('"'+(Resolve-Path $NormalProject).Path+'"')
  [IO.File]::WriteAllText((Join-Path $shots 'activation.txt'),"homePid=$($app.Id) homeHwnd=$w redirectPid=$($redirect.Id)")
  [void](FindName $w 'Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.')
  if($app.HasExited -or $app.MainWindowHandle -ne $w){throw 'Normal open did not retain Home process and HWND'}
  $result.normalOpen=$true
 }else{[void](FindName $w 'Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.')}
 if(-not $NormalProject){Start-Sleep -Seconds 2;for($i=0;$i -lt 30;$i++){$check=ReadCheck $report;if($check.status -eq 'ready'){break};if($check.status -eq 'failed'){throw 'Rendered self-check failed'};Start-Sleep -Milliseconds 500}}
 if($check.status -ne 'ready' -or !$check.rootLoaded -or !$check.rendered -or $check.processId -ne $app.Id -or $check.windowHandle -ne $w.ToInt64() -or (!$NormalProject -and $check.screen -ne 'editor')){throw 'Rendered self-check did not complete for the owned PID/HWND'}
 if(-not $NormalProject){$result.editorRenderedSelfCheck=$true}
 Start-Sleep -Seconds 3
 if($NormalProject -and (HasVisibleName $w 'Preview unavailable. Your video and edits are still here.')){throw 'Normal project opened without a native media preview'}
 Dump $w 'editor';Capture $w 'editor'
 $result.editorUiAObserved=$true
 $result.editorScreenshotCaptured=$true
 $transcript=FindName $w 'Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.'
 $transcript.SetFocus();[void][R1Native]::SetForegroundWindow($w)
 [R1Native]::Key(0x24)
 [R1Native]::keybd_event(0x10,0,0,[UIntPtr]::Zero)
 for($k=0;$k -lt 5;$k++){[R1Native]::Key(0x27)}
 [R1Native]::keybd_event(0x10,0,2,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 300
 Dump $w 'selected';Capture $w 'selected'
 [R1Native]::Chord(0x11,0x4B)
 [void](FindName $w 'Export 1 clip')
 Dump $w 'clip';Capture $w 'clip'
 (FindName $w 'Clip 1').SetFocus()
 [R1Native]::Chord(0x10,0x75);Start-Sleep -Milliseconds 200
 $reverseFromClip=[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name
 if(-not $reverseFromClip.StartsWith('Playhead')){throw "Shift F6 from clip checkbox missed timeline: $reverseFromClip"}
 (FindName $w 'Source').SetFocus()
 [R1Native]::Key(0x75);Start-Sleep -Milliseconds 200
 $forwardFromAspect=[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name
 [IO.File]::WriteAllText((Join-Path $shots 'f6-descendants.txt'),"reverseFromClip=$reverseFromClip`nforwardFromAspect=$forwardFromAspect")
 if(-not $forwardFromAspect.StartsWith('Playhead')){throw "F6 from preview aspect missed timeline: $forwardFromAspect"}
 $result.f6Descendants=$true
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
 if($typed.Current.Name -ne 'Correct spelling. The audio stays the same.' -or $value.Current.Value -notmatch '(?i)jklc' -or -not (HasVisibleName $w 'Export 1 clip')){throw 'Correction typing or Ctrl K escaped the text field'}
 [R1Native]::Key(0x0D);Start-Sleep -Milliseconds 250
 $result.correctionTextIsolated=$true
 $focus=@()
 for($k=0;$k -lt 3;$k++){[R1Native]::Key(0x75);Start-Sleep -Milliseconds 200;$focus+=('F6='+[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name)}
 for($k=0;$k -lt 30;$k++){
  $name=[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name
  $focus+=('Tab='+$name)
  if($name -eq 'Preview Clip 1'){break}
  [R1Native]::Key(0x09);Start-Sleep -Milliseconds 100
 }
 [IO.File]::WriteAllLines((Join-Path $shots 'focus-before-preview.txt'),$focus)
 if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -ne 'Preview Clip 1'){throw 'Keyboard traversal did not reach Preview clip'}
 [R1Native]::Chord(0x10,0x09);Start-Sleep -Milliseconds 120
 $reverseTab=[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name
 [R1Native]::Key(0x09);Start-Sleep -Milliseconds 120
 if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -ne 'Preview Clip 1'){throw "Shift Tab and Tab did not return to preview action from $reverseTab"}
 [R1Native]::Key(0x0D)
 [void](FindName $w 'Previewing this clip')
 $previewFocus=[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name
 if($previewFocus -ne 'Play or pause (Space)'){throw "Preview did not focus its transport: $previewFocus"}
 $result.previewFocused=$true
 Dump $w 'preview';Capture $w 'preview'
 [R1Native]::Key(0x1B);Start-Sleep -Milliseconds 300
 $afterEscape=[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name
 [IO.File]::WriteAllText((Join-Path $shots 'preview-focus.txt'),"afterEnter=$previewFocus`nafterEscape=$afterEscape")
 Dump $w 'after-escape';Capture $w 'after-escape'
 if($afterEscape -ne 'Clip 1'){throw "Escape did not restore focus to clip row: $afterEscape"}
 $result.previewEscapeReturn=$true
 $focus=@()
 for($k=0;$k -lt 80;$k++){
  $name=[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name
  $focus+=('Tab='+$name)
  if($name -eq 'Export 1 clip'){break}
  [R1Native]::Key(0x09);Start-Sleep -Milliseconds 70
 }
 [IO.File]::WriteAllLines((Join-Path $shots 'focus-to-export.txt'),$focus)
 if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -ne 'Export 1 clip'){throw 'Tab did not reach selected clip Export'}
 [R1Native]::Key(0x0D)
 [void](FindName $w 'Selected clips (1)')
 $result.exportDialog=$true
 Start-Sleep -Milliseconds 700;Capture $w 'export'
 [R1Native]::Key(0x1B);Start-Sleep -Milliseconds 250
 if(HasVisibleName $w 'Selected clips (1)'){throw 'Export dialog remained open after Escape'}
 $result.exportCancelled=$true
 $focus=@()
 for($k=0;$k -lt 80;$k++){
  $name=[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name
  $focus+=('Tab='+$name)
  if($name -eq 'Find clips with a chosen connector'){break}
  [R1Native]::Key(0x09);Start-Sleep -Milliseconds 70
 }
 [IO.File]::WriteAllLines((Join-Path $shots 'focus-to-find.txt'),$focus)
 if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -ne 'Find clips with a chosen connector'){throw 'Tab did not reach Find Clips'}
 [R1Native]::Key(0x0D)
 [void](FindName $w 'Connector')
 $result.findSetup=$true
 Start-Sleep -Milliseconds 700;Capture $w 'find'
 [void][R1Native]::SetWindowPos($w,[IntPtr]::Zero,32,32,[int](900*$check.rasterizationScale),[int](720*$check.rasterizationScale),0x40)
 Start-Sleep -Milliseconds 700
 (FindName $w 'Clips and captions').SetFocus();[R1Native]::Key(0x0D)
 Start-Sleep -Milliseconds 400;Capture $w 'compact-find'
 [R1Native]::Key(0x1B);Start-Sleep -Milliseconds 300;Capture $w 'compact-return'
 $compactFocus=[System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name
 [IO.File]::WriteAllText((Join-Path $shots 'compact-focus.txt'),$compactFocus)
 if($compactFocus -ne 'Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.'){throw "Compact Escape did not return transcript focus: $compactFocus"}
 $result.compactReturn=$true
 if($NormalProject){
  $clipCountLabel='1 clip in this take '+[char]0x00B7+' Select words to make another.'
  [R1Native]::Chord(0x12,0x25)
  [void](FindName $w 'Import video, Ctrl+O')
  if($app.HasExited -or $app.MainWindowHandle -ne $w){throw 'Home navigation changed the owned HWND'}
  Dump $w 'home-recent';Capture $w 'home-recent'
  $items=[System.Windows.Automation.AutomationElement]::FromHandle($w).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  $recent=$items | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and $_.Current.Name -like '*r2-synthetic*'} | Select-Object -First 1
  if(-not $recent){throw 'Saved project was absent from Home recents'}
  $recent.SetFocus();[R1Native]::Key(0x0D)
  [void](FindName $w 'Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.')
  if($app.HasExited -or $app.MainWindowHandle -ne $w){throw 'Recent reopen changed the owned HWND'}
  if(HasVisibleName $w 'Preview unavailable. Your video and edits are still here.'){throw 'Recent reopen lost the native media preview'}
  Start-Sleep -Milliseconds 700
  Dump $w 'recent-reopened';Capture $w 'recent-reopened'
  $result.sameWindowReopen=$true
  [void](FindName $w $clipCountLabel)
  Start-Sleep -Seconds 1
  $noticesBefore=VisibleNotices $w
  $savedBefore=(Get-Item $NormalProject).LastWriteTimeUtc.Ticks
  $contentBefore=(Get-FileHash $NormalProject -Algorithm SHA256).Hash
  $noFile=StartOwned ''
  if(-not $noFile.WaitForExit(10000)){throw 'No-argument redirected process did not exit'}
  # The redirected process can exit before the original window handles its queued activation.
  # Let the UI dispatcher settle before checking the editor and saved project.
  Start-Sleep -Seconds 3
  [void](FindName $w $clipCountLabel)
  $app.Refresh()
  if($app.HasExited -or $app.Path -ne $exe -or $app.StartTime.ToUniversalTime().Ticks -ne $owned[$app.Id] -or $app.MainWindowHandle -ne $w -or (VisibleNotices $w) -ne $noticesBefore -or (Get-Item $NormalProject).LastWriteTimeUtc.Ticks -ne $savedBefore -or (Get-FileHash $NormalProject -Algorithm SHA256).Hash -ne $contentBefore){throw 'No-argument launch changed the project, window, saved file or notice'}
  Dump $w 'no-argument';Capture $w 'no-argument'
  [void](FindName $w $clipCountLabel)
  $app.Refresh()
  if($app.HasExited -or $app.Path -ne $exe -or $app.StartTime.ToUniversalTime().Ticks -ne $owned[$app.Id] -or $app.MainWindowHandle -ne $w -or (VisibleNotices $w) -ne $noticesBefore -or (Get-Item $NormalProject).LastWriteTimeUtc.Ticks -ne $savedBefore -or (Get-FileHash $NormalProject -Algorithm SHA256).Hash -ne $contentBefore){throw 'No-argument launch changed state after the owned-window capture'}
  [IO.File]::WriteAllText((Join-Path $shots 'no-argument-activation.txt'),"pid=$($app.Id) hwnd=$w redirectPid=$($noFile.Id) selectedClipCount=1 notices=$noticesBefore savedTicks=$savedBefore sha256=$contentBefore settledSeconds=3")
  $result.noArgumentReactivation=$true
  [R1Native]::Chord(0x12,0x25)
  [void](FindName $w 'Import video, Ctrl+O')
  $fileLaunch=StartOwned ('"'+(Resolve-Path $NormalProject).Path+'"')
  if(-not $fileLaunch.WaitForExit(10000)){throw 'File-activation redirected process did not exit'}
  [void](FindName $w 'Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.')
  [void](FindName $w $clipCountLabel)
  [void](FindName $w ('Export'+[char]0x2026))
  $savedProject=ReadCheck $NormalProject
  if($savedProject.edits.corrections.w1 -ne 'jklc' -or @($savedProject.edits.clips).Count -ne 1 -or !$savedProject.edits.clips[0].selected){throw 'File activation did not preserve the correction and selected manual clip'}
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
