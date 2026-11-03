<#
.SYNOPSIS
    Manifest-driven target application engine (targets/*.json). Counterpart of lib/apply_targets.py.

.DESCRIPTION
    Implements the SAME contract as the Python engine, reading the same manifests.
    Two engines exist intentionally: Windows does not depend on Python (workstations may not
    have Python guaranteed), and Unix does not depend on PowerShell.

    Pure PowerShell 5.1: no '?.', no ternary operator, no '??'.

.PARAMETER TargetHome
    Target user HOME directory. Not named -Home ($Home is an automatic variable).

.NOTES
    Exit codes: 0 ok | 1 failure or missing privileges | 2 usage error
    | 3 valid selection with no matching targets (phase skipped)

.EXAMPLE
    .\lib\ApplyTargets.ps1 -Root . -Scope machine
    .\lib\ApplyTargets.ps1 -Root . -Scope user -TargetHome C:\Users\alice -DryRun
#>
[CmdletBinding()]
param(
    [string]   $Root = ".",
    [ValidateSet("user", "machine", "all")]
    [string]   $Scope = "all",
    [string]   $TargetHome,
    [ValidateSet("windows", "linux", "darwin")]
    [string]   $OsKey,
    # Selectors: all | tool (claude, codex, antigravity, vscode)
    # | group (managed) | target id. Default all.
    [string[]] $Only = @("all"),
    [switch]   $ListTargets,
    [switch]   $DryRun
)

$ErrorActionPreference = "Stop"

# --- output ------------------------------------------------------------------
function Info($m)   { Write-Host "[INFO] $m"  -ForegroundColor Green }
function Warn($m)   { Write-Host "[WARN] $m"  -ForegroundColor Yellow }
function Err($m)    { Write-Host "[ERROR] $m" -ForegroundColor Red }
function Detail($m) { Write-Host "       $m"  -ForegroundColor DarkGray }

# --- helpers -----------------------------------------------------------------

function Get-CurrentOs {
    if ($null -eq $PSVersionTable.Platform -or $PSVersionTable.Platform -eq "Win32NT") {
        return "windows"
    }
    if ($IsMacOS) { return "darwin" }
    return "linux"
}

function Test-IsAdmin {
    if ((Get-CurrentOs) -ne "windows") {
        return ((id -u) -eq 0)
    }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $normalized = $Content -replace "`r`n", "`n"
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $enc)
}

function Write-OrPreview {
    param([string]$Path, [string]$Content, [bool]$Dry, [string]$Verbo = "would write")
    if ($Dry) {
        Detail "[dry-run] $Verbo $Path ($($Content.Length) bytes)"
        return
    }
    Write-Utf8NoBom -Path $Path -Content $Content
}

function Read-TextFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

# --- deterministic JSON serialization (replaces ConvertTo-Json) --------------

function ConvertTo-JsonString {
    <#
      String escaping matching json.dumps(ensure_ascii=False): only mandatory
      escapes (quotes, backslash, named control characters) and \uXXXX for
      characters below 0x20. Non-ASCII is preserved literally.
    #>
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($ch -eq "`n") { [void]$sb.Append('\n') }
        elseif ($ch -eq "`r") { [void]$sb.Append('\r') }
        elseif ($ch -eq "`t") { [void]$sb.Append('\t') }
        elseif ($ch -eq "`b") { [void]$sb.Append('\b') }
        elseif ($ch -eq "`f") { [void]$sb.Append('\f') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-JsonValue {
    <#
      Deterministic JSON serializer. Formats identically to Python
      json.dumps(obj, indent=2, ensure_ascii=False) + "`n".
    #>
    param($Obj, [int]$Level = 0)

    $pad = ' ' * (2 * $Level)
    $padIn = ' ' * (2 * ($Level + 1))

    if ($null -eq $Obj) { return 'null' }
    if ($Obj -is [bool]) { if ($Obj) { return 'true' } else { return 'false' } }
    if ($Obj -is [string]) { return (ConvertTo-JsonString $Obj) }
    if ($Obj -is [int] -or $Obj -is [long] -or $Obj -is [int64]) {
        return $Obj.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Obj -is [double] -or $Obj -is [decimal] -or $Obj -is [single]) {
        return ([double]$Obj).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Count -eq 0) { return '{}' }
        $parts = @()
        foreach ($k in $Obj.Keys) {
            $parts += ($padIn + (ConvertTo-JsonString ([string]$k)) + ': ' +
                       (ConvertTo-JsonValue $Obj[$k] ($Level + 1)))
        }
        return "{`n" + ($parts -join ",`n") + "`n" + $pad + '}'
    }

    if ($Obj -is [System.Collections.IEnumerable]) {
        $items = @($Obj)
        if ($items.Count -eq 0) { return '[]' }
        $parts = @()
        foreach ($it in $items) {
            $parts += ($padIn + (ConvertTo-JsonValue $it ($Level + 1)))
        }
        return "[`n" + ($parts -join ",`n") + "`n" + $pad + ']'
    }

    return (ConvertTo-JsonString ([string]$Obj))
}

function ConvertTo-JsonText {
    param($Obj)
    return (ConvertTo-JsonValue $Obj 0) + "`n"
}

function ConvertTo-OrderedHashtable {
    param($Obj)
    if ($null -eq $Obj) { return $null }

    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $dict = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($prop in $Obj.PSObject.Properties) {
            $dict[$prop.Name] = ConvertTo-OrderedHashtable $prop.Value
        }
        return $dict
    }

    if ($Obj -is [System.Collections.IDictionary]) {
        $dict = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($k in $Obj.Keys) {
            $dict[$k] = ConvertTo-OrderedHashtable $Obj[$k]
        }
        return $dict
    }

    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($elem in $Obj) {
            [void]$list.Add((ConvertTo-OrderedHashtable $elem))
        }
        return ,$list
    }

    return $Obj
}

# --- path and payload resolution ----------------------------------------------

function Set-PayloadByOs {
    param($Spec, [string]$HomeDir, [string]$Os)

    if ($Spec.PSObject.Properties.Name -contains "payload_file_by_os") {
        if (-not ($Spec.payload_file_by_os.PSObject.Properties.Name -contains $Os)) {
            throw "payload_file_by_os does not define OS '$Os'"
        }
        $Spec | Add-Member -NotePropertyName "payload_file" -NotePropertyValue $Spec.payload_file_by_os.$Os -Force
    }
    if (-not ($Spec.PSObject.Properties.Name -contains "payload_by_os")) { return }

    foreach ($prop in $Spec.payload_by_os.PSObject.Properties) {
        $dotted = $prop.Name
        $variantes = $prop.Value
        if (-not ($variantes.PSObject.Properties.Name -contains $Os)) {
            throw "payload_by_os['$dotted'] does not define OS '$Os'"
        }
        $valor = Expand-PathToken -Template $variantes.$Os -HomeDir $HomeDir -Os $Os

        $partes = $dotted.Split(".")
        $no = $Spec.payload
        if ($null -eq $no) {
            throw "payload_by_os requires a 'payload' object (target missing payload?)"
        }
        for ($i = 0; $i -lt ($partes.Count - 1); $i++) {
            $seg = $partes[$i]
            if (-not ($no.PSObject.Properties.Name -contains $seg)) {
                throw "payload_by_os: '$dotted' not found in payload (stopped at '$seg')"
            }
            $no = $no.$seg
        }
        $ultima = $partes[$partes.Count - 1]
        if (-not ($no.PSObject.Properties.Name -contains $ultima)) {
            throw "payload_by_os: '$dotted' not found in payload"
        }
        $no.$ultima = $valor
    }
}

function Expand-PathToken {
    param([string]$Template, [string]$HomeDir, [string]$Os)

    if ($Template.Contains('${HOME}') -and -not $HomeDir) {
        throw "template requires HOME and no -TargetHome was provided"
    }

    if ($Os -eq "windows") {
        $appdata = ""
        if ($HomeDir) { $appdata = Join-Path $HomeDir "AppData\Roaming" }
        $prog    = $env:ProgramFiles
        if (-not $prog) { $prog = "C:\Program Files" }
        $pdata   = $env:ProgramData
        if (-not $pdata) { $pdata = "C:\ProgramData" }
    } else {
        $appdata = ""
        if ($HomeDir) { $appdata = Join-Path $HomeDir ".config" }
        $prog    = "/usr/local"
        $pdata   = "/etc"
    }

    $out = $Template
    $out = $out.Replace('${HOME}',         $HomeDir)
    $out = $out.Replace('${APPDATA}',      $appdata)
    $out = $out.Replace('${PROGRAMFILES}', $prog)
    $out = $out.Replace('${PROGRAMDATA}',  $pdata)

    if ($Template.Contains('${APPDATA}') -and -not $HomeDir) {
        throw "template requires APPDATA (derived from HOME) and no -TargetHome was provided"
    }

    if ($out.Contains('${')) {
        throw "unexpanded token in '$Template' -> '$out'"
    }

    if ($Os -eq "windows") { $out = $out.Replace("/", "\") }
    return $out
}

function Backup-File {
    param([string]$Path, [bool]$Dry)
    if (-not (Test-Path $Path)) { return }
    $dst = "$Path.bak"
    if ($Dry) { Detail "[dry-run] backup -> $dst"; return }
    Copy-Item -Path $Path -Destination $dst -Force
    Detail "backup -> $(Split-Path -Leaf $dst)"
}

function Read-JsonTolerant {
    param([string]$Path, [bool]$TolerateJsonc)

    $raw = Read-TextFile $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{ Ok = $true; Data = (New-Object System.Collections.Specialized.OrderedDictionary) }
    }
    try {
        $parsed = $raw | ConvertFrom-Json
        return @{ Ok = $true; Data = (ConvertTo-OrderedHashtable $parsed) }
    } catch {
        if ($TolerateJsonc) {
            Warn "  $(Split-Path -Leaf $Path) is not strict JSON (comments?) -- preserved without modification"
            Detail "parse: $($_.Exception.Message)"
            return @{ Ok = $false; Data = $null }
        }
        throw "invalid JSON in ${Path}: $($_.Exception.Message)"
    }
}

function Merge-UniqueList {
    param($Existing, $Incoming)
    $out  = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($i in $Existing) { [void]$out.Add($i); [void]$seen.Add([string]$i) }
    foreach ($i in $Incoming) {
        if (-not $seen.Contains([string]$i)) { [void]$out.Add($i); [void]$seen.Add([string]$i) }
    }
    return ,$out
}

# --- strategies --------------------------------------------------------------

function Invoke-Remove {
    param($Spec, $Dst, $RootDir, $Dry)
    if (-not (Test-Path -LiteralPath $Dst -PathType Leaf)) {
        return "absent -- nothing to remove"
    }
    if ($Dry) { return "would remove (no longer distributed)" }
    Remove-Item -LiteralPath $Dst -Force
    return "file removed (no longer distributed)"
}

function Invoke-Overwrite {
    param($Spec, [string]$Dst, [string]$RootDir, [bool]$Dry)

    if ($Spec.PSObject.Properties.Name -contains "payload_file") {
        $src = Join-Path $RootDir $Spec.payload_file
        if (-not (Test-Path $src)) { throw "payload_file not found: $($Spec.payload_file)" }
        $content = Read-TextFile $src
        if ($Spec.format -eq "json") {
            try { $null = $content | ConvertFrom-Json }
            catch { throw "payload_file $($Spec.payload_file) is not valid JSON: $($_.Exception.Message)" }
        }
    } else {
        $content = ConvertTo-JsonText (ConvertTo-OrderedHashtable $Spec.payload)
    }

    $doBackup = $true
    if ($Spec.PSObject.Properties.Name -contains "backup") { $doBackup = [bool]$Spec.backup }
    if ($doBackup) { Backup-File -Path $Dst -Dry $Dry }

    Write-OrPreview -Path $Dst -Content $content -Dry $Dry
    return "written (overwrite)"
}

function Invoke-MergePermissionLists {
    param($Spec, [string]$Dst, [string]$RootDir, [bool]$Dry)

    $parent  = $Spec.list_parent
    $lists   = @($Spec.lists)
    $payload = ConvertTo-OrderedHashtable $Spec.payload.$parent

    if (-not (Test-Path $Dst)) {
        $content = ConvertTo-JsonText (ConvertTo-OrderedHashtable $Spec.payload)
        Write-OrPreview -Path $Dst -Content $content -Dry $Dry -Verbo "would create"
        return "created"
    }

    $tolerate = $false
    if ($Spec.PSObject.Properties.Name -contains "tolerate_jsonc") { $tolerate = [bool]$Spec.tolerate_jsonc }
    $res = Read-JsonTolerant -Path $Dst -TolerateJsonc $tolerate
    if (-not $res.Ok) { return "preserved (parse failed)" }
    $data = $res.Data

    Backup-File -Path $Dst -Dry $Dry

    if (-not $data.Contains($parent)) {
        $data[$parent] = New-Object System.Collections.Specialized.OrderedDictionary
    }
    $block = $data[$parent]

    $added = 0
    foreach ($name in $lists) {
        if (-not $payload.Contains($name)) { continue }
        $incoming = @($payload[$name])
        if ($incoming.Count -eq 0) { continue }
        $before = @()
        if ($block.Contains($name)) { $before = @($block[$name]) }
        $merged = Merge-UniqueList -Existing $before -Incoming $incoming
        $added += ($merged.Count - $before.Count)
        $block[$name] = $merged
    }

    foreach ($k in $payload.Keys) {
        if ($lists -notcontains $k) { $block[$k] = $payload[$k] }
    }

    $content = ConvertTo-JsonText $data
    Write-OrPreview -Path $Dst -Content $content -Dry $Dry
    return "merged (+$added rules)"
}

function Invoke-MergeMcp {
    param($Spec, [string]$Dst, [string]$RootDir, [bool]$Dry)

    $key = "mcpServers"
    if ($Spec.PSObject.Properties.Name -contains "mcp_key") { $key = $Spec.mcp_key }
    $payload = ConvertTo-OrderedHashtable $Spec.payload.$key

    if (-not (Test-Path $Dst)) {
        $content = ConvertTo-JsonText (ConvertTo-OrderedHashtable $Spec.payload)
        Write-OrPreview -Path $Dst -Content $content -Dry $Dry -Verbo "would create"
        return "created"
    }

    $res = Read-JsonTolerant -Path $Dst -TolerateJsonc $false
    if (-not $res.Ok) { return "preserved (parse failed)" }
    $data = $res.Data

    Backup-File -Path $Dst -Dry $Dry

    if (-not $data.Contains($key)) {
        $data[$key] = New-Object System.Collections.Specialized.OrderedDictionary
    }
    $servers = $data[$key]
    foreach ($k in $payload.Keys) { $servers[$k] = $payload[$k] }

    $content = ConvertTo-JsonText $data
    Write-OrPreview -Path $Dst -Content $content -Dry $Dry
    return "merged ($($payload.Count) servers)"
}

function Invoke-MergeMissingKeys {
    param($Spec, [string]$Dst, [string]$RootDir, [bool]$Dry)

    $payload = ConvertTo-OrderedHashtable $Spec.payload

    if (-not (Test-Path $Dst)) {
        $content = ConvertTo-JsonText $payload
        Write-OrPreview -Path $Dst -Content $content -Dry $Dry -Verbo "would create"
        return "created"
    }

    $tolerate = $false
    if ($Spec.PSObject.Properties.Name -contains "tolerate_jsonc") { $tolerate = [bool]$Spec.tolerate_jsonc }
    $res = Read-JsonTolerant -Path $Dst -TolerateJsonc $tolerate
    if (-not $res.Ok) { return "preserved (parse failed)" }
    $data = $res.Data

    Backup-File -Path $Dst -Dry $Dry

    $added = 0
    foreach ($k in $payload.Keys) {
        if (-not $data.Contains($k)) { $data[$k] = $payload[$k]; $added++ }
    }

    $content = ConvertTo-JsonText $data
    Write-OrPreview -Path $Dst -Content $content -Dry $Dry
    if ($added -eq 0) { return "unchanged (keys already present)" }
    return "merged (+$added keys)"
}

function Remove-MdBlock {
    param($Spec, [string]$Dst, [bool]$Dry)

    if (-not (Test-Path $Dst)) { return $null }

    $existing = Read-TextFile $Dst
    $marker = $Spec.marker
    $first = $existing.IndexOf($marker)
    if ($first -lt 0) { return $null }

    $second = $existing.IndexOf($marker, $first + $marker.Length)
    if ($second -lt 0) {
        Warn "  unclosed marker in $(Split-Path -Leaf $Dst) -- block NOT removed"
        return $null
    }

    $end = $second + $marker.Length
    $before = $existing.Substring(0, $first).TrimEnd("`r", "`n")
    $after = $existing.Substring($end).TrimStart("`r", "`n")
    if ($before -and $after) {
        $content = "$before`n`n$after"
    } else {
        $content = ("$before`n$after").TrimStart("`r", "`n")
    }
    Write-OrPreview -Path $Dst -Content $content -Dry $Dry -Verbo "would remove block from"
    return "block removed"
}

function Invoke-MdBlock {
    param($Spec, [string]$Dst, [string]$RootDir, [bool]$Dry)

    $marker = $Spec.marker
    $parts = New-Object System.Collections.ArrayList
    foreach ($rel in @($Spec.compose)) {
        $src = Join-Path $RootDir $rel
        if (-not (Test-Path $src)) { throw "compose file not found: $rel" }
        [void]$parts.Add((Read-TextFile $src).TrimEnd("`r", "`n"))
    }
    $body  = [string]::Join("`n`n---`n`n", $parts.ToArray())
    $block = "$marker`n$body`n$marker`n"

    if (-not (Test-Path $Dst)) {
        Write-OrPreview -Path $Dst -Content $block -Dry $Dry -Verbo "would create"
        return "created"
    }

    $existing = Read-TextFile $Dst
    $first = $existing.IndexOf($marker)
    if ($first -ge 0) {
        $second = $existing.IndexOf($marker, $first + $marker.Length)
        if ($second -ge 0) {
            $end = $second + $marker.Length
            $head = $existing.Substring(0, $first).TrimEnd("`r", "`n")
            $tail = $existing.Substring($end).TrimStart("`r", "`n")
            $content = "$head`n`n$block$tail"
            Write-OrPreview -Path $Dst -Content $content -Dry $Dry -Verbo "would update block in"
            return "block updated"
        }
        Warn "  unclosed opening marker in $(Split-Path -Leaf $Dst) -- appending new block"
    }

    $content = $existing.TrimEnd("`r", "`n") + "`n`n" + $block
    Write-OrPreview -Path $Dst -Content $content -Dry $Dry -Verbo "would append block in"
    return "block appended"
}

function Get-DryRunResult {
    param([string]$Result)
    switch -Regex ($Result) {
        '^written \(overwrite\)$' { return 'would overwrite' }
        '^created$' { return 'would create' }
        '^merged' { return ('would merge' + $Result.Substring(6)) }
        '^block updated$' { return 'would update block' }
        '^block appended$' { return 'would append block' }
        '^block removed$' { return 'would remove block' }
        '^file removed' { return 'would remove file (no longer distributed)' }
        default { return $Result }
    }
}

# --- execution ---------------------------------------------------------------

function Invoke-Preflight {
    param($Target, [string]$HomeDir, [string]$Os)
    if ($Target.PSObject.Properties.Name -notcontains "preflight") { return }
    foreach ($check in @($Target.preflight)) {
        if ($check.type -ne "warn-if-exists") { continue }
        if ($check.path.PSObject.Properties.Name -notcontains $Os) { continue }
        try {
            $p = Expand-PathToken -Template $check.path.$Os -HomeDir $HomeDir -Os $Os
        } catch {
            Detail "preflight not verified (no HOME in this run): $($check.path.$Os)"
            continue
        }
        if (Test-Path $p) { Warn "  $(Split-Path -Leaf $p): $($check.message)" }
    }
}

function Invoke-Target {
    param($Target, [string]$RootDir, [string]$HomeDir, [string]$Os, [bool]$Dry)

    $files = @()
    foreach ($f in @($Target.files)) {
        if ($f.dest.PSObject.Properties.Name -contains $Os) { $files += $f }
    }
    if ($files.Count -eq 0) {
        return @{ Ok = 0; Fail = 0; SkipOs = 1; SkipAdmin = 0 }
    }

    $tag = ""
    if ($Target.PSObject.Properties.Name -contains "enforcement") {
        if ($Target.enforcement.PSObject.Properties.Name -contains $Os) {
            if ($Target.enforcement.$Os -eq "hard")     { $tag = " [enforcement: managed]" }
            if ($Target.enforcement.$Os -eq "advisory") { $tag = " [advisory: user editable]" }
        }
    }
    Info "$($Target.label)$tag"

    if ($Target.requires_admin -and -not (Test-IsAdmin) -and -not $Dry) {
        Warn "  lacks Admin privilege -- target SKIPPED (config was not applied)"
        return @{ Ok = 0; Fail = 0; SkipOs = 0; SkipAdmin = $files.Count }
    }

    Invoke-Preflight -Target $Target -HomeDir $HomeDir -Os $Os

    $ok = 0
    $fail = 0
    foreach ($spec in $files) {
        $dst = Expand-PathToken -Template $spec.dest.$Os -HomeDir $HomeDir -Os $Os

        if ($spec.PSObject.Properties.Name -contains "superseded_by") {
            $sup = $spec.superseded_by
            if (-not ($sup.PSObject.Properties.Name -contains $Os)) {
                Err "  superseded_by does not define OS '$Os'"
                $fail++
                continue
            }
            $supPath = Expand-PathToken -Template $sup.$Os -HomeDir $HomeDir -Os $Os
            if (Test-Path $supPath) {
                $res = Remove-MdBlock -Spec $spec -Dst $dst -Dry $Dry
                if ($res) {
                    Info "  OK $dst"
                    Detail "$res -- superseded by $supPath"
                    $ok++
                } else {
                    Detail "skipped: already covered by $supPath"
                }
                continue
            }
        }

        if ($spec.PSObject.Properties.Name -contains "only_if_parent_exists") {
            if ($spec.only_if_parent_exists) {
                $parent = Split-Path -Parent $dst
                if (-not (Test-Path $parent)) {
                    Detail "skipped (does not exist): $parent"
                    continue
                }
            }
        }

        Set-PayloadByOs -Spec $spec -HomeDir $HomeDir -Os $Os

        try {
            $msg = switch ($spec.strategy) {
                "overwrite"              { Invoke-Overwrite            -Spec $spec -Dst $dst -RootDir $RootDir -Dry $Dry }
                "remove"                 { Invoke-Remove               -Spec $spec -Dst $dst -RootDir $RootDir -Dry $Dry }
                "merge-permission-lists" { Invoke-MergePermissionLists -Spec $spec -Dst $dst -RootDir $RootDir -Dry $Dry }
                "merge-mcp"              { Invoke-MergeMcp             -Spec $spec -Dst $dst -RootDir $RootDir -Dry $Dry }
                "merge-missing-keys"     { Invoke-MergeMissingKeys     -Spec $spec -Dst $dst -RootDir $RootDir -Dry $Dry }
                "md-block"               { Invoke-MdBlock              -Spec $spec -Dst $dst -RootDir $RootDir -Dry $Dry }
                default                  { throw "unknown strategy: $($spec.strategy)" }
            }
            if ($Dry) { $msg = Get-DryRunResult -Result $msg }
            Info "  OK $dst"
            Detail $msg
            $ok++
        } catch {
            Err "  FAIL $dst"
            Detail $_.Exception.Message
            $fail++
        }
    }

    if ($Target.PSObject.Properties.Name -contains "notes") {
        foreach ($n in @($Target.notes)) { Detail "note: $n" }
    }

    return @{ Ok = $ok; Fail = $fail; SkipOs = 0; SkipAdmin = 0 }
}

function Get-TargetNames {
    param($Target)
    $names = New-Object 'System.Collections.Generic.HashSet[string]'
    [void]$names.Add($Target.id)
    if ($Target.PSObject.Properties.Name -contains "selectors") {
        foreach ($s in @($Target.selectors)) { [void]$names.Add([string]$s) }
    }
    return $names
}

# --- main --------------------------------------------------------------------

$RootDir = (Resolve-Path $Root).Path
$TargetsDir = Join-Path $RootDir "targets"
if (-not (Test-Path $TargetsDir)) {
    Err "manifests directory not found: $TargetsDir"
    exit 2
}

$allTargets = @()
$targetFiles = @(Get-ChildItem -Path $TargetsDir -Filter "*.json" | Sort-Object Name)
if ($targetFiles.Count -eq 0) {
    Err "no manifests found in $TargetsDir"
    exit 2
}

foreach ($file in $targetFiles) {
    try {
        $raw = Read-TextFile $file.FullName
        $t = $raw | ConvertFrom-Json
    } catch {
        Err "invalid manifest $($file.Name): $($_.Exception.Message)"
        exit 2
    }
    $expectedId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    if ($t.id -ne $expectedId) {
        Err "manifest $($file.Name): id '$($t.id)' does not match filename"
        exit 2
    }
    foreach ($req in @("label", "tool", "scope", "files")) {
        if (-not ($t.PSObject.Properties.Name -contains $req)) {
            Err "manifest $($file.Name): missing required field '$req'"
            exit 2
        }
    }
    $allTargets += $t
}

$validSelectors = New-Object 'System.Collections.Generic.HashSet[string]'
[void]$validSelectors.Add("all")
foreach ($t in $allTargets) {
    foreach ($n in (Get-TargetNames -Target $t)) { [void]$validSelectors.Add($n) }
}

if (-not $OsKey) { $OsKey = Get-CurrentOs }

if ($ListTargets) {
    Write-Host "Available targets (OS: $OsKey)`n" -ForegroundColor Cyan
    Write-Host ("  {0,-17} {1,-8} {2,-6} {3,-9} SELECTORS" -f "ID", "SCOPE", "ADMIN", "ENFORCE")
    Write-Host ("  " + ("-" * 76))
    $sortedTargets = @($allTargets | Sort-Object scope, id)
    foreach ($t in $sortedTargets) {
        $enf = "-"
        if ($t.PSObject.Properties.Name -contains "enforcement" -and
            $t.enforcement.PSObject.Properties.Name -contains $OsKey) {
            $enf = $t.enforcement.$OsKey
        }
        $avail = $false
        foreach ($f in @($t.files)) {
            if ($f.dest.PSObject.Properties.Name -contains $OsKey) { $avail = $true }
        }
        $adm = "no"
        if ($t.requires_admin) { $adm = "yes" }
        $sels = ((Get-TargetNames -Target $t) | Sort-Object) -join ", "
        $mark = ""
        if (-not $avail) { $mark = "   (not available on this OS)" }
        Write-Host ("  {0,-17} {1,-8} {2,-6} {3,-9} {4}{5}" -f $t.id, $t.scope, $adm, $enf, $sels, $mark)
    }
    Write-Host "`n  Groups: all (all targets), managed (all 3 enforcement targets),"
    Write-Host "          claude / codex / antigravity / vscode (by tool)"
    Write-Host "`n  Examples: -Only codex,antigravity    -Only managed    -Only claude-managed"
    exit 0
}

# --- Resolve -Only -------------------------------------------------------
$onlySet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($o in @($Only)) {
    foreach ($piece in ($o -split ",")) {
        $trimmed = $piece.Trim()
        if ($trimmed) { [void]$onlySet.Add($trimmed) }
    }
}
if ($onlySet.Count -eq 0) { [void]$onlySet.Add("all") }

# Unknown selectors abort (seletor desconhecido):
$badSel = @()
foreach ($o in $onlySet) { if (-not $validSelectors.Contains($o)) { $badSel += $o } }
if ($badSel.Count -gt 0) {
    Err "unknown selector (seletor desconhecido): $(($badSel | Sort-Object) -join ', ')"
    Err "valid: $((($validSelectors) | Sort-Object) -join ', ')"
    exit 2
}

$scopes = @("user", "machine")
if ($Scope -ne "all") { $scopes = @($Scope) }

$filtered = @()
foreach ($t in $allTargets) {
    if (-not $onlySet.Contains("all")) {
        $names = Get-TargetNames -Target $t
        $hit = $false
        foreach ($n in $names) { if ($onlySet.Contains($n)) { $hit = $true } }
        if (-not $hit) { continue }
    }
    $filtered += $t
}

$selected = @()
foreach ($t in $filtered) { if ($scopes -contains $t.scope) { $selected += $t } }

$needsHome = $false
foreach ($t in $selected) { if ($t.scope -eq "user") { $needsHome = $true } }
if ($needsHome -and -not $TargetHome) {
    Err "-TargetHome is required when a user-scope target is selected"
    exit 2
}
$HomeDir = ""
if ($TargetHome) { $HomeDir = $TargetHome.TrimEnd("\", "/") }

if ($selected.Count -eq 0) {
    Warn "no target matches -Only '$(($onlySet | Sort-Object) -join ',')' in scope '$Scope'"
    Write-Host "APPLY-TARGETS: DONE ok=0 fail=0 skip_os=0 skip_admin=0 selected=0"
    exit 3
}

if ($DryRun) { Warn "DRY-RUN: nothing will be written" }
$selDesc = "all"
if (-not $onlySet.Contains("all")) { $selDesc = (($onlySet | Sort-Object) -join ",") }
Write-Host "OS: $OsKey | scope: $($scopes -join ',') | only: $selDesc | targets: $($selected.Count)" -ForegroundColor Cyan

$inScopeTotal = 0
foreach ($t in $allTargets) { if ($scopes -contains $t.scope) { $inScopeTotal++ } }
if ($selected.Count -lt $inScopeTotal) {
    $selIds = @($selected | ForEach-Object { $_.id })
    $omitted = @($allTargets | Where-Object { $scopes -contains $_.scope -and $selIds -notcontains $_.id } | ForEach-Object { $_.id })
    Warn "PARTIAL INSTALLATION -- not selected: $(($omitted | Sort-Object) -join ', ')"
}
if ($HomeDir) { Write-Host "HOME: $HomeDir" -ForegroundColor Cyan }
Write-Host ""

$totOk = 0; $totFail = 0; $totSkipOs = 0; $totSkipAdmin = 0
foreach ($t in $selected) {
    $r = Invoke-Target -Target $t -RootDir $RootDir -HomeDir $HomeDir -Os $OsKey -Dry ([bool]$DryRun)
    $totOk += $r.Ok; $totFail += $r.Fail; $totSkipOs += $r.SkipOs; $totSkipAdmin += $r.SkipAdmin
    if (-not ($r.SkipOs -gt 0 -and $r.Ok -eq 0 -and $r.Fail -eq 0)) {
        Write-Host ""
    }
}

Write-Host "APPLY-TARGETS: DONE ok=$totOk fail=$totFail skip_os=$totSkipOs skip_admin=$totSkipAdmin selected=$($selected.Count)"

if ($totFail -gt 0) {
    Err "$totFail target(s) failed"
    exit 1
}
if ($totSkipAdmin -gt 0) {
    Err "$totSkipAdmin file(s) skipped due to missing privileges -- requested config was NOT applied"
    exit 1
}
exit 0
