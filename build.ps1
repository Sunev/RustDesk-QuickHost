param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateSet('x86', 'x64')]
    [string]$Platform = 'x86',

    [string]$OutputDir = '',

    [switch]$DryRun,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Write-Host "Usage: .\build.ps1 [-Configuration Debug|Release] [-Platform x86|x64] [-OutputDir path] [-DryRun]"
    Write-Host ""
    Write-Host "This script builds the C++ sources under src/ with MSVC tools."
    Write-Host "For Windows XP compatibility, use -Platform x86. The script will automatically use the v141_xp toolset and XP-compatible linker settings for that build."
    Write-Host "It expects Visual Studio Build Tools or Visual Studio with cl.exe available."
    Write-Host "If you have external deps such as libyuv/vpx/sodium/zstd in non-standard locations,"
    Write-Host "set LIBYUV_ROOT, VPX_ROOT, SODIUM_ROOT, and ZSTD_ROOT before running."
    exit 0
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir = Join-Path $repoRoot 'src'

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot ("build\{0}-{1}" -f $Configuration.ToLowerInvariant(), $Platform)
}

if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $buildDir = [System.IO.Path]::GetFullPath($OutputDir)
} else {
    $buildDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDir))
}
if (-not (Test-Path $buildDir)) {
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
}

$exeName = 'RustDeskQS.exe'
$exePath = Join-Path $buildDir $exeName

$archArg = if ($Platform -eq 'x86') { 'x86' } else { 'x64' }
$machineArg = if ($Platform -eq 'x86') { '/MACHINE:X86' } else { '/MACHINE:X64' }

# ============================================================
# Include directories
# ============================================================
$includeDirs = @(
    $srcDir
)

# ============================================================
# Vcpkg bootstrap
# ============================================================
$vcpkgRoot = Join-Path $repoRoot 'third_party\vcpkg'
$vcpkgBootstrap = Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat'
if (-not (Test-Path $vcpkgBootstrap)) {
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($gitCommand) {
        Write-Host '[build] Bootstrapping vcpkg under third_party\vcpkg'
        New-Item -ItemType Directory -Path $vcpkgRoot -Force | Out-Null
        & $gitCommand.Source clone --depth 1 https://github.com/microsoft/vcpkg.git $vcpkgRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone vcpkg into $vcpkgRoot."
        }
    } else {
        throw "git.exe was not found. Install Git or place a prebuilt vcpkg under third_party\vcpkg."
    }
}

if (-not (Test-Path $vcpkgBootstrap)) {
    throw "Unable to find $vcpkgBootstrap."
}

if (-not (Test-Path (Join-Path $vcpkgRoot 'vcpkg.exe'))) {
    Write-Host '[build] Bootstrapping vcpkg toolchain'
    & cmd.exe /d /c "$vcpkgBootstrap"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to bootstrap vcpkg."
    }
}

$env:VCPKG_ROOT = $vcpkgRoot
# ============================================================
# For x86 XP builds, use a custom v141xp triplet
# The triplet is defined in third_party/vcpkg_overlays/triplets/
# ============================================================
$vcpkgTriplet = if ($Platform -eq 'x86') { 'x86-windows-static-v141xp' } else { 'x64-windows-static' }
$env:VCPKG_DEFAULT_TRIPLET = $vcpkgTriplet

$overlayTripletsPath = Join-Path $repoRoot 'third_party\vcpkg_overlays\triplets'
if ($Platform -eq 'x86') {
    Write-Host '[build] Using x86-windows-static-v141xp triplet for Windows XP compatibility'
}

$vcpkgExe = Join-Path $vcpkgRoot 'vcpkg.exe'

# ============================================================
# Detect Visual Studio environment
# ============================================================
$vcvarsPath = $null
$vcvarsFound = $false
$vswherePath = $null
$vsInstallPath = $null

function Find-VsWhere {
    $vsWherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWherePath) {
        return $vsWherePath
    }
    $vsWhereCmd = Get-Command vswhere.exe -ErrorAction SilentlyContinue
    if ($vsWhereCmd) {
        return $vsWhereCmd.Source
    }
    return $null
}

