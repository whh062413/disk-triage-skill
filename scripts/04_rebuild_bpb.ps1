# 04_rebuild_bpb.ps1 - synthesize a FAT32 boot record and (optionally) write it back
#
# Dry-run by default. Only -Apply writes, and only these three sectors:
#   LBA0  boot record          (the BPB Windows needs in order to mount)
#   LBA6  backup boot record   (same bytes)
#   LBA7  backup FSInfo        (copy of the surviving LBA1)
#
# Nothing else is touched: FAT tables, directories and file data are never written.
#
# REFUSES TO WRITE unless every gate passes:
#   self-check   derived dataStart / FAT2 offset match the measurements
#   elevation    raw volume writes require an administrator token
#   identity     target friendly name matches -ExpectFriendlyName (if supplied)
#   live check   LBA1 FSInfo signatures, both FAT media descriptors, root dir entries
#   backup       the original 4 sectors are saved before anything is written
#
#   .\04_rebuild_bpb.ps1 -Source '\\.\E:' ... -OutDir 'D:\case\10_FIXED'            # dry run
#   .\04_rebuild_bpb.ps1 -Source '\\.\E:' ... -OutDir 'D:\case\10_FIXED' -Apply     # write
#   .\04_rebuild_bpb.ps1 -Source 'D:\case\00_IMAGE\source.img' ... -Apply           # patch an image copy

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][int]$SectorsPerCluster,
    [Parameter(Mandatory=$true)][int64]$ReservedSectors,
    [Parameter(Mandatory=$true)][int64]$FatSizeSectors,
    [Parameter(Mandatory=$true)][int64]$TotalSectors,
    [Parameter(Mandatory=$true)][int64]$DataStart,
    [Parameter(Mandatory=$true)][int64]$Fat2Offset,
    [int]$BytesPerSector = 512,
    [int]$NumFats = 2,
    [int64]$HiddenSectors = 0,
    [int]$RootCluster = 2,
    [int]$FsInfoSector = 1,
    [int]$BackupBootSector = 6,
    [string]$VolumeLabel = 'NO NAME',
    [string]$VolumeId = '0x1A2B3C4D',
    [string]$OutDir = '',
    [string]$ExpectFriendlyName = '',
    [switch]$Apply,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\FatLib.ps1')

function Norm-Source([string]$s) {
    if ($s -match '^([A-Za-z]):$') { return '\\.\' + $s.ToUpper() }
    return $s
}
$src = Norm-Source $Source
$isFile = Test-Path -LiteralPath $src -PathType Leaf
if (-not $OutDir) { $OutDir = Join-Path (Get-Location).Path 'bpb_out' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

Write-Host "=== disk-triage / 04_rebuild_bpb ==="
Write-Host ("target : {0}  ({1})" -f $src, $(if ($isFile) { 'image file - patching a copy, safe' } else { 'LIVE DEVICE - real write' }))
Write-Host ("mode   : {0}" -f $(if ($Apply) { 'APPLY (writes 3 sectors)' } else { 'DRY RUN (writes nothing to the target)' }))

# ------------------------------------------------------------------ 1. build
$vid = [uint32]([Convert]::ToUInt32($VolumeId, 16))
$bs = [BpbBuilder]::BuildFat32($BytesPerSector, $SectorsPerCluster, [int]$ReservedSectors, $NumFats,
        $TotalSectors, $FatSizeSectors, $HiddenSectors, [uint32]$RootCluster,
        $FsInfoSector, $BackupBootSector, $VolumeLabel, $vid)

$bsPath = Join-Path $OutDir 'bootsector_lba0.bin'
[System.IO.File]::WriteAllBytes($bsPath, $bs)
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'bootsector_backup_lba6.bin'), $bs)
Write-Host ""
Write-Host ("boot record generated: {0} bytes -> {1}" -f $bs.Length, $bsPath)
Write-Host ("  bytes/sector={0} sectors/cluster={1} reserved={2} numFATs={3} FATsz={4} totalSectors={5}" -f `
    $BytesPerSector, $SectorsPerCluster, $ReservedSectors, $NumFats, $FatSizeSectors, $TotalSectors)
Write-Host ("  rootCluster={0} FSInfo={1} backupBoot={2} hiddenSectors={3} label='{4}'" -f `
    $RootCluster, $FsInfoSector, $BackupBootSector, $HiddenSectors, $VolumeLabel)

