param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$OutDir,
    [ValidateSet('windows-amd64', 'windows-arm64', 'linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64')]
    [string[]]$Targets = @('windows-amd64', 'windows-arm64', 'linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$source = Join-Path $RepoRoot 'hooks/claude/native'
$destination = [IO.Path]::GetFullPath($OutDir)
if (Test-Path -LiteralPath $destination) { throw 'Output directory must not already exist.' }
$go = (Get-Command go -CommandType Application -ErrorAction Stop).Source
$settings = @{
    GOTOOLCHAIN = 'local'; GOPROXY = 'off'; GOSUMDB = 'off'; CGO_ENABLED = '0'
    GOENV = 'off'; GOWORK = 'off'; GOFLAGS = ''; GOEXPERIMENT = ''; GO111MODULE = 'on'
    GOOS = ''; GOARCH = ''; GOAMD64 = 'v1'; GOARM64 = 'v8.0'
    GOCACHE = (Join-Path $RepoRoot 'tmp/go-cache')
    GOMODCACHE = (Join-Path $RepoRoot 'tmp/go-mod-cache')
}
$previous = @{}
foreach ($name in $settings.Keys) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process')
}
$pushed = $false
try {
    Push-Location $source
    $pushed = $true
    $version = & $go version
    if ($LASTEXITCODE -ne 0) { throw 'Unable to identify Go toolchain.' }
    $hostTarget = & $go env GOHOSTOS GOHOSTARCH
    if ($LASTEXITCODE -ne 0) { throw 'Unable to identify build host.' }
    Write-Host '[INFO] Testing native guard on the build host.'
    & $go test -count=1 ./...
    if ($LASTEXITCODE -ne 0) { throw 'Native unit tests failed.' }
    $inputs = @('go.mod', 'main.go', 'main_test.go', 'README.md', 'Test-Pilot.ps1', 'test_pilot.py', 'HOST-VALIDATION.md', 'host-validation.template.json') | ForEach-Object {
        @{ name = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $source $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    New-Item -ItemType Directory -Path $destination | Out-Null
    $artifacts = @()
    foreach ($target in ($Targets | Select-Object -Unique)) {
        $parts = $target.Split('-')
        $env:GOOS = $parts[0]
        $env:GOARCH = $parts[1]
        $filename = 'secret-write-guard-' + $target
        if ($parts[0] -eq 'windows') { $filename += '.exe' }
        Write-Host "[INFO] Compiling $target (not a runtime validation)."
        $output = Join-Path $destination $filename
        & $go build -mod=readonly -buildvcs=false -trimpath -o $output .
        if ($LASTEXITCODE -ne 0) { throw "Build failed for $target. No complete manifest was produced." }
        $artifacts += @{
            target = $target; file = $filename
            sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
            bytes = (Get-Item -LiteralPath $output).Length
            compilation = 'passed'; runtime_validation = 'not_run'; claude_validation = 'not_run'
        }
    }
    foreach ($input in $inputs) {
        if ((Get-FileHash -LiteralPath (Join-Path $source $input.name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $input.sha256) {
            throw 'Source changed during build. Discard this pilot directory.'
        }
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination (Join-Path $destination 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $source 'README.md') -Destination (Join-Path $destination 'README.md')
    Copy-Item -LiteralPath (Join-Path $source 'Test-Pilot.ps1') -Destination (Join-Path $destination 'Test-Pilot.ps1')
    Copy-Item -LiteralPath (Join-Path $source 'test_pilot.py') -Destination (Join-Path $destination 'test_pilot.py')
    Copy-Item -LiteralPath (Join-Path $source 'HOST-VALIDATION.md') -Destination (Join-Path $destination 'HOST-VALIDATION.md')
    Copy-Item -LiteralPath (Join-Path $source 'host-validation.template.json') -Destination (Join-Path $destination 'host-validation.template.json')
    $manifest = [ordered]@{
        schema_version = 1; purpose = 'isolated-pilot'; production_ready = $false
        built_at_utc = [DateTime]::UtcNow.ToString('o'); toolchain = "$version"
        compiler_sha256 = (Get-FileHash -LiteralPath $go -Algorithm SHA256).Hash.ToLowerInvariant()
        host_unit_tests = @{ status = 'passed'; target = ($hostTarget -join '-') }
        source_files = $inputs; cgo_enabled = $false; artifacts = $artifacts
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $destination 'manifest.json') -Encoding UTF8
    Write-Host "[INFO] Pilot built: $destination"
} finally {
    if ($pushed) { Pop-Location }
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
}