$vswherePath = Find-VsWhere
if ($vswherePath) {
    $vsInstallOutput = (& $vswherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if ($LASTEXITCODE -eq 0 -and $vsInstallOutput) {
        $vsInstallPath = $vsInstallOutput.Trim()
    }

    if (-not $vsInstallPath) {
        $vsInstallOutput = (& $vswherePath -latest -products * -property installationPath)
        if ($LASTEXITCODE -eq 0 -and $vsInstallOutput) {
            $vsInstallPath = $vsInstallOutput.Trim()
        }
    }
}

if ($vsInstallPath) {
    $candidateVcvars = Join-Path $vsInstallPath 'VC\Auxiliary\Build\vcvarsall.bat'
    if (Test-Path $candidateVcvars) {
        $vcvarsPath = $candidateVcvars
        $vcvarsFound = $true
    }
}

if (-not $vcvarsFound) {
    $fallback = $env:VCToolsInstallDir
    if ($fallback -and (Test-Path $fallback)) {
        $candidateVcvars = Join-Path $fallback '..\..\Auxiliary\Build\vcvarsall.bat'
        if (Test-Path $candidateVcvars) {
            $vcvarsPath = $candidateVcvars
            $vcvarsFound = $true
            $resolvedPath = Resolve-Path (Join-Path $fallback '..\..\..\..')
            if ($resolvedPath) {
                $vsInstallPath = $resolvedPath.Path
                Write-Host "[build] Derived VS install path from VCToolsInstallDir: $vsInstallPath"
            }
        }
    }
}

if (-not $vcvarsFound) {
    $clCommand = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($clCommand) {
        $vcvarsFound = $true
        $vcvarsPath = $null
    }
}

# ============================================================
# When invoking vcvarsall.bat, add -vcvars_ver=14.16 for x86 platform
# This activates the v141_xp toolset, making cl.exe and link.exe produce XP-compatible code
# ============================================================
$vcvarsCommandPrefix = ''
if ($vcvarsPath) {
    $vcvarsArgs = $archArg
    if ($Platform -eq 'x86') {
        $vcvarsArgs += ' -vcvars_ver=14.16'
    }
    $vcvarsCommandPrefix = '"{0}" {1} && ' -f $vcvarsPath, $vcvarsArgs
}

# ============================================================
# Update include directory probe paths, adding x86-windows-static-v141xp
# ============================================================
$thirdPartyProbeDirs = @(
    (Join-Path $repoRoot 'third_party\libyuv\include'),
    (Join-Path $repoRoot 'third_party\libvpx\include'),
    (Join-Path $repoRoot 'third_party\vcpkg\installed\x86-windows-static-v141xp\include'),
    (Join-Path $repoRoot 'third_party\vcpkg\installed\x86-windows-static\include'),
    (Join-Path $repoRoot 'third_party\vcpkg\installed\x64-windows-static\include'),
    (Join-Path $repoRoot 'third_party\vcpkg_installed\x86-windows-static\include'),
    (Join-Path $repoRoot 'third_party\vcpkg_installed\x64-windows-static\include')
)

foreach ($probeDir in $thirdPartyProbeDirs) {
    if ((Test-Path $probeDir) -and (-not ($includeDirs -contains $probeDir))) {
        $includeDirs += $probeDir
    }
}

if ($env:LIBYUV_ROOT) {
    $includeDirs += (Join-Path $env:LIBYUV_ROOT 'include')
}
if ($env:VPX_ROOT) {
    $includeDirs += (Join-Path $env:VPX_ROOT 'include')
}
if ($env:SODIUM_ROOT) {
    $includeDirs += (Join-Path $env:SODIUM_ROOT 'include')
}
if ($env:ZSTD_ROOT) {
    $includeDirs += (Join-Path $env:ZSTD_ROOT 'include')
}

# ============================================================
# Check third-party dependency headers
# All dependencies are now managed through vcpkg (libyuv, libvpx, libsodium, zstd)
# ============================================================
$requiredHeaders = @(
    @{ Header = 'libyuv/convert.h'; Name = 'libyuv' },
    @{ Header = 'vpx/vpx_encoder.h'; Name = 'libvpx' },
    @{ Header = 'sodium.h'; Name = 'libsodium' },
    @{ Header = 'zstd.h'; Name = 'zstd' }
)

$missingDependencies = @()
foreach ($headerSpec in $requiredHeaders) {
    $found = $false
    foreach ($includeDir in $includeDirs) {
        if (Test-Path (Join-Path $includeDir $headerSpec.Header)) {
            $found = $true
            break
        }
    }

    if (-not $found) {
        $missingDependencies += $headerSpec.Name
    }
}

if ($missingDependencies.Count -gt 0) {
    $requiredVcpkgPackages = @('libyuv', 'libvpx', 'libsodium', 'zstd')
    $overlayPortsPath = Join-Path $repoRoot 'third_party\vcpkg_overlays\ports'
    Write-Host "[build] Installing missing vcpkg dependencies: $($requiredVcpkgPackages -join ', ')"

    $vcpkgArgs = @('install', '--triplet', $vcpkgTriplet, '--overlay-ports', $overlayPortsPath, '--overlay-triplets', $overlayTripletsPath) + $requiredVcpkgPackages
    if ($vcvarsPath) {
        $vcpkgCommandLine = ('{0}"{1}" {2}' -f $vcvarsCommandPrefix, $vcpkgExe, ($vcpkgArgs -join ' '))
        & cmd.exe /d /c $vcpkgCommandLine
    } else {
        & $vcpkgExe @vcpkgArgs
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install required vcpkg dependencies for: $($missingDependencies -join ', ')."
    }

    # Scan all installed triplet include directories (v141xp, x86-static, x64-static, etc.)
    $installedRoot = Join-Path $vcpkgRoot 'installed'
    if (Test-Path $installedRoot) {
        Get-ChildItem -Path $installedRoot -Directory | ForEach-Object {
            $candidateIncludeDir = Join-Path $_.FullName 'include'
            if ((Test-Path $candidateIncludeDir) -and (-not ($includeDirs -contains $candidateIncludeDir))) {
                $includeDirs += $candidateIncludeDir
            }
        }
    }

    $missingDependencies = @()
    foreach ($headerSpec in $requiredHeaders) {
        $found = $false
        foreach ($includeDir in $includeDirs) {
            if (Test-Path (Join-Path $includeDir $headerSpec.Header)) {
                $found = $true
                break
            }
        }

        if (-not $found) {
            $missingDependencies += $headerSpec.Name
        }
    }

    if ($missingDependencies.Count -gt 0) {
        throw "Missing required dependency headers for: $($missingDependencies -join ', '). Place them under third_party or set the matching *_ROOT environment variables (LIBYUV_ROOT, VPX_ROOT, SODIUM_ROOT, ZSTD_ROOT)."
    }
}

# ============================================================
# Step 2: Build main project
# ============================================================

$sourceFiles = @(
    'main.cpp',
    'portable_host.cpp',
    'xp_fls_compat.cpp'
)

$compileFlags = @(
    '/nologo',
    '/utf-8',
    '/std:c++17',
    '/EHsc',
    '/W3',
    '/DWIN32',
    '/D_WINDOWS',
    '/DUNICODE',
    '/D_UNICODE'
)

$xpToolsetAvailable = $false

if ($Platform -eq 'x86') {
    $compileFlags += '/D_WIN32_WINNT=0x0501', '/DWINVER=0x0501'

    if ($vsInstallPath) {
        $candidateRoot = Join-Path $vsInstallPath 'VC\Tools\MSVC'
        if (Test-Path $candidateRoot) {
            $candidateVersions = Get-ChildItem -Path $candidateRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^14\.([1-9]?[0-9])(\.\d+)?$' }
            if ($candidateVersions) {
                $xpToolsetAvailable = $true
                Write-Host "[build] Detected MSVC toolset version(s): $($candidateVersions.Name -join ', ')"
            }
        }
    } else {
        $fallback = $env:VCToolsInstallDir
        if ($fallback -and (Test-Path $fallback)) {
            $msvcRoot = Resolve-Path (Join-Path $fallback '..\..')
            if ($msvcRoot) {
                $candidateRoot = $msvcRoot.Path
                if (Test-Path $candidateRoot) {
                    $candidateVersions = Get-ChildItem -Path $candidateRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^14\.([1-9]?[0-9])(\.\d+)?$' }
                    if ($candidateVersions) {
                        $xpToolsetAvailable = $true
                        Write-Host "[build] Detected MSVC toolset version(s) from VCToolsInstallDir: $($candidateVersions.Name -join ', ')"
                    }
                }
            }
        }
    }

    if ($xpToolsetAvailable) {
        Write-Host '[build] Using v141_xp toolset for Windows XP compatibility'
    } else {
        Write-Warning 'v141_xp toolset was not detected. Install the VS 2017/2019 XP-compatible VC toolset if you need a Windows XP-compatible binary.'
    }
}

if ($Configuration -eq 'Debug') {
    $compileFlags += '/Od', '/Zi', '/MDd'
} else {
    $compileFlags += '/O2', '/MD', '/DNDEBUG'
}

# $srcDir is already included in $includeDirs, avoid duplication
$compileFlags += ($includeDirs | ForEach-Object { '/I"{0}"' -f $_ })

$objectFiles = @()

function Invoke-ToolCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    Write-Host "[build] $Description"
    Write-Host $CommandLine

    if ($DryRun) {
        return
    }

    $exitCode = 0
    & cmd.exe /d /c $CommandLine
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $CommandLine"
    }
}

