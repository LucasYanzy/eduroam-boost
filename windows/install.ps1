<#
  eduroam-boost installer for Windows (experimental).
    irm https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main/windows/install.ps1 | iex

  Optional, set before running:
    $env:EDUROAM_BOOST_WATCH = 'notify' | 'auto' | 'none'   # background watcher at logon (asked if unset)
    $env:EDUROAM_BOOST_PREFER5G = '1' | '0'                  # set the driver's Preferred Band to 5 GHz (asked if unset)
#>
$ErrorActionPreference = 'Stop'
$raw = if ($env:EDUROAM_BOOST_RAW) { $env:EDUROAM_BOOST_RAW } else { 'https://raw.githubusercontent.com/LucasYanzy/eduroam-boost/main' }
$dir = if ($env:EDUROAM_BOOST_INSTALL_DIR) { $env:EDUROAM_BOOST_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'eduroam-boost\bin' }
$script = Join-Path $dir 'eduroam-boost.ps1'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'eduroam-boost.ps1' } else { $null }
if ($local -and (Test-Path $local)) { Copy-Item $local $script -Force }
else { Invoke-WebRequest -UseBasicParsing "$raw/windows/eduroam-boost.ps1" -OutFile $script }

# Syntax check before wiring anything up
$tokens = $null; $errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errs)
if ($errs) { throw "downloaded script has errors: $errs" }

Set-Content -Path (Join-Path $dir 'eduroam-boost.cmd') -Encoding ASCII -Value "@powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`" %*"

if (-not $env:EDUROAM_BOOST_DRY_RUN) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$dir").TrimStart(';'), 'User')
        $env:Path += ";$dir"
    }
}
Write-Host "✓ installed: $dir\eduroam-boost.cmd"

function Ask($envName, $question, $choices) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { return $v }
    try { return (Read-Host $question) } catch { return '' }
}

$watch = Ask 'EDUROAM_BOOST_WATCH' 'Background watcher at logon? [n] no / [y] notify / [a] auto-reconnect' $null
$mode = switch -Regex ($watch) { '^(y|notify)$' { 'notify' } '^(a|auto)$' { 'auto' } default { 'none' } }
if ($mode -ne 'none') {
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" watch"
    if ($mode -eq 'auto') { $arg += ' -Auto' }
    if (-not $env:EDUROAM_BOOST_DRY_RUN) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName 'eduroam-boost' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName 'eduroam-boost'
    }
    Write-Host "✓ background watcher ($mode) starts at logon"
}

$p5 = Ask 'EDUROAM_BOOST_PREFER5G' 'Set Wi-Fi driver to prefer 5 GHz now? (needs admin) [y/N]' $null
if ($p5 -match '^(y|1)$' -and -not $env:EDUROAM_BOOST_DRY_RUN) { & powershell -NoProfile -ExecutionPolicy Bypass -File $script prefer-5g }

Write-Host 'Open a new terminal, then try:  eduroam-boost status'
Write-Host "Uninstall:  irm $raw/windows/uninstall.ps1 | iex"
