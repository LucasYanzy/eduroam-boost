<#
  Remove eduroam-boost from Windows. Set $env:EDUROAM_BOOST_PURGE = '1' to also delete logs.
  Note: if you ran prefer-5g, undo it first with:  eduroam-boost prefer-5g -Undo
#>
$dir = if ($env:EDUROAM_BOOST_INSTALL_DIR) { $env:EDUROAM_BOOST_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'eduroam-boost\bin' }
if (-not $env:EDUROAM_BOOST_DRY_RUN) {
    Unregister-ScheduledTask -TaskName 'eduroam-boost' -Confirm:$false -ErrorAction SilentlyContinue
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    [Environment]::SetEnvironmentVariable('Path', (($userPath -split ';') | Where-Object { $_ -and $_ -ne $dir }) -join ';', 'User')
}
Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
if ($env:EDUROAM_BOOST_PURGE -eq '1') { Remove-Item -Recurse -Force (Join-Path $env:LOCALAPPDATA 'eduroam-boost') -ErrorAction SilentlyContinue }
Write-Host '✓ eduroam-boost removed'
