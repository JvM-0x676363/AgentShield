# =============================================================================
# SERIALIZATION parity between both engines -- byte-for-byte.
#
# Section 7 of validate-config.py compares engines STRUCTURALLY: whether both
# implement the same strategies, whether both return exit code 3, etc.
# It previously never compared what they WRITE. And that was precisely where
# they diverged: PS 5.1 ConvertTo-Json uses indentation of 4, TWO spaces after
# colons, and progressive alignment on nested levels, compared to Python's
# json.dumps(indent=2). Identical content, different bytes.
#
# Why this matters even when JSON is valid on both sides: drift detection,
# file hashing across a fleet, and the post-installation verifier compare
# TEXT. With the discrepancy, every Windows host appeared divergent from
# every Linux host, hiding real differences in noise.
#
# Usage:  powershell -ExecutionPolicy Bypass -File tests\parity-json.ps1
# Output: stable summary line, exit 0/1.
# =============================================================================
[CmdletBinding()]
param([switch] $Quiet)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Engine = Join-Path $Root "lib\ApplyTargets.ps1"

# The engine terminates with 'exit 0', so dot-sourcing would terminate the process.
# Extract only function definitions via AST -- this ensures the test exercises
# real engine code rather than a stale copy.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Engine, [ref]$null, [ref]$null)
$fns = $ast.FindAll({
    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)
foreach ($f in $fns) { Invoke-Expression $f.Extent.Text }

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) {
    Write-Host "[WARN] python not found -- parity NOT verified" -ForegroundColor Yellow
    Write-Host "PARITY-JSON: DONE ok=0 fail=0 skipped=1"
    exit 0
}

function Show-Invisible {
    <#
      Makes invisible characters visible when separating two "identical" lines.
      The divergence that motivated this test was CRLF vs LF, where diagnostics
      printed '{' vs '{' -- technically accurate yet completely useless.
    #>
    param([string]$Line)
    $out = $Line.Replace("`r", '<CR>').Replace("`t", '<TAB>')
    return ($out -replace ' ', [char]0x00B7)
}

$ok = 0
$fail = 0

foreach ($mf in (Get-ChildItem (Join-Path $Root "targets") -Filter *.json | Sort-Object Name)) {
    $target = Get-Content $mf.FullName -Raw | ConvertFrom-Json
    $idx = -1
    foreach ($file in $target.files) {
        $idx++
        if (-not $file.PSObject.Properties.Name.Contains("payload")) { continue }

        $rotulo = "{0}[{1}] {2}" -f $target.id, $idx, $file.strategy

        # PS side: exact engine path (ordered hashtable -> text).
        $psText = ConvertTo-JsonText (ConvertTo-OrderedHashtable $file.payload)

        # Python side: engine's own dump_json, without reimplementation.
        $tmpIn = [IO.Path]::GetTempFileName()
        $tmpOut = [IO.Path]::GetTempFileName()
        try {
            # Payload goes to disk as JSON to avoid command-line escaping issues.
            [IO.File]::WriteAllText($tmpIn, ($file.payload | ConvertTo-Json -Depth 64),
                                    (New-Object Text.UTF8Encoding $false))
            $script = @"
import io, json, sys, os
sys.path.insert(0, os.path.join(r'$Root', 'lib'))
from apply_targets import dump_json
obj = json.load(io.open(r'$tmpIn', encoding='utf-8'))
io.open(r'$tmpOut', 'w', encoding='utf-8', newline='').write(dump_json(obj))
"@
            $tmpPy = [IO.Path]::GetTempFileName() + ".py"
            [IO.File]::WriteAllText($tmpPy, $script, (New-Object Text.UTF8Encoding $false))
            & $py.Source $tmpPy
            if ($LASTEXITCODE -ne 0) { throw "python failed in $rotulo" }
            $pyText = [IO.File]::ReadAllText($tmpOut)
            Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
        } finally {
            Remove-Item $tmpIn, $tmpOut -Force -ErrorAction SilentlyContinue
        }

        if ($psText -ceq $pyText) {
            $ok++
            if (-not $Quiet) {
                Write-Host ("  [OK  ] {0}  --  {1} chars identical" -f $rotulo, $psText.Length) -ForegroundColor Green
            }
        } else {
            $fail++
            Write-Host ("  [FAIL] {0}" -f $rotulo) -ForegroundColor Red
            Write-Host ("         ps={0} chars  py={1} chars" -f $psText.Length, $pyText.Length)
            # First diverging line: shows WHERE, not just that it diverged.
            $a = $psText -split "`n"
            $b = $pyText -split "`n"
            for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
                $la = if ($i -lt $a.Count) { $a[$i] } else { "<end>" }
                $lb = if ($i -lt $b.Count) { $b[$i] } else { "<end>" }
                if ($la -cne $lb) {
                    Write-Host ("         line {0}:" -f ($i + 1))
                    Write-Host ("           ps: {0}" -f (Show-Invisible $la))
                    Write-Host ("           py: {0}" -f (Show-Invisible $lb))
                    break
                }
            }
        }
    }
}

