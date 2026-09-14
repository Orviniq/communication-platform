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
    # CI never holds the production key (ADR-076 D6). The release build asks for
    # an unsigned package explicitly, and every production signing variable is
    # removed from its environment, so a key in the caller's environment can
    # neither sign this artifact nor fail the build for asking for both. This
    # script runs in the caller's session, so the caller's values are put back
    # afterwards.
    $signingVariables = @(
        Get-ChildItem -Path 'Env:' | Where-Object {
            $_.Name -match '^CP_PRODUCTION_(KEYSTORE_|KEY_)' -or
            $_.Name -eq 'CP_PRODUCTION_SIGNING_PROPERTIES'
        }
    )
    $previousUnsignedRequest = $env:CP_PRODUCTION_UNSIGNED_BUILD
    try {
        foreach ($variable in $signingVariables) {
            Remove-Item -Path "Env:$($variable.Name)"
        }
        $env:CP_PRODUCTION_UNSIGNED_BUILD = '1'
        Invoke-CheckedCommand 'flutter' @(
            'build',
            'apk',
            '--release',
            '--flavor',
            'production',
            '--target',
            'lib/main_production.dart'
        )
    }
    finally {
        foreach ($variable in $signingVariables) {
            Set-Item -Path "Env:$($variable.Name)" -Value $variable.Value
        }
        if ($null -eq $previousUnsignedRequest) {
            Remove-Item -Path 'Env:CP_PRODUCTION_UNSIGNED_BUILD' -ErrorAction SilentlyContinue
        }
        else {
            $env:CP_PRODUCTION_UNSIGNED_BUILD = $previousUnsignedRequest
        }
    }
    # The unsigned artifact must still be the right application, declare only
    # what ADR-054 recorded, and lack the deleted beta MLS core. It is verified as
    # the unsigned CI artifact, never as a distributable one. Flutter copies it
    # without the "-unsigned" suffix the Android build gave it, so the name alone
    # is never evidence.
    Invoke-CheckedCommand 'bash' @(
        './tool/verify_release_apk.sh',
        '--production-unsigned',
        'build/app/outputs/flutter-apk/app-production-release.apk'
    )
}
finally {
    Pop-Location
}