if (-not $vcvarsFound) {
    throw "Unable to find MSVC toolchain. Install Visual Studio Build Tools and ensure cl.exe is available."
}

$clCommandLine = $vcvarsCommandPrefix

$resourceFile = Join-Path $srcDir 'portable_host.rc'

$sourceFiles | ForEach-Object {
    $sourcePath = Join-Path $srcDir $_
    $objPath = Join-Path $buildDir ([System.IO.Path]::GetFileNameWithoutExtension($_) + '.obj')
    $objectFiles += $objPath

    $compileCmd = ('{0}cl /c /Fo"{1}" {2} "{3}"' -f $clCommandLine, $objPath, ($compileFlags -join ' '), $sourcePath)
    Invoke-ToolCommand -Description ("Compiling {0}" -f $_) -CommandLine $compileCmd
}

if (Test-Path $resourceFile) {
    $resPath = Join-Path $buildDir 'portable_host.res'
    $rcCmd = ('{0}rc /nologo /fo"{1}" /I"{2}" "{3}"' -f $clCommandLine, $resPath, $srcDir, $resourceFile)
    Invoke-ToolCommand -Description 'Compiling resource file' -CommandLine $rcCmd
}

if ($DryRun) {
    Write-Host "Dry run completed. No files were built."
    exit 0
}

