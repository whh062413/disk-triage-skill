# 01_triage.ps1 - read-only triage of a volume Windows refuses to mount
#
# Answers three questions, in order:
#   1. What does the OS think this device is?  (disk / partition / volume state)
#   2. What is actually in the first sectors?  (valid BPB? foreign data? zeros?)
#   3. Which of the four strategies applies?   (A copy / B rebuild BPB / C escalate / D stop)
#
# READ ONLY. No sector is written by this script.
#
#   .\01_triage.ps1 -Volume '\\.\E:'
#   .\01_triage.ps1 -Volume 'E:' -ReportDir 'D:\case\30_REPORT'

[CmdletBinding()]
param(
    [string]$Volume = '\\.\E:',
    [int]$ReservedScan = 64,
    [string]$ReportDir = ''
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

$lines = New-Object System.Collections.ArrayList
function Out([string]$s) { [void]$lines.Add($s); Write-Host $s }

Out "=== disk-triage / 01_triage (read only) ==="
Out ("target volume : {0}" -f $vol)
Out ("timestamp     : {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date))

# ---------------------------------------------------------------- 1. OS view
Out ""
Out "--- 1. what the OS reports ---"
$diskInfo = $null
if ($letter) {
    $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    if ($part) {
        $diskInfo = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
        $disk = $diskInfo
        Out ("disk          : {0} ({1} GB, {2}, {3})" -f $disk.FriendlyName, [math]::Round($disk.Size/1GB,2), $disk.PartitionStyle, $disk.BusType)
        Out ("disk status   : {0} / health {1} / offline {2} / readOnly {3}" -f $disk.OperationalStatus, $disk.HealthStatus, $disk.IsOffline, $disk.IsReadOnly)
        Out ("partition     : #{0} type={1} mbrType={2} offset={3} bytes ({4} sectors) size={5} bytes" -f `
            $part.PartitionNumber, $part.Type, $part.MbrType, $part.Offset, [int64]($part.Offset/512), $part.Size)
        Out ("               (Hidden Sectors for a BPB = partition offset / 512 = {0})" -f [int64]($part.Offset/512))
    }
    $v = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if ($v) {
        Out ("volume        : fs='{0}' label='{1}' health={2} op={3}" -f $v.FileSystem, $v.FileSystemLabel, $v.HealthStatus, $v.OperationalStatus)
        Out ("                size={0} bytes  free={1} bytes  cluster={2}" -f $v.Size, $v.SizeRemaining, $v.AllocationUnitSize)
        if (-not $v.FileSystem -or $v.Size -eq 0) { Out "                => FileSystem empty / Size 0 is the classic 'unrecognized filesystem' signature" }
    } else { Out "volume        : no volume object for this letter" }
} else {
    Out "volume        : non-drive-letter path given; skipping partition lookup"
}

# ------------------------------------------------------- 2. raw sector reads
Out ""
Out "--- 2. raw sector content ---"
$err = ''
if (-not [RawVol]::CanRead($vol, [ref]$err)) {
    Out ("raw read FAILED: {0}" -f $err)
    Out "  - if the volume is mounted and healthy, raw sector access needs an elevated session"
    Out "  - if the device is offline/absent, re-attach it first"
    if ($ReportDir) { $lines -join "`r`n" | Set-Content -Path (Join-Path $ReportDir '01_triage.txt') -Encoding UTF8 }
    return
}
Out "raw read      : OK (volume handle opened read-only)"

$bpbOk = $false
$s0 = [RawVol]::Read($vol, 0, 512)
$sig = ('{0:X2}{1:X2}' -f $s0[510], $s0[511])
$oem = [System.Text.Encoding]::ASCII.GetString($s0, 3, 8)
$bps = [BitConverter]::ToUInt16($s0, 11); $spc = $s0[13]; $rsvd = [BitConverter]::ToUInt16($s0, 14)
$nfat = $s0[16]; $f16 = [BitConverter]::ToUInt16($s0, 22); $f32 = [BitConverter]::ToUInt32($s0, 36)
$tot32 = [BitConverter]::ToUInt32($s0, 32); $rootClus = [BitConverter]::ToUInt32($s0, 44)
$hidden = [BitConverter]::ToUInt32($s0, 28)
$spcPow2 = ($spc -gt 0) -and (($spc -band ($spc - 1)) -eq 0)
$bpsOk = @(512,1024,2048,4096) -contains $bps
$bpbOk = ($sig -eq '55AA') -and ($spcPow2) -and $bpsOk -and ($rsvd -gt 0) -and ($nfat -in 1,2) -and (($f16 -gt 0) -or ($f32 -gt 0))

Out ("LBA0 signature: {0}   jump=0x{1:X2}   OEM='{2}'" -f $sig, $s0[0], $oem)
if ($bpbOk) {
    Out "LBA0 is a VALID boot sector (BPB fields sane)"
    Out ("   bytes/sector={0} sectors/cluster={1} reserved={2} numFATs={3} FATsz16={4} FATsz32={5}" -f $bps,$spc,$rsvd,$nfat,$f16,$f32)
    Out ("   totalSectors32={0} rootCluster={1} hiddenSectors={2} FSInfo={3} backupBoot={4}" -f `
        $tot32, $rootClus, $hidden, [BitConverter]::ToUInt16($s0,48), [BitConverter]::ToUInt16($s0,50))
    $ds = ([int64]$rsvd + [int64]$nfat * $f32) * $bps
    $f2 = ([int64]$rsvd + $f32) * $bps
    Out ("   => derived dataStart={0}  FAT2 offset={1}" -f $ds, $f2)
} else {
    $nz = 0; foreach ($x in $s0) { if ($x -ne 0) { $nz++ } }
    Out ("LBA0 is NOT a boot sector  (non-zero bytes {0}/512, head: {1})" -f $nz, [RawVol]::Hex($s0,0,16))
    Out "   => this alone explains the 'format?' prompt: the OS cannot identify a filesystem without a valid BPB"
}

$s1 = [RawVol]::Read($vol, 512, 512)
$lead = '{0:X8}' -f [BitConverter]::ToUInt32($s1,0)
$stru = '{0:X8}' -f [BitConverter]::ToUInt32($s1,0x1E4)
$trail = '{0:X8}' -f [BitConverter]::ToUInt32($s1,0x1FC)
$fsinfoOk = ($lead -eq '41615252') -and ($stru -eq '61417272') -and ($trail -eq 'AA550000')
Out ("LBA1 FSInfo   : lead=0x{0} struct=0x{1} trail=0x{2} => {3}" -f $lead,$stru,$trail, $(if ($fsinfoOk) { 'VALID (the FAT32 root metadata survived)' } else { 'wrong signature' }))
if ($fsinfoOk) {
    Out ("   freeClusters={0}  nextFree={1}" -f [BitConverter]::ToUInt32($s1,0x1E8), [BitConverter]::ToUInt32($s1,0x1EC))
}

# reserved area scan
Out ""
Out ("--- 3. reserved area scan (LBA 0..{0}) ---" -f ($ReservedScan - 1))
$sectors = [RawVol]::Read($vol, 0, $ReservedScan * 512)
for ($s = 0; $s -lt $ReservedScan; $s++) {
    $o = $s * 512
    $zero = $true; $nz = 0
    for ($i = 0; $i -lt 512; $i++) { if ($sectors[$o + $i] -ne 0) { $zero = $false; $nz++ } }
    $kind = 'ALL-ZERO'
    if (-not $zero) {
        if ($sectors[$o] -eq 0xEB -and $sectors[$o+510] -eq 0x55) { $kind = 'boot-sector-like' }
        elseif ($sectors[$o] -eq 0x52 -and $sectors[$o+1] -eq 0x52 -and $sectors[$o+2] -eq 0x61 -and $sectors[$o+3] -eq 0x41) { $kind = 'FSInfo' }
        elseif ($s -eq 0) { $kind = '*** BOOT SLOT HOLDS FOREIGN DATA ***' }
        elseif ($s -eq 6) { $kind = '*** BACKUP BOOT SLOT DAMAGED ***' }
        elseif ($s -eq 7) { $kind = '*** BACKUP FSINFO SLOT DAMAGED ***' }
        else { $kind = 'non-zero' }
    }
    if ($kind -ne 'ALL-ZERO') {
        Out ("  LBA{0,-4} {1,-38} {2}" -f $s, $kind, $(if ($nz -lt 512) { "nonZero=$nz" } else { '' }))
    }
}

# ------------------------------------------------------------ 4. FAT probe
Out ""
Out "--- 4. look for surviving FAT tables (media descriptor F8 FF FF 0F) ---"
$limit = 32MB
$hits = New-Object System.Collections.ArrayList
$chunk = 1MB
for ($p = 0; $p -lt $limit; $p += $chunk) {
    $buf = [RawVol]::Read($vol, $p, $chunk)
    for ($i = 0; $i + 8 -le $buf.Length; $i += 512) {
        if ($buf[$i] -eq 0xF8 -and $buf[$i+1] -eq 0xFF -and $buf[$i+2] -eq 0xFF -and $buf[$i+3] -eq 0x0F -and
            $buf[$i+4] -eq 0xFF -and $buf[$i+5] -eq 0xFF -and $buf[$i+6] -eq 0xFF -and $buf[$i+7] -eq 0x0F) {
            [void]$hits.Add([int64]($p + $i))
            if ($hits.Count -ge 4) { break }
        }
    }
    if ($hits.Count -ge 4) { break }
}
if ($hits.Count -eq 0) {
    Out "  no FAT media descriptor found in the first 32 MB"
} else {
    foreach ($h in $hits) { Out ("  FAT candidate at byte {0:N0}  (LBA {1:N0})" -f $h, [int64]($h/512)) }
    if ($hits.Count -ge 2) {
        Out ("  => FAT size = {0:N0} bytes = {1:N0} sectors ; reserved sectors = {2:N0}" -f `
            ($hits[1]-$hits[0]), [int64](($hits[1]-$hits[0])/512), [int64]($hits[0]/512))
    }
}

# ---------------------------------------------------------------- 5. verdict
Out ""
Out "--- 5. verdict ---"
if ($bpbOk -and $fsinfoOk) {
    Out "  STRATEGY A - the filesystem header is intact."
    Out "  If files still fail to open, go straight to copying + structural audit (07_audit_media.ps1)."
} elseif (-not $bpbOk -and $fsinfoOk -and $hits.Count -ge 2) {
    Out "  STRATEGY B - the boot record is destroyed but FAT + FSInfo survived."
    Out "  Next: 02_image.ps1 (image + head insurance) -> 03_probe_geometry.ps1 -> 04_rebuild_bpb.ps1"
    Out "  Do NOT format. Do NOT run chkdsk /f."
} elseif (-not $bpbOk -and -not $fsinfoOk -and $hits.Count -eq 0) {
    Out "  STRATEGY C/D - no recognizable filesystem structure in the first 32 MB."
    Out "  Check the partition table (offset/size) before any write; consider professional recovery."
} else {
    Out "  STRATEGY B/D - partial structure. Verify geometry carefully in 03 before generating any BPB."
}
Out ""
Out "wrote nothing. Every step above was a read."

if ($ReportDir) {
    if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null }
    $lines -join "`r`n" | Set-Content -Path (Join-Path $ReportDir '01_triage.txt') -Encoding UTF8
    Write-Host ("report: " + (Join-Path $ReportDir '01_triage.txt'))
}
