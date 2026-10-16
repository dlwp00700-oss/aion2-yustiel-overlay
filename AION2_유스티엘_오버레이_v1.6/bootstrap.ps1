# AION2 startup supervisor - Windows PowerShell 5.1 (STA)
# It parses before loading the overlay and writes actionable diagnostics instead of vanishing.
$ErrorActionPreference = 'Stop'
$script:baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:logDir = Join-Path $env:LOCALAPPDATA 'AION2_Yustiel_Overlay'
$script:log = Join-Path $script:logDir 'last_error.txt'
try { [void][System.IO.Directory]::CreateDirectory($script:logDir) } catch {
    $script:logDir = [System.IO.Path]::GetTempPath()
    $script:log = Join-Path $script:logDir 'AION2_last_error.txt'
}
function Report-Failure([string]$reason) {
    $content = ('AION2 v1.6 startup error - ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + [Environment]::NewLine + [Environment]::NewLine + $reason + [Environment]::NewLine + [Environment]::NewLine + 'Script folder: ' + $script:baseDir + [Environment]::NewLine + 'PS version: ' + $PSVersionTable.PSVersion)
    try { [System.IO.File]::WriteAllText($script:log,$content,[System.Text.Encoding]::UTF8) } catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(('AION2 overlay failed to start. Error details saved to:' + [Environment]::NewLine + $script:log + [Environment]::NewLine + [Environment]::NewLine + $reason.Substring(0,[Math]::Min($reason.Length,600))),'AION2 Yustiel v1.6',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { Write-Host $content }
}
try {
    $scriptFile = Join-Path $script:baseDir 'AION2_Overlay.ps1'
    $csv = Join-Path $script:baseDir 'schedule.csv'
    if(-not (Test-Path -LiteralPath $scriptFile)) { throw 'Missing main script: AION2_Overlay.ps1' }
    if(-not (Test-Path -LiteralPath $csv)) { throw 'Missing data file: schedule.csv' }
    if($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 or higher is required.' }
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptFile,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count -gt 0) {
        $msg = ($parseErrors | ForEach-Object { 'Line ' + $_.Extent.StartLineNumber + ': ' + $_.Message }) -join [Environment]::NewLine
        throw ('PowerShell script syntax error:' + [Environment]::NewLine + $msg)
    }
    & $scriptFile
}
catch {
    Report-Failure ($_.Exception.ToString() + [Environment]::NewLine + ($_ | Out-String))
    exit 1
}
