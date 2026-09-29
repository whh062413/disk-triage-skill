# 05_walk_and_validate.ps1 - walk the directory tree and arbitrate FAT1 vs FAT2
#
# Produces the evidence that decides what is actually recoverable:
#   * every file with its declared size and first cluster
#   * for each file: does the FAT1 chain match the size? does the FAT2 chain?
#   * files where BOTH copies fail          -> rescue candidates (06)
#   * files where only FAT1 fails           -> Windows may have copied these WRONG
#   * FAT1/FAT2 conflict ranges             -> where the mirror diverged
#
# READ ONLY.
#
#   .\05_walk_and_validate.ps1 -Source '\\.\E:' -GeometryFile 'D:\case\geometry.json' -ReportDir 'D:\case\30_REPORT'

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Source,
    [string]$GeometryFile = '',
    [int]$BytesPerSector = 512,
    [int]$SectorsPerCluster = 0,
    [int64]$ReservedSectors = 0,
    [int]$NumFats = 2,
    [int64]$FatSizeSectors = 0,
    [int64]$DataStart = 0,
    [int64]$Fat2Offset = 0,
    [int]$TotalClusters = 0,
    [int]$RootCluster = 2,
    [string]$ReportDir = '',
    [int]$ListLimit = 40
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\FatLib.ps1')