$linkLibs = @(
    'advapi32.lib',
    'comctl32.lib',
    'comdlg32.lib',
    'crypt32.lib',
    'gdi32.lib',
    'gdiplus.lib',
    'iphlpapi.lib',
    'mfuuid.lib',
    'ole32.lib',
    'oleaut32.lib',
    'shell32.lib',
    'user32.lib',
    'ws2_32.lib'
)

# ============================================================
# Update lib directory paths to match the new triplet names
# x86-windows-static-v141xp is used for XP-compatible builds
# All dependencies (libyuv, libvpx, libsodium, zstd) built via vcpkg
# ============================================================
$libDirs = @()
$libDirs += (Join-Path $repoRoot 'third_party\vcpkg\installed\x86-windows-static-v141xp\lib')
$libDirs += (Join-Path $repoRoot 'third_party\vcpkg\installed\x86-windows-static\lib')
$libDirs += (Join-Path $repoRoot 'third_party\vcpkg\installed\x64-windows-static\lib')
$linkLibs += 'yuv.lib', 'vpx.lib', 'libsodium.lib', 'zstd.lib'

# ============================================================
# Linker flags: critical settings for XP compatibility
# /subsystem:windows,5.01  →  Set Windows subsystem version to 5.01 (XP)
# /DYNAMICBASE:NO          →  Disable ASLR (not supported on XP)
# /NXCOMPAT:NO             →  Disable DEP compatibility flag (not supported on XP)
# ============================================================
$linkFlags = @('/nologo', '/subsystem:windows,5.01', $machineArg, '/NODEFAULTLIB:LIBCMT')
if ($Platform -eq 'x86') {
    $linkFlags += '/DYNAMICBASE:NO', '/NXCOMPAT:NO'
}

foreach ($libDir in ($libDirs | Select-Object -Unique)) {
    if (Test-Path $libDir) {
        $linkFlags += ('/LIBPATH:"{0}"' -f $libDir)
    }
}

$linkObjects = @($objectFiles)
if (Test-Path $resourceFile) {
    $linkObjects += (Join-Path $buildDir 'portable_host.res')
}

if ($Platform -eq 'x86') {
    $linkFlags += '/OPT:REF', '/OPT:ICF'
}

$linkCmd = ('{0}link {1} /OUT:"{2}" {3} {4}' -f $clCommandLine, ($linkFlags -join ' '), $exePath, ($linkObjects -join ' '), ($linkLibs -join ' '))
Invoke-ToolCommand -Description 'Linking executable' -CommandLine $linkCmd

if ($Configuration -eq 'Release') {
    Get-ChildItem -Path $buildDir -Filter '*.obj' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -Path $buildDir -Filter '*.res' -File -ErrorAction SilentlyContinue | Remove-Item -Force
}

Write-Host "Build completed: $exePath"