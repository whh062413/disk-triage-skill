# 06_rescue.ps1 - recover files whose FAT chains are destroyed
#
# Escalating strategies, all read-only on the source. The first one that produces a
# structurally valid file wins:
#
#   1. FAT2 chain       - the mirror copy is often intact where FAT1 is not
#   2. contiguous run   - camera/app writes are usually contiguous; accepted only
#                         if the file's own structure validates
#   3. truncate at EOI  - the head may be intact while the tail clusters are gone;
#                         a complete shorter JPEG is still a usable photo
#   4. valid fragment   - keep whatever the surviving chain covers, clearly named
#   5. fingerprint      - scan cluster-aligned starts around the recorded first
#                         cluster for one whose EOI lands exactly at start+size-2
#
#   .\06_rescue.ps1 -Source '\\.\E:' -GeometryFile 'D:\case\geometry.json' -OutDir 'D:\case\40_RESCUE' -AllBroken
#   .\06_rescue.ps1 -Source '\\.\E:' -GeometryFile 'D:\case\geometry.json' -OutDir 'D:\case\40_RESCUE' -Targets 'a.jpg,b.mp4'
#   .\06_rescue.ps1 -Source '\\.\E:' -GeometryFile '...json' -OutDir '...' -Targets 'D:\case\targets.txt'

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [string]$GeometryFile = '',
    [int]$BytesPerSector = 512,
    [int]$SectorsPerCluster = 0,
    [int64]$ReservedSectors = 0,
    [int64]$FatSizeSectors = 0,
    [int64]$DataStart = 0,
    [int64]$Fat2Offset = 0,
    [int]$TotalClusters = 0,
    [int]$RootCluster = 2,
    [string[]]$Targets = @(),
    [switch]$AllBroken,
    [int]$FingerprintRadius = 20000,
    [switch]$SkipFingerprint
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\FatLib.ps1')

