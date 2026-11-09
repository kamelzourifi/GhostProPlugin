# Fetches the AssettoServer sources this plugin builds against, then builds.
#
# The plugin cannot compile without them: its .csproj references
# AssettoServer.csproj and AssettoServer.Shared.csproj, because the types it
# uses (CSPClientMessageTypeManager, OnlineEvent<T>, EntryCarManager) live in
# the server, not in a NuGet package.
#
# Those sources are NOT kept in this repository — they are ~117 MB of someone
# else's source. This script pulls the exact tag the plugin was verified against.

[CmdletBinding()]
param(
    # AssettoServer commit to build against. This MUST be the commit your server
    # is running — not merely the same minor version. The plugin binds against
    # the exact assembly versions that commit's sources declare, and the server
    # only ships the versions its own build resolved.
    #
    # Find yours in the server log's first line:
    #   AssettoServer 0.0.55+503edd87f3  ->  commit 503edd87f3
    [string]$Commit = '503edd87f3',

    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src'

function Get-Prop([string]$projectPath, [string]$name) {
    if (-not (Test-Path $projectPath)) { return $null }
    $m = Select-String -Path $projectPath -Pattern "<$name>([^<]+)"
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Get-PackageVersions([string]$projectPath) {
    $map = @{}
    if (-not (Test-Path $projectPath)) { return $map }
    foreach ($m in [regex]::Matches((Get-Content $projectPath -Raw),
            'PackageReference Include="([^"]+)" Version="([^"]+)"')) {
        $map[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $map
}

Write-Host "Fetching AssettoServer $Commit ..."

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "as-$Commit"
$zip = "$tmp.zip"

if (Test-Path $zip) { Remove-Item $zip -Force }

# Accept a commit SHA, a full tag ("v0.0.55-pre42"), or the bare version the
# server log prints ("pre42").
#
# The bare form cannot be prefixed naively: the tag for "pre42" is
# "v0.0.55-pre42", not "vpre42". So a non-SHA argument is resolved through the
# tags API by suffix match, which is what actually maps a log line to a ref.
$tagToFetch = $null

if ($Commit -match '^[0-9a-f]{7,40}$') {
    $tagToFetch = $null
    $shaToFetch = $Commit
}
else {
    $shaToFetch = $null
    $tags = Invoke-RestMethod -Uri "https://api.github.com/repos/compujuckel/AssettoServer/tags?per_page=100"
    $match = $tags | Where-Object { $_.name -eq $Commit } | Select-Object -First 1
    if (-not $match) {
        $match = $tags | Where-Object { $_.name -like "*$Commit" } | Select-Object -First 1
    }
    if (-not $match) {
        $known = ($tags | Select-Object -First 8 | ForEach-Object { $_.name }) -join ', '
        throw "no AssettoServer tag matches '$Commit'."
        throw "Recent tags: $known"
    }
    Write-Host "  '$Commit' -> $($match.name)"
    $tagToFetch = $match.name
    $shaToFetch = $match.commit.sha
}

$fetched = $false
$forms = @()
if ($tagToFetch) { $forms += "refs/tags/$tagToFetch.zip" }
$forms += "$shaToFetch.zip"

foreach ($form in $forms) {
    $url = "https://github.com/compujuckel/AssettoServer/archive/$form"
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Write-Host "  fetched $form"
        $fetched = $true
        break
    }
    catch {
        Write-Host "  not found: $form"
    }
}

if (-not $fetched) { throw "could not download AssettoServer '$Commit'." }

if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive $zip -DestinationPath $tmp -Force
Remove-Item $zip -Force

$extracted = Get-ChildItem $tmp -Directory | Select-Object -First 1
if (-not $extracted) { throw "archive did not contain a directory" }

Write-Host "Copying sources into src\ ..."
foreach ($project in 'AssettoServer', 'AssettoServer.Shared') {
    $dest = Join-Path $src $project
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item (Join-Path $extracted.FullName $project) -Destination $dest -Recurse -Force
}

Write-Host "Vendored AssettoServer:"
foreach ($project in 'AssettoServer', 'AssettoServer.Shared') {
    $csproj = Join-Path $src "$project\$project.csproj"
    Write-Host "  $project -> $(Get-Prop $csproj 'TargetFramework')"
}

$serverTfm = Get-Prop (Join-Path $src 'AssettoServer\AssettoServer.csproj') 'TargetFramework'
if (-not $serverTfm) { throw "could not read the server TargetFramework" }

# Pin the vendored server assemblies to 0.0.0.0, which .NET treats as "any
# version". HardBrain's released plugins reference AssettoServer 0.0.0.0 for
# exactly this reason.
#
# Left alone, the SDK stamps them 1.0.0.0 and the server then fails at plugin load
# with FileNotFoundException: 'AssettoServer, Version=1.0.0.0'. The plugin
# compiles cleanly and only fails at runtime, so no build output mentions it.
foreach ($project in 'AssettoServer', 'AssettoServer.Shared') {
    $csproj = Join-Path $src "$project\$project.csproj"
    if (-not (Test-Path $csproj)) { continue }
    $text = Get-Content $csproj -Raw
    if ($text -match '<AssemblyVersion>') { continue }
    $inject = "`n  <PropertyGroup>`n    <AssemblyVersion>0.0.0.0</AssemblyVersion>`n  </PropertyGroup>`n"
    # Anchor on the root <Project Sdk="..."> only. A looser pattern also matches
    # <ProjectReference>, which produces a PropertyGroup nested inside one and
    # fails with MSB4118 "PropertyGroup is a reserved metadata name".
    $anchor = '<Project Sdk="Microsoft.NET.Sdk">'
    if (-not $text.Contains($anchor)) { continue }
    $text = $text.Replace($anchor, $anchor + $inject)
    Set-Content $csproj $text -NoNewline
    Write-Host "  pinned $project to AssemblyVersion 0.0.0.0"
}

# The plugin must target exactly the server's TFM. pre42 moved to net11.0 while
# the 0.0.55 release is net9.0, and a plugin built for the wrong one compiles
# cleanly and then fails at load.
$serverTfm = Get-Prop (Join-Path $src 'AssettoServer\AssettoServer.csproj') 'TargetFramework'
if (-not $serverTfm) { throw "could not read the server TargetFramework" }

# Pick an SDK that can target it. A user-local .NET 11 install is preferred over
# failing, because that is where pre42's toolchain ends up on most machines.
$dotnetExe = 'dotnet'
$userDotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
if ($serverTfm -like 'net1*') {
    $major = [int]($serverTfm -replace '^net(\d+)\.?\d*$', '$1')
    $have = & dotnet --list-sdks 2>$null | ForEach-Object { ($_ -split ' ')[0] }
    $haveMajor = $have | ForEach-Object { [int](($_ -split '\.')[0]) }
    if ($haveMajor -notcontains $major) {
        if (Test-Path $userDotnet) {
            $userSdks = & $userDotnet --list-sdks 2>$null | ForEach-Object { ($_ -split ' ')[0] }
            if (($userSdks | ForEach-Object { [int](($_ -split '\.')[0]) }) -contains $major) {
                Write-Host "  using $userDotnet (has .NET $major)"
                $dotnetExe = $userDotnet
            }
        }
        if ($dotnetExe -eq 'dotnet') {
            throw "server targets $serverTfm but no .NET $major SDK is available."
            throw "install one: dotnet-install.ps1 -Channel $major -InstallDir `"$env:USERPROFILE\.dotnet`""
        }
    }
}

Write-Host "Building GhostProPlugin (targeting $serverTfm) ..."

Push-Location (Join-Path $src 'GhostProPlugin')
try {
    # MinVer derives the version from git tags. There is no git repository here
    # (and git may not be installed), so skip it rather than fail the build.
    $buildArgs = @(
        'build', '-c', $Configuration, '-v:m',
        '-p:MinVerSkip=true',
        "-p:GhostProTargetFramework=$serverTfm"
    )
    & $dotnetExe @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "build failed" }
}
finally {
    Pop-Location
}

$out = Join-Path $src "GhostProPlugin\bin\$Configuration\win-x64"
if (-not (Test-Path $out)) { throw "build reported success but produced no output in $out" }

Write-Host ""
Write-Host "Output:" -ForegroundColor Green
Get-ChildItem $out -Recurse -File |
    Select-Object @{n = 'file'; e = { $_.FullName.Replace("$out\", '') } }, Length |
    Format-Table -AutoSize

# A successful build proves nothing about loading. ACPluginLoader calls
# assembly.GetTypes(), so ONE unresolvable reference aborts the whole plugin with
# ReflectionTypeLoadException, and the message names the missing assembly rather
# than the plugin at fault. The refs are therefore read back and checked against
# the freshly built host assemblies — assembly version to assembly version, since
# a package version is not an assembly version (YamlDotNet 16.2.1 ships an
# assembly stamped 16.0.0.0, and comparing against csproj gives false conflicts).
# A successful build proves nothing about loading. ACPluginLoader calls
# assembly.GetTypes(), so ONE unresolvable reference aborts the whole plugin with
# ReflectionTypeLoadException, and the message names the missing assembly rather
# than the plugin at fault. The refs are therefore read back and checked against
# the freshly built host assemblies — assembly version to assembly version, since
# a package version is not an assembly version (YamlDotNet 16.2.1 ships an
# assembly stamped 16.0.0.0, and comparing against csproj gives false conflicts).
$checker = Join-Path $PSScriptRoot 'asmrefs'

# AssettoServer is an Exe with a RID, so its output nests the RID one level
# deeper than a plain library would. Search rather than guess the path.
$hostDlls = Get-ChildItem (Join-Path $src 'AssettoServer\bin') -Recurse -Filter 'AssettoServer*.dll' `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in 'AssettoServer.dll', 'AssettoServer.Shared.dll' } |
    Select-Object -ExpandProperty FullName

if ((Test-Path $checker) -and $hostDlls) {
    Write-Host ""
    Write-Host "Assembly references:" -ForegroundColor Cyan
    Push-Location $checker
    try {
        # The checker is pinned to net9.0 and reads metadata for any TFM, so it
        # uses the system dotnet rather than the RC one the plugin needed.
        $refArgs = @('run', '-c', 'Release', '--')
        $refArgs += (Join-Path $out 'GhostProPlugin.dll')
        $refArgs += $hostDlls
        & dotnet @refArgs
        if ($LASTEXITCODE -ne 0) {
            throw "assembly reference check failed - do not deploy this build"
        }
    }
    finally {
        Pop-Location
    }
}
elseif (-not $hostDlls) {
    Write-Warning "host assemblies not found under src\AssettoServer\bin - refs not verified"
}

Write-Host ""
Write-Host "Deploy $out to <server>\plugins\GhostProPlugin" -ForegroundColor Green