function Norm-Source([string]$s) { if ($s -match '^([A-Za-z]):$') { return '\\.\' + $s.ToUpper() }; return $s }
$src = Norm-Source $Source

if ($GeometryFile) {
    if (-not (Test-Path $GeometryFile)) { throw ("geometry file not found: " + $GeometryFile) }
    $g = Get-Content $GeometryFile -Raw | ConvertFrom-Json
    $BytesPerSector    = $g.bytesPerSector;    if (-not $BytesPerSector) { $BytesPerSector = 512 }
    $SectorsPerCluster = $g.sectorsPerCluster
    $ReservedSectors   = $g.reservedSectors
    $NumFats           = $g.numFats
    $FatSizeSectors    = $g.fatSizeSectors
    $DataStart         = $g.dataStart
    $Fat2Offset        = $g.fat2Offset
    $TotalClusters     = $g.totalClusters
    $RootCluster       = $g.rootCluster
    Write-Host ("geometry loaded from {0}" -f $GeometryFile)
}

$fat1Offset = [int64]$ReservedSectors * $BytesPerSector
$fatBytes = [int64]$FatSizeSectors * $BytesPerSector
if (-not $Fat2Offset) { $Fat2Offset = $fat1Offset + $fatBytes }
if (-not $TotalClusters) { $TotalClusters = [int]($fatBytes / 4) }
$clusterSize = $SectorsPerCluster * $BytesPerSector

Write-Host "=== disk-triage / 05_walk_and_validate (read only) ==="
Write-Host ("source       : {0}" -f $src)
Write-Host ("geometry     : cluster={0} bytes  dataStart={1:N0}  FAT1={2:N0}  FAT2={3:N0}  clusters={4:N0}" -f `
    $clusterSize, $DataStart, $fat1Offset, $Fat2Offset, $TotalClusters)
if ($clusterSize -le 0 -or $DataStart -le 0 -or $TotalClusters -le 0) { throw "incomplete geometry; run 03_probe_geometry.ps1 or pass the parameters" }

$img = New-Object FatImage($src, $DataStart, $clusterSize, $fat1Offset, $Fat2Offset, $fatBytes, $TotalClusters)

# ------------------------------------------------------------ FAT divergence
$conf = 0
for ($i = 2; $i -lt $img.Conflict.Length; $i++) { if ($img.Conflict[$i]) { $conf++ } }
Write-Host ("FAT conflicts: {0:N0} entries differ between FAT1 and FAT2" -f $conf)
if ($conf -gt 0) {
    $ranges = New-Object System.Collections.ArrayList
    $inRun = $false; $runStart = 0
    for ($i = 2; $i -le $img.Conflict.Length; $i++) {
        $isConf = ($i -lt $img.Conflict.Length) -and $img.Conflict[$i]
        if ($isConf -and -not $inRun) { $inRun = $true; $runStart = $i }
        elseif (-not $isConf -and $inRun) {
            $inRun = $false
            [void]$ranges.Add([pscustomobject]@{ From = $runStart; To = $i - 1 })
        }
    }
    $shown = 0
    foreach ($r in $ranges) {
        if ($shown -ge 12) { Write-Host ("  ... and {0} more ranges" -f ($ranges.Count - 12)); break }
        $byteFrom = $DataStart + ([int64]$r.From - 2) * $clusterSize
        Write-Host ("  clusters {0,10:N0}..{1,-10:N0}  data offset {2:N0}" -f $r.From, $r.To, $byteFrom)
        $shown++
    }
}

# --------------------------------------------------------------------- walk
Write-Host ""
Write-Host "--- walking the directory tree ---"
$sw = [Diagnostics.Stopwatch]::StartNew()
$walker = New-Object TreeWalker($img, [uint32]$RootCluster)
$walker.Walk()
Write-Host ("  files={0:N0}  dirs={1:N0}  deleted marks={2:N0}  ({3:N0}s)" -f `
    $walker.Files.Count, $walker.Dirs.Count, $walker.DeletedEntries, $sw.Elapsed.TotalSeconds)
if ($walker.Issues.Count -gt 0) {
    Write-Host ("  walk issues: {0}" -f $walker.Issues.Count)
    $walker.Issues | Select-Object -First 10 | ForEach-Object { Write-Host ("    " + $_) }
}

# --------------------------------------------------------------- arbitration
$bothBad = New-Object System.Collections.ArrayList
$fat1OnlyBad = New-Object System.Collections.ArrayList
$fat2OnlyBad = New-Object System.Collections.ArrayList
$totalBytes = [int64]0
$clean = 0
foreach ($f in $walker.Files) {
    $totalBytes += $f.Size
    if ($f.Size -le 0) { $clean++; continue }
    if ($f.FirstCluster -lt 2) { [void]$bothBad.Add($f); continue }
    $need = [FatImage]::NeedClusters($f.Size, $clusterSize)
    $ok1 = ($f.Chain1Issue -eq '') -and ($f.Chain1Count -eq $need)
    $ok2 = ($f.Chain2Issue -eq '') -and ($f.Chain2Count -eq $need)
    if ($ok1 -and $ok2) { $clean++ }
    elseif (-not $ok1 -and -not $ok2) { [void]$bothBad.Add($f) }
    elseif (-not $ok1) { [void]$fat1OnlyBad.Add($f) }
    else { [void]$fat2OnlyBad.Add($f) }
}

Write-Host ""
Write-Host "--- chain validation (need = ceil(size / clusterSize)) ---"
Write-Host ("  declared total bytes     : {0:N0} ({1:N2} GB)" -f $totalBytes, ($totalBytes/1GB))
Write-Host ("  chains consistent        : {0:N0}" -f $clean)
Write-Host ("  BOTH FAT copies invalid  : {0:N0}   <- rescue with 06_rescue.ps1" -f $bothBad.Count)
Write-Host ("  only FAT1 invalid        : {0:N0}   <- Windows (FAT1) may have copied these wrong" -f $fat1OnlyBad.Count)
Write-Host ("  only FAT2 invalid        : {0:N0}   <- benign for Windows, FAT2 lags" -f $fat2OnlyBad.Count)

foreach ($set in @(@{n='BOTH FAT copies invalid'; l=$bothBad}, @{n='FAT1 invalid (FAT2 usable)'; l=$fat1OnlyBad})) {
    if ($set.l.Count -eq 0) { continue }
    Write-Host ""
    Write-Host ("--- {0} (first {1}) ---" -f $set.n, [math]::Min($ListLimit, $set.l.Count))
    $set.l | Select-Object -First $ListLimit | ForEach-Object {
        Write-Host ("  {0,-46} size={1,12:N0}  FC={2,-9} FAT1={3,-6} FAT2={4,-6}" -f $_.Name, $_.Size, $_.FirstCluster, $_.Chain1Count, $_.Chain2Count)
    }
}

# ------------------------------------------------------------------ reports
if ($ReportDir) {
    if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null }
    $csv = New-Object System.Text.StringBuilder
    [void]$csv.AppendLine('path,type,size,firstCluster,clustersFat1,clustersFat2,issueFat1,issueFat2,verdict')
    foreach ($f in $walker.Files) {
        $need = [FatImage]::NeedClusters($f.Size, $clusterSize)
        $ok1 = ($f.Chain1Issue -eq '') -and ($f.Chain1Count -eq $need)
        $ok2 = ($f.Chain2Issue -eq '') -and ($f.Chain2Count -eq $need)
        $verdict = 'ok'
        if ($f.Size -le 0) { $verdict = 'empty' }
        elseif ($f.FirstCluster -lt 2) { $verdict = 'bad-first-cluster' }
        elseif ($ok1 -and $ok2) { $verdict = 'ok' }
        elseif (-not $ok1 -and -not $ok2) { $verdict = 'broken-both' }
        elseif (-not $ok1) { $verdict = 'broken-fat1' }
        else { $verdict = 'broken-fat2' }
        [void]$csv.AppendLine(('"{0}",FILE,{1},{2},{3},{4},"{5}","{6}",{7}' -f `
            ($f.Path -replace '"','""'), $f.Size, $f.FirstCluster, $f.Chain1Count, $f.Chain2Count,
            ($f.Chain1Issue -replace '"','""'), ($f.Chain2Issue -replace '"','""'), $verdict))
    }
    $p = Join-Path $ReportDir '05_filelist.csv'
    [System.IO.File]::WriteAllText($p, $csv.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ""
    Write-Host ("report: {0}  ({1:N0} rows)" -f $p, $walker.Files.Count)

    $pl = New-Object System.Text.StringBuilder
    [void]$pl.AppendLine('name,path,size,firstCluster,issueFat1,issueFat2')
    foreach ($f in ($bothBad + $fat1OnlyBad)) {
        [void]$pl.AppendLine(('"{0}","{1}",{2},{3},"{4}","{5}"' -f `
            ($f.Name -replace '"','""'), ($f.Path -replace '"','""'), $f.Size, $f.FirstCluster,
            ($f.Chain1Issue -replace '"','""'), ($f.Chain2Issue -replace '"','""')))
    }
    $pp = Join-Path $ReportDir '05_problems.csv'
    [System.IO.File]::WriteAllText($pp, $pl.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("problems: {0}" -f $pp)
}

$img.Close()
Write-Host ""
Write-Host "nothing was written to the source."
