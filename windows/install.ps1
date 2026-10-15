#Requires -RunAsAdministrator
# Builds NotchKit and NotchKitService, copies both to Program Files and registers the service.
#   .\install.ps1              install or update
#   .\install.ps1 -Uninstall   stop and remove the service and the files
# Needs the .NET 10 SDK. Run it from an elevated PowerShell in this folder.
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$target = Join-Path $env:ProgramFiles 'NotchKit'
$service = 'NotchKitService'

if (Get-Service $service -ErrorAction SilentlyContinue) { Stop-Service $service }
Get-Process NotchKit -ErrorAction SilentlyContinue | Stop-Process

if ($Uninstall) {
    if (Get-Service $service -ErrorAction SilentlyContinue) { sc.exe delete $service | Out-Null }
    Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'NotchKit removed. Switch off "Launch at login" first if it was on, or delete the NotchKit value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.'
    return
}

$publish = '-c', 'Release', '-r', 'win-x64', '--self-contained', '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true', '-o', $target
dotnet publish (Join-Path $PSScriptRoot 'NotchKit') @publish
dotnet publish (Join-Path $PSScriptRoot 'NotchKitService') @publish

if (-not (Get-Service $service -ErrorAction SilentlyContinue)) {
    New-Service -Name $service -DisplayName 'NotchKit Service' -StartupType Automatic `
        -Description 'Keeps the PC awake and handles the lid for NotchKit.' `
        -BinaryPathName "`"$target\NotchKitService.exe`"" | Out-Null
}
Start-Service $service
# Not started from here: it would run as administrator, and Windows then blocks drag and drop from Explorer.
Write-Host "Installed in $target. Start NotchKit from there (not as administrator), then turn on Launch at login in its Settings."
