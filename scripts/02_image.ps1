# 02_image.ps1 - read-only imaging with a retry ladder, bad-block log and resume
#
# WHY IMAGE FIRST: the boot record lives in the same NAND erase block as the start
# of FAT more often than people expect. Any write to LBA0 can disturb that block.
# Get a copy that covers the risk zone before you touch anything.
#
# READ ONLY on the source. Writes only into -OutDir.
#
#   .\02_image.ps1 -Volume '\\.\E:' -OutDir 'D:\case\00_IMAGE'
#   .\02_image.ps1 -Volume '\\.\E:' -OutDir 'D:\case\00_IMAGE' -HeadInsuranceMB 256
#
# PITFALL: never run anything else against the same device while this runs.
# Concurrent access has been observed to produce read errors and misplaced data.

[CmdletBinding()]
param(
    [string]$Volume = '\\.\E:',
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int64]$Length = 0,             # 0 = infer from partition/volume size
    [int]$ChunkKB = 1024,
    [int]$HeadInsuranceMB = 256,
    [switch]$SkipHeadInsurance
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\FatLib.ps1')

function Norm-Volume([string]$v) {
    if ($v -match '^\\\\\.\\([A-Za-z]):$') { return $v.ToUpper() }
    if ($v -match '^([A-Za-z]):$') { return '\\.\' + $v.ToUpper() }
    return $v
}
$vol = Norm-Volume $Volume
$letter = ''
if ($vol -match '^\\\\\.\\([A-Za-z]):$') { $letter = $Matches[1] }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$imgPath  = Join-Path $OutDir 'source.img'
$logPath  = Join-Path $OutDir 'image_log.txt'
$progPath = Join-Path $OutDir 'progress.txt'
$headPath = Join-Path $OutDir ('head_insurance_{0}MB.bin' -f $HeadInsuranceMB)

Write-Host "=== disk-triage / 02_image (read only on source) ==="
Write-Host ("source : {0}" -f $vol)

# ---------------------------------------------------------------- pre-flight
if (-not $Length) {
    if ($letter) {
        $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
        if ($part) { $Length = [int64]$part.Size; Write-Host ("length : {0:N0} bytes (from partition)" -f $Length) }
    }
    if (-not $Length) { throw "cannot infer length; pass -Length explicitly" }
}
$err = ''
if (-not [RawVol]::CanRead($vol, [ref]$err)) { throw ("source not readable: " + $err) }

$outDrive = (Split-Path -Qualifier (Resolve-Path $OutDir).Path)
$free = (Get-Volume -DriveLetter $outDrive.TrimEnd(':')).SizeRemaining
$need = $Length + ($HeadInsuranceMB * 1MB) + 512MB
Write-Host ("free   : {0:N1} GB on {1} ; need ~{2:N1} GB" -f ($free/1GB), $outDrive, ($need/1GB))
if ($free -lt $need) { throw "not enough free space on the destination" }

# ------------------------------------------------------------------- imaging
# Read the whole thing in ChunkKB blocks. On failure, retry, then halve down to
# 512 bytes; anything still unreadable is zero-filled and logged with its LBA.
$chunk = $ChunkKB * 1KB
$start = 0
if (Test-Path $imgPath) {
    $len = (Get-Item $imgPath).Length
    if ($len -ge $Length) { $start = $Length }
    elseif ($len -gt 0) { $start = [int64]([math]::Floor($len / $chunk) * $chunk) }
    Write-Host ("resume : existing image {0:N0} bytes -> restart at {1:N0}" -f $len, $start)
}

$fs = New-Object System.IO.FileStream($imgPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
$fs.SetLength($start)
$fs.Position = $start
$src = New-Object System.IO.FileStream($vol, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$log = New-Object System.IO.StreamWriter($logPath, $true, [System.Text.Encoding]::UTF8)
$log.AutoFlush = $true
$log.WriteLine(("=== run {0:yyyy-MM-dd HH:mm:ss} resumeFrom={1} total={2} ===" -f (Get-Date), $start, $Length))

$badSectors = [int64]0
$badBytes = [int64]0
$badList = New-Object System.Collections.ArrayList

function Read-Span([System.IO.FileStream]$s, [int64]$off, [int]$len, [byte[]]$buf, [int]$bufOff, [int]$depth) {
    for ($a = 0; $a -lt 3; $a++) {
        try {
            $s.Position = $off
            $got = 0
            while ($got -lt $len) { $n = $s.Read($buf, $bufOff + $got, $len - $got); if ($n -le 0) { break }; $got += $n }
            if ($got -eq $len) { return $true }
        } catch { }
        Start-Sleep -Milliseconds 200
    }
    if ($len -gt 512 -and $depth -lt 12) {
        $half = [int](($len / 2) -band (-bnot 511))
        if ($half -lt 512) { $half = 512 }
        $null = Read-Span $s $off $half $buf $bufOff ($depth + 1)
        $null = Read-Span $s ($off + $half) ($len - $half) $buf ($bufOff + $half) ($depth + 1)
        return $false
    }
    for ($i = 0; $i -lt $len; $i++) { $buf[$bufOff + $i] = 0 }
    return $false
}

$buf = New-Object byte[] $chunk
$pos = $start
$sw = [Diagnostics.Stopwatch]::StartNew()
$nextMark = $start + 2GB

while ($pos -lt $Length) {
    $want = [int][math]::Min([int64]$chunk, $Length - $pos)
    $want = $want - ($want % 512)
    if ($want -le 0) { break }

    # fast path: plain read; slow path: retry ladder
    $ok = $false
    try {
        $src.Position = $pos
        $got = 0
        while ($got -lt $want) { $n = $src.Read($buf, $got, $want - $got); if ($n -le 0) { break }; $got += $n }
        $ok = ($got -eq $want)
    } catch { $ok = $false }

    if (-not $ok) {
        $null = Read-Span $src $pos $want $buf 0 0
        for ($i = 0; $i -lt $want; $i += 512) {
            $z = $true
            for ($k = 0; $k -lt 512; $k++) { if ($buf[$i + $k] -ne 0) { $z = $false; break } }
            if ($z) {
                $badSectors++; $badBytes += 512
                if ($badList.Count -lt 20000) { [void]$badList.Add([int64](($pos + $i) / 512)) }
            }
        }
        Write-Host ("  read error around byte {0:N0} - recovered with smaller reads, zero-filled sectors logged" -f $pos)
    }

    $fs.Write($buf, 0, $want)
    $pos += $want

    if ($pos -ge $nextMark -or $pos -ge $Length) {
        $nextMark = $pos + 2GB
        $sec = [math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        $mbs = ($pos - $start) / 1MB / $sec
        $eta = ($Length - $pos) / 1MB / [math]::Max($mbs, 0.01)
        $line = ("[{0:HH:mm:ss}] {1:N1}/{2:N1} GB  {3:N1} MB/s  elapsed {4:N0}s  ETA {5:N0}s  badSectors={6}" -f `
            (Get-Date), ($pos/1GB), ($Length/1GB), $mbs, $sec, $eta, $badSectors)
        Write-Host $line
        Set-Content -Path $progPath -Value $line -Encoding UTF8
    }
}
$fs.Flush($true); $fs.Close(); $src.Close()

$summary = ("IMAGE DONE written={0:N0} bytes  elapsed={1:N0}s  badSectors={2}  badBytes={3:N0}" -f $pos, $sw.Elapsed.TotalSeconds, $badSectors, $badBytes)
Write-Host $summary
$log.WriteLine($summary)
foreach ($lba in $badList) { $log.WriteLine("BAD lba=" + $lba) }
$log.WriteLine(("=== run end {0:yyyy-MM-dd HH:mm:ss} ===" -f (Get-Date)))
$log.Close()

# ------------------------------------------------------------- verification
Write-Host ""
Write-Host "--- verify image length ---"
$len = (Get-Item $imgPath).Length
Write-Host ("  image {0:N0} bytes  expected {1:N0}  => {2}" -f $len, $Length, $(if ($len -eq $Length) { 'OK' } else { 'MISMATCH - rerun to resume' }))

if (-not $SkipHeadInsurance) {
    Write-Host ""
    Write-Host ("--- head insurance ({0} MB), captured separately from the source ---" -f $HeadInsuranceMB)
    $src = New-Object System.IO.FileStream($vol, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $hb = New-Object byte[] ($HeadInsuranceMB * 1MB)
    $src.Position = 0
    $got = 0
    while ($got -lt $hb.Length) { $n = $src.Read($hb, $got, $hb.Length - $got); if ($n -le 0) { break }; $got += $n }
    $src.Close()
    [System.IO.File]::WriteAllBytes($headPath, $hb)
    $h = (Get-FileHash $headPath -Algorithm SHA256).Hash
    Write-Host ("  {0}" -f $headPath)
    Write-Host ("  sha256 {0}" -f $h)
    Write-Host "  capture this twice; identical hashes prove the source is reproducible"

    # compare the insurance head against the image head
    $cmp = 0
    $ifs = [System.IO.File]::OpenRead($imgPath)
    $blk = 1MB
    $a = New-Object byte[] $blk
    $pos = 0
    while ($pos -lt $hb.Length) {
        $want = [int][math]::Min([int64]$blk, $hb.Length - $pos)
        $ifs.Position = $pos
        $g = 0
        while ($g -lt $want) { $n = $ifs.Read($a, $g, $want - $g); if ($n -le 0) { break }; $g += $n }
        for ($i = 0; $i -lt $want; $i++) { if ($a[$i] -ne $hb[$pos + $i]) { $cmp++; break } }
        $pos += $want
    }
    $ifs.Close()
    Write-Host ("  differing 1MB blocks between source and image in the head region: {0}" -f $cmp)
    if ($cmp -gt 0) { Write-Host "  => rerun the imaging pass (resume) or re-image from scratch; do not trust a mismatching head" }
}

Write-Host ""
Write-Host ("log    : {0}" -f $logPath)
Write-Host "next   : 03_probe_geometry.ps1 -Source <image or volume>"
