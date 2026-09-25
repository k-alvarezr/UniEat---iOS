$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$package = Join-Path $repo 'Packages\UniEatCore'
$swiftHome = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
$toolchain = Get-ChildItem (Join-Path $swiftHome 'Toolchains') -Directory |
    Sort-Object Name -Descending |
    Where-Object { Test-Path (Join-Path $_.FullName 'usr\bin\swift.exe') } |
    Select-Object -First 1
if (-not $toolchain) { throw 'No se encontró Swift para Windows.' }
$swift = Join-Path $toolchain.FullName 'usr\bin\swift.exe'

$sdk = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
if (-not $sdk -or -not (Test-Path $sdk)) { throw 'No se encontró SDKROOT de Swift.' }
$sdkLink = Join-Path $repo '.local-swift-sdk'
if (-not (Test-Path $sdkLink)) {
    New-Item -ItemType Junction -Path $sdkLink -Target $sdk | Out-Null
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $vsRoot) { throw 'No se encontraron las herramientas C++ de Visual Studio 2022.' }
$vcCmd = Join-Path $vsRoot 'Common7\Tools\VsDevCmd.bat'
$vcTools = Get-ChildItem (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
$kit = Get-ChildItem $kitRoot -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'ucrt\stdlib.h') } |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $vcTools -or -not $kit) { throw 'Faltan cabeceras de MSVC o del SDK de Windows.' }

$includeLinks = Join-Path $repo '.local-windows-includes'
New-Item -ItemType Directory -Path $includeLinks -Force | Out-Null
$includes = [ordered]@{
    ucrt = Join-Path $kit.FullName 'ucrt'
    msvc = Join-Path $vcTools.FullName 'include'
    um = Join-Path $kit.FullName 'um'
    shared = Join-Path $kit.FullName 'shared'
}
foreach ($name in $includes.Keys) {
    $link = Join-Path $includeLinks $name
    if (-not (Test-Path $link)) {
        New-Item -ItemType Junction -Path $link -Target $includes[$name] | Out-Null
    }
}

$env:SDKROOT = $sdkLink
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
$flags = foreach ($name in $includes.Keys) { '-Xcc -I"' + (Join-Path $includeLinks $name) + '"' }
$command = 'call "' + $vcCmd + '" -arch=x64 -host_arch=x64 >nul && "' + $swift + '" build -j 1 ' + ($flags -join ' ')
Push-Location $package
try {
    & cmd.exe /d /c $command
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}