# ------------------------------------------------------------- 2. self-check
Write-Host ""
Write-Host "--- self-check against the measured geometry ---"
$check = [BpbBuilder]::SelfCheck($bs, $DataStart, $Fat2Offset)
$check -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Host ("  " + $_) }
$mismatch = ($check -match 'MISMATCH') -or ($check -match 'WARNING')
if ($mismatch -and -not $Force) {
    Write-Host ""
    Write-Host "REFUSING: the candidate geometry does not match the media. Fix the inputs or pass -Force." -ForegroundColor Red
    return
}

# --------------------------------------------------------------- 3. dry run
$plan = @(
    @{ Name = 'LBA0 boot record';        Offset = 0;                      Len = 512 },
    @{ Name = 'LBA6 backup boot record'; Offset = [int64]$BackupBootSector * 512; Len = 512 },
    @{ Name = 'LBA7 backup FSInfo';      Offset = [int64]($BackupBootSector + 1) * 512; Len = 512 }
)
Write-Host ""
Write-Host "--- write plan (total 1536 bytes) ---"
foreach ($p in $plan) { Write-Host ("  {0,-24} offset {1,10:N0}" -f $p.Name, $p.Offset) }

if (-not $Apply) {
    Write-Host ""
    Write-Host "DRY RUN complete. To write, re-run with -Apply (administrator required for a live device)."
    Write-Host ("candidate kept at {0}" -f $bsPath)
    return
}

# ------------------------------------------------------- 4. write pre-flight
Write-Host ""
Write-Host "--- write pre-flight ---"
if (-not $isFile) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "REFUSING: raw volume writes require an administrator session." -ForegroundColor Red
        Write-Host "  right-click Start -> Terminal (Admin), then re-run this command." -ForegroundColor Yellow
        return
    }
    Write-Host "  elevation        : administrator OK"
    if ($src -match '^\\\\\.\\([A-Za-z]):$') {
        $part = Get-Partition -DriveLetter $Matches[1] -ErrorAction SilentlyContinue
        if ($part) {
            $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
            Write-Host ("  target device    : {0} (disk {1}, {2})" -f $disk.FriendlyName, $part.DiskNumber, $disk.BusType)
            if ($ExpectFriendlyName -and $disk.FriendlyName -notmatch $ExpectFriendlyName) {
                Write-Host ("REFUSING: friendly name '{0}' does not match -ExpectFriendlyName '{1}'" -f $disk.FriendlyName, $ExpectFriendlyName) -ForegroundColor Red
                return
            }
        }
    }
}
$werr = ''
if (-not [RawVol]::CanWrite($src, [ref]$werr)) { Write-Host ("REFUSING: cannot open for write: {0}" -f $werr) -ForegroundColor Red; return }
Write-Host "  write handle     : OK"