# ------------------------------------------------------------------- helpers
function Norm-Source([string]$s) { if ($s -match '^([A-Za-z]):$') { return '\\.\' + $s.ToUpper() }; return $s }

function Test-Media([string]$path, [string]$name) {
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    $ext = [System.IO.Path]::GetExtension($name).ToLower()
    if ($ext -eq '.jpg' -or $ext -eq '.jpeg' -or $ext -eq '.png') {
        $note = ''
        return ([MediaAudit]::Jpeg($path, [ref]$note) + ' ' + $note)
    } elseif ($ext -eq '.mp4' -or $ext -eq '.mov') {
        return [MediaAudit]::Mp4($path)
    }
    return 'unknown-type'
}

function Write-FromChain($image, $chain, [int64]$size, [string]$path) {
    $o = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB)
    $buf = New-Object byte[] $image.ClusterSize
    $remain = $size
    foreach ($c in $chain) {
        if ($remain -le 0) { break }
        $want = [int][math]::Min([int64]$image.ClusterSize, $remain)
        $got = $image.ReadInto([uint32]$c, $buf, 0, $want)
        if ($got -le 0) { break }
        $o.Write($buf, 0, $got)
        $remain -= $got
    }
    $o.Flush($true); $o.Close()
    return ($size - $remain)
}

# Keep the bytes up to the first EOI found after SOS: a truncated-but-valid JPEG.
function Truncate-AtEoi([string]$src, [string]$dst) {
    $b = [System.IO.File]::ReadAllBytes($src)
    if ($b.Length -lt 4 -or $b[0] -ne 0xFF -or $b[1] -ne 0xD8) { return 0 }
    $sos = -1
    for ($i = 2; $i + 1 -lt $b.Length; $i++) { if ($b[$i] -eq 0xFF -and $b[$i+1] -eq 0xDA) { $sos = $i; break } }
    if ($sos -lt 0) { return 0 }
    for ($k = $sos + 2; $k + 1 -lt $b.Length; $k++) {
        if ($b[$k] -eq 0xFF -and $b[$k+1] -eq 0xD9) {
            $len = $k + 2
            [System.IO.File]::WriteAllBytes($dst, $b[0..($len-1)])
            return $len
        }
    }
    return 0
}

# ------------------------------------------------------------------- set up
$src = Norm-Source $Source
if ($GeometryFile) {
    $g = Get-Content $GeometryFile -Raw | ConvertFrom-Json
    $SectorsPerCluster = $g.sectorsPerCluster; $ReservedSectors = $g.reservedSectors
    $FatSizeSectors = $g.fatSizeSectors; $DataStart = $g.dataStart
    $Fat2Offset = $g.fat2Offset; $TotalClusters = $g.totalClusters; $RootCluster = $g.rootCluster
}
$fat1Offset = [int64]$ReservedSectors * $BytesPerSector
$fatBytes = [int64]$FatSizeSectors * $BytesPerSector
if (-not $Fat2Offset) { $Fat2Offset = $fat1Offset + $fatBytes }
if (-not $TotalClusters) { $TotalClusters = [int]($fatBytes / 4) }
$clusterSize = $SectorsPerCluster * $BytesPerSector
if ($clusterSize -le 0 -or $DataStart -le 0) { throw "incomplete geometry; run 03_probe_geometry.ps1 or pass the parameters" }

$targetNames = New-Object System.Collections.ArrayList
foreach ($t in $Targets) {
    if ($t -and (Test-Path -LiteralPath $t -PathType Leaf)) {
        Get-Content -LiteralPath $t | Where-Object { $_.Trim() } | ForEach-Object { [void]$targetNames.Add($_.Trim()) }
    } elseif ($t) {
        foreach ($piece in ($t -split ',')) { if ($piece.Trim()) { [void]$targetNames.Add($piece.Trim()) } }
    }
}
if (-not $AllBroken -and $targetNames.Count -eq 0) { throw "pass -AllBroken or -Targets" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

Write-Host "=== disk-triage / 06_rescue (read only on source) ==="
Write-Host ("source : {0}" -f $src)
Write-Host ("out    : {0}" -f $OutDir)
Write-Host ("cluster={0} bytes  dataStart={1:N0}" -f $clusterSize, $DataStart)

$img = New-Object FatImage($src, $DataStart, $clusterSize, $fat1Offset, $Fat2Offset, $fatBytes, $TotalClusters)
$walker = New-Object TreeWalker($img, [uint32]$RootCluster)
$walker.Walk()
Write-Host ("tree   : {0:N0} files" -f $walker.Files.Count)

$work = New-Object System.Collections.ArrayList
foreach ($f in $walker.Files) {
    if ($f.Size -le 0) { continue }
    $need = [FatImage]::NeedClusters($f.Size, $clusterSize)
    $ok1 = ($f.Chain1Issue -eq '') -and ($f.Chain1Count -eq $need)
    $ok2 = ($f.Chain2Issue -eq '') -and ($f.Chain2Count -eq $need)
    if ($AllBroken) {
        if (-not $ok1 -and -not $ok2) { [void]$work.Add($f) }
    } elseif ($targetNames -contains $f.Name) {
        [void]$work.Add($f)
    }
}
Write-Host ("targets: {0}" -f $work.Count)
if ($work.Count -eq 0) { Write-Host "nothing to do."; $img.Close(); return }

# ------------------------------------------------------------------ rescue
$carver = New-Object Carver($img)
$results = New-Object System.Collections.ArrayList
$n = 0
foreach ($f in $work) {
    $n++
    $need = [FatImage]::NeedClusters($f.Size, $clusterSize)
    $ok1 = ($f.Chain1Issue -eq '') -and ($f.Chain1Count -eq $need)
    $ok2 = ($f.Chain2Issue -eq '') -and ($f.Chain2Count -eq $need)
    Write-Host ""
    Write-Host ("[{0}/{1}] {2}  size={3:N0}  FC={4}  need={5}  FAT1={6} FAT2={7}" -f $n, $work.Count, $f.Name, $f.Size, $f.FirstCluster, $need, $f.Chain1Count, $f.Chain2Count)

    $outPath = Join-Path $OutDir $f.Name
    $method = ''; $verdict = 'not-attempted'; $issue = ''
    $ext = [System.IO.Path]::GetExtension($f.Name).ToLower()
    $isJpeg = ($ext -eq '.jpg' -or $ext -eq '.jpeg')

    if ($f.FirstCluster -lt 2 -or $f.FirstCluster -ge $TotalClusters) {
        Write-Host "    first cluster is not usable"
        [void]$results.Add([pscustomobject]@{ Name = $f.Name; Size = $f.Size; Method = 'none'; Verdict = 'no-first-cluster'; Note = '' })
        continue
    }

    # 1. FAT2 chain (only when FAT2 is the valid copy)
    if ($ok2 -and -not $ok1) {
        $chain = $img.Chain($f.FirstCluster, $true, [ref]$issue)
        $w = Write-FromChain $img $chain $f.Size $outPath
        $method = 'FAT2-chain'
        $verdict = Test-Media $outPath $f.Name
        Write-Host ("    FAT2 chain: {0} clusters, wrote {1:N0} bytes -> {2}" -f $chain.Count, $w, $verdict)
    }

    # 2. contiguous run
    if ($verdict -notlike 'OK*') {
        $err = ''
        $w = $carver.ReadContiguous($f.FirstCluster, $f.Size, $outPath, [ref]$err)
        $method = 'contiguous'
        $verdict = Test-Media $outPath $f.Name
        Write-Host ("    contiguous: wrote {0:N0} bytes -> {1} {2}" -f $w, $verdict, $err)
    }

    # 3. truncate at the first EOI (head intact, tail clusters gone)
    if (($verdict -notlike 'OK*') -and $isJpeg -and (Test-Path -LiteralPath $outPath)) {
        $partial = Join-Path $OutDir ([System.IO.Path]::GetFileNameWithoutExtension($f.Name) + '.partial.jpg')
        $len = Truncate-AtEoi $outPath $partial
        if ($len -gt 0) {
            $pv = Test-Media $partial $f.Name
            Write-Host ("    truncated at EOI: {0:N0} bytes -> {1}" -f $len, $pv)
            if ($pv -like 'OK*') { $method = 'truncate-at-EOI'; $verdict = $pv + ' [partial file kept]'; $outPath = $partial }
        }
    }

    # 4. keep the valid-chain fragment for the record
    if ($verdict -notlike 'OK*') {
        $fchain = $img.Chain($f.FirstCluster, $false, [ref]$issue)
        if ($fchain.Count -gt 0) {
            $fragPath = Join-Path $OutDir ($f.Name + '.fragment')
            $fw = Write-FromChain $img $fchain $f.Size $fragPath
            Write-Host ("    valid-chain fragment: {0} clusters, {1:N0} bytes (kept for the record)" -f $fchain.Count, $fw)
        }
    }

    # 5. fingerprint search
    if (($verdict -notlike 'OK*') -and (-not $SkipFingerprint) -and $isJpeg) {
        Write-Host ("    fingerprint search +/- {0} clusters ..." -f $FingerprintRadius)
        $found = [int64]-1
        $msg = $carver.FindJpegBySize($f.FirstCluster, $f.Size, $FingerprintRadius, $outPath, [ref]$found)
        Write-Host ("    {0}" -f $msg)
        if ($found -ge 0) { $method = 'fingerprint'; $verdict = Test-Media $outPath $f.Name }
    }

    Write-Host ("    => method={0}  verdict={1}" -f $method, $verdict)
    [void]$results.Add([pscustomobject]@{ Name = $f.Name; Size = $f.Size; Method = $method; Verdict = $verdict; Note = $issue })
}

# ----------------------------------------------------------------- summary
Write-Host ""
Write-Host "--- summary ---"
$okCount = @($results | Where-Object { $_.Verdict -like 'OK*' }).Count
Write-Host ("  structurally valid : {0}/{1}" -f $okCount, $results.Count)
$results | Sort-Object Verdict | Format-Table Name, Size, Method, Verdict -AutoSize
$csvPath = Join-Path $OutDir 'rescue_results.csv'
$results | ConvertTo-Csv -NoTypeInformation | Set-Content -Path $csvPath -Encoding UTF8
Write-Host ("report: {0}" -f $csvPath)
Write-Host ""
Write-Host "Files that stayed invalid: their clusters were overwritten and a size-exact"
Write-Host "fingerprint scan found no copy. List every one of them in the final report;"
Write-Host "suggest checking the phone / cloud / other backups by filename date."
$img.Close()
