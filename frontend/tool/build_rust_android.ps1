param(
    [ValidateSet('all', 'arm64-v8a', 'armeabi-v7a', 'x86_64')]
    [string]$Abi = 'all',
    [ValidateSet('foundation')]
    [string]$CryptoProfile = 'foundation'
)

$ErrorActionPreference = 'Stop'

$frontendRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildScript = Join-Path $PSScriptRoot 'build_rust_android.sh'
$gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
$pathBash = (Get-Command 'bash.exe' -ErrorAction SilentlyContinue).Source
$bashCandidates = @(
    $env:BASH_EXE,
    $gitBash,
    $pathBash
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

if ($bashCandidates.Count -eq 0) {
    throw 'A POSIX shell is required to build the pinned libsodium source. Install Git for Windows or set BASH_EXE.'
}

$bash = $bashCandidates[0]
$shellScript = & $bash -lc "cygpath -u '$($buildScript.Replace("'", "'\''"))'"
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to resolve the Android Rust build script for the POSIX shell.'
}

Push-Location $frontendRoot
try {
    & $bash $shellScript $Abi $CryptoProfile
    if ($LASTEXITCODE -ne 0) {
        throw "Android Rust build exited with code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
