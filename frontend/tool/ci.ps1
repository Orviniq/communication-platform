$ErrorActionPreference = 'Stop'

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable exited with code $LASTEXITCODE."
    }
}

Push-Location (Join-Path $PSScriptRoot '..')
try {
    Invoke-CheckedCommand 'flutter' @('pub', 'get', '--enforce-lockfile')
    & (Join-Path $PSScriptRoot 'generate.ps1')
    Invoke-CheckedCommand 'git' @('diff', '--exit-code', '--', 'lib')
    Invoke-CheckedCommand 'dart' @(
        'format',
        '--output=none',
        '--set-exit-if-changed',
        'lib',
        'test',
        'integration_test'
    )
    Invoke-CheckedCommand 'flutter' @(
        'analyze',
        '--fatal-infos',
        '--fatal-warnings'
    )
    Invoke-CheckedCommand 'flutter' @('test')
    Invoke-CheckedCommand 'flutter' @(
        'build',
        'apk',
        '--debug',
        '--flavor',
        'development',
        '--target',
        'lib/main_development.dart'
    )
    Invoke-CheckedCommand 'flutter' @(
        'build',
        'apk',
        '--release',
        '--flavor',
        'production',
        '--target',
        'lib/main_production.dart'
    )
    # Production must keep building and stay verifiable, while remaining
    # undistributable: unsigned, correctly identified, and free of the Beta MLS
    # core. Flutter copies this artifact without the "-unsigned" suffix the
    # Android build gave it, so the name alone is never evidence.
    Invoke-CheckedCommand 'bash' @(
        './tool/verify_release_apk.sh',
        '--production',
        'build/app/outputs/flutter-apk/app-production-release.apk'
    )
}
finally {
    Pop-Location
}