# live structural verification
$fail = 0
if (-not $isFile) {
    $s1 = [RawVol]::Read($src, [int64]$FsInfoSector * 512, 512)
    $l = '{0:X8}' -f [BitConverter]::ToUInt32($s1,0)
    $st = '{0:X8}' -f [BitConverter]::ToUInt32($s1,0x1E4)
    $tr = '{0:X8}' -f [BitConverter]::ToUInt32($s1,0x1FC)
    $ok = ($l -eq '41615252') -and ($st -eq '61417272') -and ($tr -eq 'AA550000')
    Write-Host ("  LBA{0} FSInfo     : lead=0x{1} struct=0x{2} trail=0x{3} => {4}" -f $FsInfoSector, $l, $st, $tr, $(if ($ok) { 'OK' } else { 'FAIL' }))
    if (-not $ok) { $fail++ }

    foreach ($fo in @(([int64]$ReservedSectors * $BytesPerSector), $Fat2Offset)) {
        $fb = [RawVol]::Read($src, $fo, 512)
        $ok = ($fb[0] -eq 0xF8 -and $fb[1] -eq 0xFF -and $fb[2] -eq 0xFF -and $fb[3] -eq 0x0F)
        Write-Host ("  FAT @{0,-10:N0} : {1} {2} {3} {4} => {5}" -f $fo, $fb[0].ToString('X2'), $fb[1].ToString('X2'), $fb[2].ToString('X2'), $fb[3].ToString('X2'), $(if ($ok) { 'OK' } else { 'FAIL' }))
        if (-not $ok) { $fail++ }
    }

    $rd = [RawVol]::ReadAny($src, $DataStart, 64)
    $nm = [System.Text.Encoding]::ASCII.GetString($rd, 0, 11)
    $attr = $rd[11]
    Write-Host ("  root dir @{0,-10:N0}: first entry '{1}' attr=0x{2:X2}" -f $DataStart, $nm, $attr)
    if ($nm.Trim().Length -eq 0) { $fail++ }
}
if ($fail -gt 0) { Write-Host ("REFUSING: live verification failed ({0} check(s))" -f $fail) -ForegroundColor Red; return }
Write-Host "  live verification: PASSED"

# ------------------------------------------------------------------ 5. write
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
foreach ($p in @(@{n='lba0';o=0}, @{n='lba1';o=[int64]$FsInfoSector * 512}, @{n='lba6';o=[int64]$BackupBootSector * 512}, @{n='lba7';o=[int64]($BackupBootSector+1) * 512})) {
    $d = [RawVol]::Read($src, $p.o, 512)
    [System.IO.File]::WriteAllBytes((Join-Path $OutDir ('before_write_{0}_{1}.bin' -f $p.n, $stamp)), $d)
}
Write-Host ("  original sectors backed up into {0}" -f $OutDir)

$s1data = [RawVol]::Read($src, [int64]$FsInfoSector * 512, 512)
Write-Host ""
Write-Host "--- writing ---"
[RawVol]::WriteSectors($src, 0, $bs);                                                Write-Host "  LBA0 boot record        written"
[RawVol]::WriteSectors($src, [int64]$BackupBootSector * 512, $bs);                   Write-Host ("  LBA{0} backup boot      written" -f $BackupBootSector)
[RawVol]::WriteSectors($src, [int64]($BackupBootSector + 1) * 512, $s1data);         Write-Host ("  LBA{0} backup FSInfo    written" -f ($BackupBootSector + 1))

# ------------------------------------------------------------ 6. read back
Write-Host ""
Write-Host "--- read-back verification ---"
$r0 = [RawVol]::Read($src, 0, 512)
$r6 = [RawVol]::Read($src, [int64]$BackupBootSector * 512, 512)
$r7 = [RawVol]::Read($src, [int64]($BackupBootSector + 1) * 512, 512)
$m0 = ($r0[510] -eq 0x55 -and $r0[511] -eq 0xAA -and $r0[13] -eq $SectorsPerCluster -and $r0[16] -eq $NumFats)
$m6 = ($r6[510] -eq 0x55 -and $r6[511] -eq 0xAA -and $r6[13] -eq $SectorsPerCluster)
$m7 = (('{0:X8}' -f [BitConverter]::ToUInt32($r7,0)) -eq '41615252')
Write-Host ("  LBA0 signature+geometry : {0}" -f $m0)
Write-Host ("  LBA{0} mirror             : {1}" -f $BackupBootSector, $m6)
Write-Host ("  LBA{0} FSInfo copy        : {1}" -f ($BackupBootSector+1), $m7)

if ($m0 -and $m6 -and $m7) {
    Write-Host ""
    Write-Host "SUCCESS. Detach and re-attach the device so the OS re-reads the boot record," -ForegroundColor Green
    Write-Host "then copy data off immediately and verify it (05 -> 06 -> 07)." -ForegroundColor Green
} else {
    Write-Host "Read-back verification FAILED - stop and report." -ForegroundColor Red
}