# =============================================================================
# payload_by_os: identical injection in both engines across all THREE OSes.
#
# Shared new logic across both engines is where differences emerge. Without this,
# a Set-PayloadByOs that resolved paths differently from apply_payload_by_os
# would pass unnoticed: the loop above compares RAW payload before injection.
# =============================================================================
foreach ($mf in (Get-ChildItem (Join-Path $Root "targets") -Filter *.json | Sort-Object Name)) {
    $target = Get-Content $mf.FullName -Raw | ConvertFrom-Json
    $idx = -1
    foreach ($file in $target.files) {
        $idx++
        if (-not $file.PSObject.Properties.Name.Contains("payload_by_os")) { continue }

        foreach ($osk in @("windows", "linux", "darwin")) {
            $rotulo = "{0}[{1}] payload_by_os/{2}" -f $target.id, $idx, $osk
            $lar = @{ windows = "C:\Users\x"; linux = "/home/x"; darwin = "/Users/x" }[$osk]

            # PS side: copy spec (Set-PayloadByOs mutates in place) + real engine.
            $copia = $file | ConvertTo-Json -Depth 64 | ConvertFrom-Json
            Set-PayloadByOs -Spec $copia -HomeDir $lar -Os $osk
            $psText = ConvertTo-JsonText (ConvertTo-OrderedHashtable $copia.payload)

            $tmpOut = [IO.Path]::GetTempFileName()
            $tmpPy = [IO.Path]::GetTempFileName() + ".py"
            try {
                $script = @"
import io, json, os, sys
sys.path.insert(0, os.path.join(r'$Root', 'lib'))
from apply_targets import apply_payload_by_os, dump_json
t = json.load(io.open(os.path.join(r'$Root', 'targets', '$($mf.Name)'), encoding='utf-8'))
spec = t['files'][$idx]
r = apply_payload_by_os(spec, r'$lar', '$osk')
io.open(r'$tmpOut', 'w', encoding='utf-8', newline='').write(dump_json(r['payload']))
"@
                [IO.File]::WriteAllText($tmpPy, $script, (New-Object Text.UTF8Encoding $false))
                & $py.Source $tmpPy
                if ($LASTEXITCODE -ne 0) { throw "python failed in $rotulo" }
                $pyText = [IO.File]::ReadAllText($tmpOut)
            } finally {
                Remove-Item $tmpOut, $tmpPy -Force -ErrorAction SilentlyContinue
            }

            if ($psText -ceq $pyText) {
                $ok++
                if (-not $Quiet) {
                    Write-Host ("  [OK  ] {0}  --  {1} chars identical" -f $rotulo, $psText.Length) -ForegroundColor Green
                }
            } else {
                $fail++
                Write-Host ("  [FAIL] {0}" -f $rotulo) -ForegroundColor Red
                Write-Host ("         ps={0} chars  py={1} chars" -f $psText.Length, $pyText.Length)
                $a = $psText -split "`n"
                $b = $pyText -split "`n"
                for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
                    $la = if ($i -lt $a.Count) { $a[$i] } else { "<end>" }
                    $lb = if ($i -lt $b.Count) { $b[$i] } else { "<end>" }
                    if ($la -cne $lb) {
                        Write-Host ("         line {0}:" -f ($i + 1))
                        Write-Host ("           ps: {0}" -f (Show-Invisible $la))
                        Write-Host ("           py: {0}" -f (Show-Invisible $lb))
                        break
                    }
                }
            }
        }
    }
}

Write-Host ""
if ($fail -gt 0) {
    Write-Host ("RESULT: {0} OK, {1} FAIL" -f $ok, $fail) -ForegroundColor Red
} else {
    Write-Host ("RESULT: {0} OK, {1} FAIL" -f $ok, $fail) -ForegroundColor Green
}
Write-Host "PARITY-JSON: DONE ok=$ok fail=$fail skipped=0"
if ($fail -gt 0) { exit 1 }
exit 0
