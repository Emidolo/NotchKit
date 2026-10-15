# Builds build\NotchKit-<version>-setup.exe: the app and the service, self-contained, in one installer.
# Needs the .NET 10 SDK and Inno Setup 6 (winget install JRSoftware.InnoSetup).
$ErrorActionPreference = 'Stop'
$out = Join-Path (Split-Path $PSScriptRoot) 'build\windows'
$version = ([xml](Get-Content (Join-Path $PSScriptRoot 'NotchKit\NotchKit.csproj'))).Project.PropertyGroup.Version

foreach ($project in 'NotchKit', 'NotchKitService') {
    dotnet publish (Join-Path $PSScriptRoot $project) -c Release -r win-x64 --self-contained `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $out
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}

$iscc = Get-Command iscc -ErrorAction SilentlyContinue
$iscc = if ($iscc) { $iscc.Source } else { Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
& $iscc "/DVersion=$version" (Join-Path $PSScriptRoot 'installer.iss')
exit $LASTEXITCODE
