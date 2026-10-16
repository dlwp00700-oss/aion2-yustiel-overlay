# Separate update helper; launched only after explicit confirmation in the overlay.
# Runs in a different PowerShell process so running program files can be replaced.
param(
    [Parameter(Mandatory=$true)][string]$ZipPath,
    [Parameter(Mandatory=$true)][string]$InstallDir,
    [Parameter(Mandatory=$true)][int]$ParentPid
)
$ErrorActionPreference = 'Stop'
$logDir=Join-Path $env:LOCALAPPDATA 'AION2_Yustiel_Overlay'
[void][System.IO.Directory]::CreateDirectory($logDir)
$log=Join-Path $logDir 'update_last.txt'
$tempDir=Join-Path ([System.IO.Path]::GetTempPath()) ('AION2_stage_'+[guid]::NewGuid().ToString('N'))
$expected=@('AION2_Overlay.ps1','bootstrap.ps1','AION2_start.vbs','AION2_preview.vbs','schedule.csv','update_helper.ps1')
$optional=@('README_사용법.txt','실행.cmd','미리보기.cmd','디버그_실행.cmd','오류로그_열기.cmd','run.cmd')
function Log([string]$line) { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')+'  '+$line) -Encoding UTF8 }
try {
    Log 'Update helper started.'
    if(-not(Test-Path -LiteralPath $ZipPath)){throw 'Downloaded ZIP missing.'}
    if(-not(Test-Path -LiteralPath $InstallDir)){throw 'Installation folder missing.'}
    for($i=0;$i -lt 40;$i++) {
        if(-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
    if(Get-Process -Id $ParentPid -ErrorAction SilentlyContinue){throw 'Original app did not exit within 20 seconds. Files were not changed.'}
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [void][System.IO.Directory]::CreateDirectory($tempDir)
    $stage=Join-Path $tempDir 'new'
    $backup=Join-Path $tempDir 'backup'
    [void][System.IO.Directory]::CreateDirectory($stage)
    [void][System.IO.Directory]::CreateDirectory($backup)
    $archive=[System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach($name in $expected) {
            $candidates=@($archive.Entries | Where-Object { $_.Name -ceq $name -and $_.FullName -notmatch '\.\.' })
            if($candidates.Count -ne 1){throw ('Required file missing or duplicated in release ZIP: '+$name)}
        }
        foreach($name in @($expected+$optional)) {
            $entries=@($archive.Entries | Where-Object { $_.Name -ceq $name -and $_.FullName -notmatch '\.\.' })
            if($entries.Count -ne 1){continue}
            $entry=$entries[0]
            if($entry.Length -gt 2000000){throw ('Unexpectedly large update file: '+$name)}
            $source=$entry.Open()
            $dest=[System.IO.File]::Create((Join-Path $stage $name))
            try{$source.CopyTo($dest)}finally{$source.Dispose();$dest.Dispose()}
        }
    } finally {$archive.Dispose()}
    # Verify all staged files before mutating installed files.
    foreach($name in $expected){if(-not(Test-Path -LiteralPath (Join-Path $stage $name))){throw ('Staging failed: '+$name)}}
    $changed=New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach($file in @(Get-ChildItem -LiteralPath $stage -File)) {
            $name=$file.Name
            $target=Join-Path $InstallDir $name
            $old=Join-Path $backup $name
            if(Test-Path -LiteralPath $target){Copy-Item -LiteralPath $target -Destination $old -Force}
            $changed.Add($name)
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }
    } catch {
        Log ('Error during copy, reverting: '+$_.Exception.Message)
        foreach($name in $changed) {
            $old=Join-Path $backup $name
            $target=Join-Path $InstallDir $name
            if(Test-Path -LiteralPath $old){Copy-Item -LiteralPath $old -Destination $target -Force}
            else{Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue}
        }
        throw
    }
    Log 'Update installed successfully; launching app.'
    $wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
    $startFile=Join-Path $InstallDir 'AION2_start.vbs'
    Start-Process -FilePath $wscript -ArgumentList ('"'+$startFile+'"') | Out-Null
    Log 'Restart command sent.'
} catch {
    Log ('FAILED: '+$_.Exception.ToString())
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show('업데이트 실패: '+$_.Exception.Message+[Environment]::NewLine+'기존 파일은 가능한 한 복원했습니다.'+[Environment]::NewLine+$log,'AION2 업데이트 오류')|Out-Null
    }catch{}
} finally {
    try{Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue}catch{}
    try{Remove-Item -LiteralPath $tempDir -Force -Recurse -ErrorAction SilentlyContinue}catch{}
}
