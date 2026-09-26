$workflow = ConvertFrom-Yaml (Get-Content (Join-Path $PSScriptRoot '..\.github\workflows\release.yml') -Raw)
$checkScript = [scriptblock]::Create($workflow.jobs.check.steps[0].run)
$buildScript = [scriptblock]::Create($workflow.jobs.build.steps[0].run.Replace('${{ secrets.GITHUB_TOKEN }}', 'test-token'))
$hash = '0123456789abcdef' * 4

function Test-Check {
    param($Status, $Digest, [switch]$DownloadFails)

    $result = [pscustomobject]@{ Output = ''; Failed = $false }
    $outputPath = Join-Path $TestDrive "$([guid]::NewGuid()).txt"
    [System.IO.File]::WriteAllText($outputPath, "`n", [System.Text.UTF8Encoding]::new($true))
    $previousOutput = $env:GITHUB_OUTPUT
    $env:GITHUB_OUTPUT = $outputPath

    function Invoke-WebRequest {
        param($Uri, $OutFile, $Headers, [switch]$SkipHttpErrorCheck)

        if ($OutFile) {
            if ($DownloadFails) { throw 'Download failed' }
            return
        }
        $content = @{ assets = @(
            @{ name = 'other.exe'; digest = "sha256:$hash" },
            @{ name = 'Setup.Microsoft.PowerAutomate.exe'; digest = $Digest }
        ) } | ConvertTo-Json -Depth 4
        [pscustomobject]@{ StatusCode = $Status; Content = $content }
    }
    function Get-FileHash { [pscustomobject]@{ Hash = $hash.ToUpperInvariant() } }

    try {
        try {
            if ($env:CHECK_SCRIPT_FILE) { & $env:CHECK_SCRIPT_FILE } else { & $checkScript }
        } catch {
            $result.Failed = $true
        }
        $result.Output = (Get-Content $outputPath -Raw).Trim()
    } finally {
        $env:GITHUB_OUTPUT = $previousOutput
    }
    $result
}

function Test-Build {
    param($Status, [switch]$PostFails)

    $result = [pscustomobject]@{ Posts = 0; Failed = $false }
    function Invoke-WebRequest {
        param($Uri, $OutFile, $Method, $Headers, [switch]$SkipHttpErrorCheck)

        if ($Method -eq 'Head') { return [pscustomobject]@{ StatusCode = $Status } }
    }
    function Get-Item { [pscustomobject]@{ VersionInfo = [pscustomobject]@{ ProductVersion = '1.2.3' } } }
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $Body, $InFile)

        $result.Posts++
        if ($PostFails) { throw 'Release creation failed' }
        [pscustomobject]@{ id = 123 }
    }

    try {
        if ($env:BUILD_SCRIPT_FILE) { & $env:BUILD_SCRIPT_FILE | Out-Null } else { & $buildScript | Out-Null }
    } catch {
        $result.Failed = $true
    }
    $result
}

Describe 'Release workflow' {
    It 'only runs the release on schedule when the installer changes' {
        $workflow.jobs.check.if | Should Be "github.event_name == 'schedule'"
        $workflow.jobs.build.needs | Should Be 'check'
        $workflow.jobs.build.if | Should Be "needs.check.outputs.changed == 'true'"
    }
    It 'skips Windows when the published asset matches' {
        $result = Test-Check 200 "sha256:$hash"
        $result.Output | Should Be ''
        $result.Failed | Should Be $false
    }
    It 'checks the version when the digest differs or is missing' {
        foreach ($digest in @('sha256:different', $null)) {
            $result = Test-Check 200 $digest
            $result.Output | Should Be 'changed=true'
            $result.Failed | Should Be $false
        }
    }
    It 'checks the version when no release exists' {
        $result = Test-Check 404 $null
        $result.Output | Should Be 'changed=true'
        $result.Failed | Should Be $false
    }
    It 'fails preflight on API and download errors' {
        $result = Test-Check 403 $null
        $result.Output | Should Be ''
        $result.Failed | Should Be $true
        $result = Test-Check 200 "sha256:$hash" -DownloadFails
        $result.Output | Should Be ''
        $result.Failed | Should Be $true
    }
    It 'skips creating an existing release' {
        $result = Test-Build 200
        $result.Posts | Should Be 0
        $result.Failed | Should Be $false
    }
    It 'creates a release and uploads its asset when the tag is new' {
        $result = Test-Build 404
        $result.Posts | Should Be 2
        $result.Failed | Should Be $false
    }
    It 'fails when the release lookup or creation fails' {
        $result = Test-Build 403
        $result.Posts | Should Be 0
        $result.Failed | Should Be $true
        $result = Test-Build 404 -PostFails
        $result.Posts | Should Be 1
        $result.Failed | Should Be $true
    }
}
