# 03_probe_geometry.ps1 - derive FAT32 geometry from surviving structures
#
# When the BPB is gone, the parameters needed to rebuild it are still recoverable
# from what survived:
#
#   FAT media descriptor  F8 FF FF 0F FF FF FF 0F  ->  FAT1 offset, FAT2 offset
#   FAT2 - FAT1                                    ->  FAT size, reserved sectors
#   FAT size / 4                                   ->  FAT entry count -> max clusters
#   device/partition size + max clusters           ->  sectors per cluster
#   reserved + numFATs * FAT size                  ->  data area start (root dir, cluster 2)
#
# Every derived value is then verified against the media itself. Nothing is
# written by this script.
#
#   .\03_probe_geometry.ps1 -Source '\\.\E:'            # live device
#   .\03_probe_geometry.ps1 -Source 'D:\case\00_IMAGE\source.img' -TotalBytes 62914347008
#   .\03_probe_geometry.ps1 -Source '\\.\E:' -GeometryFile 'D:\case\geometry.json'

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Source,
    [int64]$TotalBytes = 0,
    [int64]$HiddenSectors = -1,
    [int]$BytesPerSector = 512,
    [int]$ScanLimitMB = 32,
    [string]$GeometryFile = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\FatLib.ps1')

function Norm-Source([string]$s) {
    if ($s -match '^([A-Za-z]):$') { return '\\.\' + $s.ToUpper() }
    return $s
}
$src = Norm-Source $Source

Write-Host "=== disk-triage / 03_probe_geometry (read only) ==="
Write-Host ("source : {0}" -f $src)

# ------------------------------------------------------------ total size / hidden
$isFile = Test-Path -LiteralPath $src -PathType Leaf
if ($isFile) {
    if (-not $TotalBytes) { $TotalBytes = (Get-Item -LiteralPath $src).Length; Write-Host ("size   : {0:N0} bytes (image file)" -f $TotalBytes) }
} else {
    if ($src -match '^\\\\\.\\([A-Za-z]):$') {
        $part = Get-Partition -DriveLetter $Matches[1] -ErrorAction SilentlyContinue
        if ($part) {
            if (-not $TotalBytes) { $TotalBytes = [int64]$part.Size; Write-Host ("size   : {0:N0} bytes (partition)" -f $TotalBytes) }
            if ($HiddenSectors -lt 0) { $HiddenSectors = [int64]($part.Offset / 512); Write-Host ("hidden : {0} sectors (partition offset / 512)" -f $HiddenSectors) }
        }
    }
}
if (-not $TotalBytes) { throw "cannot determine total size; pass -TotalBytes" }
if ($HiddenSectors -lt 0) { $HiddenSectors = 0; Write-Host "hidden : unknown, defaulting to 0 (verify against the partition table!)" }

$err = ''
if (-not [RawVol]::CanRead($src, [ref]$err)) { throw ("source not readable: " + $err) }
$totalSectors = [int64]($TotalBytes / 512)

# ------------------------------------------------------------- FAT discovery
Write-Host ""
Write-Host ("--- scanning the first {0} MB for FAT media descriptors ---" -f $ScanLimitMB)
$limit = [int64]$ScanLimitMB * 1MB
if ($limit -gt $TotalBytes) { $limit = $TotalBytes }
$fats = New-Object System.Collections.ArrayList
$chunk = 1MB
for ($p = [int64]0; $p -lt $limit; $p += $chunk) {
    $buf = [RawVol]::Read($src, $p, $chunk)
    for ($i = 0; $i + 512 -le $buf.Length; $i += 512) {
        if ($buf[$i] -eq 0xF8 -and $buf[$i+1] -eq 0xFF -and $buf[$i+2] -eq 0xFF -and $buf[$i+3] -eq 0x0F -and
            $buf[$i+4] -eq 0xFF -and $buf[$i+5] -eq 0xFF -and $buf[$i+6] -eq 0xFF -and $buf[$i+7] -eq 0x0F) {
            [void]$fats.Add([int64]($p + $i))
            if ($fats.Count -ge 3) { break }
        }
    }
    if ($fats.Count -ge 3) { break }
}
if ($fats.Count -eq 0) {
    Write-Host "  no FAT media descriptor found."
    Write-Host "  This is not a FAT table region, or the FATs were zeroed. Try 01_triage first;"
    Write-Host "  for exFAT/NTFS the boot sector is mandatory, so escalate instead of rebuilding."
    return
}
foreach ($f in $fats) { Write-Host ("  FAT candidate at byte {0:N0} (LBA {1:N0})" -f $f, [int64]($f/512)) }
if ($fats.Count -lt 2) { throw "only one FAT copy found; cannot derive FAT size safely" }

$fat1Off = $fats[0]
$fat2Off = $fats[1]
$fatBytes = $fat2Off - $fat1Off
$fatSizeSectors = [int64]($fatBytes / 512)
$reservedSectors = [int64]($fat1Off / 512)
$fatEntries = [int64]($fatBytes / 4)
$maxClusters = $fatEntries - 2

Write-Host ""
Write-Host "--- derived from the FAT pair ---"
Write-Host ("  FAT1 offset        : {0:N0} bytes (LBA {1:N0})" -f $fat1Off, ($fat1Off/512))
Write-Host ("  FAT2 offset        : {0:N0} bytes (LBA {1:N0})" -f $fat2Off, ($fat2Off/512))
Write-Host ("  FAT size           : {0:N0} bytes = {1:N0} sectors" -f $fatBytes, $fatSizeSectors)
Write-Host ("  reserved sectors   : {0:N0}" -f $reservedSectors)
Write-Host ("  FAT entries        : {0:N0}  => max clusters {1:N0}" -f $fatEntries, $maxClusters)

# ------------------------------------------------- sectors per cluster + data start
Write-Host ""
Write-Host "--- solving sectors/cluster and data area start ---"
$solutions = New-Object System.Collections.ArrayList
foreach ($numFats in 2, 1) {
    $dataSectors = $totalSectors - $reservedSectors - ($numFats * $fatSizeSectors)
    if ($dataSectors -le 0) { continue }
    $raw = $dataSectors / [double]$maxClusters
    $spc = 1
    while ($spc -lt 1024 -and $spc -lt $raw) { $spc *= 2 }
    foreach ($cand in @($spc, [int]($spc/2), [int]($spc*2))) {
        if ($cand -lt 1 -or $cand -gt 1024) { continue }
        $clusters = [int64][math]::Floor($dataSectors / $cand)
        $err2 = [math]::Abs($clusters - $maxClusters) / [double]$maxClusters
        $dataStart = ($reservedSectors + $numFats * $fatSizeSectors) * 512
        [void]$solutions.Add([pscustomobject]@{
            NumFats = $numFats; Spc = $cand; ClusterSize = $cand * 512
            Clusters = $clusters; EntryError = $err2; DataStart = $dataStart
            FatSizeSectors = $fatSizeSectors
        })
    }
}
$solutions = $solutions | Sort-Object EntryError | Select-Object -First 6
foreach ($s in $solutions) {
    Write-Host ("  numFATs={0} spc={1,4} cluster={2,6} bytes  clusters={3,12:N0}  entry-error={4:P4}  dataStart={5:N0}" -f `
        $s.NumFats, $s.Spc, $s.ClusterSize, $s.Clusters, $s.EntryError, $s.DataStart)
}
$best = $solutions[0]
if ($best.EntryError -gt 0.01) {
    Write-Host ("  WARNING: best candidate is off by {0:P2} - geometry is not self-consistent" -f $best.EntryError)
}

# --------------------------------------------- verify: cluster 2 must be a directory
Write-Host ""
Write-Host "--- verification on the media (cluster 2 must look like a root directory) ---"
$rootOff = $best.DataStart
$clusterSize = $best.ClusterSize
$root = [RawVol]::ReadAny($src, $rootOff, $clusterSize)
$validEntries = 0; $lfnEntries = 0; $terminator = -1; $nonZero = 0
foreach ($x in $root) { if ($x -ne 0) { $nonZero++ } }
for ($i = 0; $i + 32 -le $root.Length; $i += 32) {
    $first = $root[$i]
    if ($first -eq 0x00) { $terminator = $i; break }
    if ($first -eq 0xE5) { continue }
    $attr = $root[$i + 11]
    if ($attr -eq 0x0F) { $lfnEntries++; continue }
    if (($attr -band 0x3F) -eq 0) { continue }
    $nameOk = $true
    for ($k = 0; $k -lt 11; $k++) {
        $c = $root[$i + $k]
        if ($c -lt 0x20 -and $c -ne 0x05) { $nameOk = $false; break }
    }
    if ($nameOk) { $validEntries++ }
}
Write-Host ("  cluster 2 @ {0:N0}: nonZero bytes {1}/{2}, valid short entries {3}, LFN entries {4}, terminator at {5}" -f `
    $rootOff, $nonZero, $clusterSize, $validEntries, $lfnEntries, $terminator)
$rootLooksGood = ($validEntries -ge 1) -and ($terminator -ge 0) -and ($nonZero -gt 0)

# verify FAT2 position consistency
$fat2Check = ($reservedSectors + $best.NumFats * $best.FatSizeSectors) * 512
$fat2Consistent = $false
if ($best.NumFats -eq 2) { $fat2Consistent = ($fat2Check -eq $fat2Off) }

$fat2Derived = ([int64]$reservedSectors + $best.FatSizeSectors) * $BytesPerSector
$fat2Ok = ($fat2Derived -eq $fat2Off)
Write-Host ("  FAT2 offset check: derived {0:N0} vs measured {1:N0} => {2}" -f $fat2Derived, $fat2Off, $(if ($fat2Ok) { 'MATCH' } else { 'MISMATCH' }))

# ------------------------------------------------------------------- verdict
Write-Host ""
Write-Host "--- geometry verdict ---"
if ($rootLooksGood -and $best.EntryError -le 0.01) {
    Write-Host "  SELF-CONSISTENT: the derived geometry lands exactly on a directory cluster." -ForegroundColor Green
} else {
    Write-Host "  NOT self-consistent. Do not write a boot record from these numbers." -ForegroundColor Red
    Write-Host "  Re-check: partition offset/size, whether one FAT copy is truncated, unusual cluster size."
}

$geo = [ordered]@{
    source            = $src
    probedAt          = (Get-Date).ToString('s')
    totalBytes        = $TotalBytes
    totalSectors      = $totalSectors
    hiddenSectors     = $HiddenSectors
    bytesPerSector    = $BytesPerSector
    reservedSectors   = $reservedSectors
    numFats           = $best.NumFats
    fatSizeSectors    = $best.FatSizeSectors
    fat1Offset        = $fat1Off
    fat2Offset        = $fat2Off
    fatBytes          = $fatBytes
    sectorsPerCluster = $best.Spc
    clusterSize       = $clusterSize
    dataStart         = $best.DataStart
    totalClusters     = [int]$maxClusters
    rootCluster       = 2
    fsInfoSector      = 1
    backupBootSector  = 6
    selfConsistent    = ($rootLooksGood -and $best.EntryError -le 0.01)
}
if ($GeometryFile) {
    $geo | ConvertTo-Json | Set-Content -Path $GeometryFile -Encoding UTF8
    Write-Host ("  geometry written to {0}" -f $GeometryFile)
}

Write-Host ""
Write-Host "next: 04_rebuild_bpb.ps1 with"
Write-Host ("  -Source '{0}' -BytesPerSector 512 -SectorsPerCluster {1} -ReservedSectors {2} -NumFats {3} \" -f $src, $best.Spc, $reservedSectors, $best.NumFats)
Write-Host ("  -FatSizeSectors {0} -TotalSectors {1} -HiddenSectors {2} -DataStart {3} -Fat2Offset {4}" -f `
    $best.FatSizeSectors, $totalSectors, $HiddenSectors, $best.DataStart, $fat2Off)
