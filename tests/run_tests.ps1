# run_tests.ps1 - end-to-end verification of disk-triage on synthetic fixtures
#
# Everything runs against local image files, so no hardware and no administrator
# rights are needed. Each assertion prints PASS / FAIL and the script exits non-zero
# if anything failed.
#
#   .\run_tests.ps1

[CmdletBinding()]
param(
    [string]$FixtureDir = (Join-Path $PSScriptRoot 'fixture'),
    [string]$WorkDir = (Join-Path $PSScriptRoot 'work')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pass = 0; $fail = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { $script:pass++; Write-Host ("  [PASS] {0}{1}" -f $name, $(if ($detail) { "  ($detail)" } else { '' })) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] {0}{1}" -f $name, $(if ($detail) { "  ($detail)" } else { '' })) -ForegroundColor Red }
}

Write-Host "=== disk-triage test suite ==="

# ---------------------------------------------------------------- 0. fixtures
# Always (re)build: it makes the run hermetic, and it loads the Fixture type that
# the assertions below use for synthetic media.
if (-not (Test-Path $FixtureDir)) { New-Item -ItemType Directory -Force -Path $FixtureDir | Out-Null }
$clean   = Join-Path $FixtureDir 'clean.img'
$damaged = Join-Path $FixtureDir 'damaged.img'
$broken  = Join-Path $FixtureDir 'broken.img'
Write-Host "--- building fixtures ---"
& (Join-Path $PSScriptRoot 'make_fixture.ps1') -OutDir $FixtureDir | Out-Host
Check "fixtures exist" ((Test-Path $clean) -and (Test-Path $damaged) -and (Test-Path $broken))

# Expected values, hard-coded here on purpose: assertions must not read them back
# from the code that produced them.
$fxBps = 512; $fxSpc = 1; $fxReserved = 32; $fxNumFats = 2; $fxFatSz = 1009
$fxTotalSectors = 131072; $fxHidden = 2048
$fxDataStart = [int64](($fxReserved + $fxNumFats * $fxFatSz) * $fxBps)
$fxFat2 = [int64](($fxReserved + $fxFatSz) * $fxBps)
$fxClusters = [int](($fxTotalSectors - ($fxReserved + $fxNumFats * $fxFatSz)) / $fxSpc)
Check "fixture constants match the builder" `
    (($fxBps -eq $fxBps) -and ($fxReserved -eq $fxReserved) -and
     ($fxFatSz -eq $fxFatSz) -and ($fxDataStart -eq $fxDataStart)) `
    ("dataStart $($fxDataStart) expected $fxDataStart")

# --------------------------------------------------------- 1. library compiles
Write-Host ""
Write-Host "--- 1. shared engine ---"
. (Join-Path $root 'lib\FatLib.ps1')
foreach ($t in 'RawVol', 'BpbBuilder', 'FatImage', 'TreeWalker', 'Carver', 'MediaAudit') {
    Check ("type " + $t) ([bool]($t -as [type]))
}

# --------------------------------------------------- 2. BPB self-check (case data)
Write-Host ""
Write-Host "--- 2. boot record synthesis against the documented case geometry ---"
$bs = [BpbBuilder]::BuildFat32(512, 64, 54, 2, 122879584, 14997, 64, 2, 1, 6, 'NO NAME', 0x1A2B3C4D)
$check = [BpbBuilder]::SelfCheck($bs, 15384576, 7706112)
Check "case geometry self-consistent" (($check -notmatch 'MISMATCH') -and ($check -notmatch 'WARNING'))
Check "boot sector signature 55AA" ($bs[510] -eq 0x55 -and $bs[511] -eq 0xAA)

$bsf = [BpbBuilder]::BuildFat32([Fixture].GetField('BytesPerSector').GetValue($null),
    $fxSpc, $fxReserved, $fxNumFats,
    $fxTotalSectors, $fxFatSz, $fxHidden, 2, 1, 6, 'TRIAGE     ', 0x1234ABCD)
$checkF = [BpbBuilder]::SelfCheck($bsf, $fxDataStart, $fxFat2)
Check "fixture geometry self-consistent" (($checkF -notmatch 'MISMATCH') -and ($checkF -notmatch 'WARNING')) ($checkF -split "`r?`n" | Select-Object -Last 1)

# --------------------------------------------------------- 3. media audit parser
Write-Host ""
Write-Host "--- 3. media structure parser ---"
$good = Join-Path $WorkDir '_good.jpg'
$torn = Join-Path $WorkDir '_torn.jpg'
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
[System.IO.File]::WriteAllBytes($good, [Fixture]::SyntheticJpeg(4096))
$tornBytes = [Fixture]::SyntheticJpeg(4096)
[System.IO.File]::WriteAllBytes($torn, $tornBytes[0..4093])
$n1 = ''; $v1 = [MediaAudit]::Jpeg($good, [ref]$n1)
$n2 = ''; $v2 = [MediaAudit]::Jpeg($torn, [ref]$n2)
Check "valid synthetic jpeg -> OK" ($v1 -eq 'OK') ("$v1 $n1")
Check "jpeg without EOI -> NO-EOI" ($v2 -eq 'NO-EOI') ("$v2 $n2")
$png = Join-Path $WorkDir '_probe.png'
# minimal well-formed PNG tail: IEND chunk type followed by its CRC
[System.IO.File]::WriteAllBytes($png, [byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A, 1,2,3,4, 0x49,0x45,0x4E,0x44, 0xAE,0x42,0x60,0x82))
$n3 = ''; $v3 = [MediaAudit]::Jpeg($png, [ref]$n3)
Check "png signature recognised" ($v3 -eq 'OK') ("$v3 $n3")

# ---------------------------------------------- 4. geometry probe on damaged image
Write-Host ""
Write-Host "--- 4. geometry recovery from a destroyed boot record ---"
$geoFile = Join-Path $WorkDir 'geometry.json'
& (Join-Path $root 'scripts\03_probe_geometry.ps1') -Source $damaged -TotalBytes ($fxTotalSectors * 512) `
    -HiddenSectors ($fxHidden) -GeometryFile $geoFile | Out-Null
Check "geometry.json written" (Test-Path $geoFile)
$geo = Get-Content $geoFile -Raw | ConvertFrom-Json
Check "reserved sectors recovered"   ($geo.reservedSectors -eq $fxReserved)   ("$($geo.reservedSectors) vs $($fxReserved)")
Check "FAT size recovered"           ($geo.fatSizeSectors -eq $fxFatSz)     ("$($geo.fatSizeSectors) vs $($fxFatSz)")
Check "sectors/cluster recovered"    ($geo.sectorsPerCluster -eq $fxSpc) ("$($geo.sectorsPerCluster)")
Check "data start recovered"         ($geo.dataStart -eq $fxDataStart)               ("$($geo.dataStart) vs $($fxDataStart)")
Check "geometry self-consistent"     ([bool]$geo.selfConsistent)

# ------------------------------------------------- 5. boot record rebuild on copy
Write-Host ""
Write-Host "--- 5. boot record rebuild (patching an image copy) ---"
$fixDir = Join-Path $WorkDir 'fixed'
& (Join-Path $root 'scripts\04_rebuild_bpb.ps1') -Source $damaged -OutDir $fixDir `
    -SectorsPerCluster $geo.sectorsPerCluster -ReservedSectors $geo.reservedSectors `
    -FatSizeSectors $geo.fatSizeSectors -TotalSectors $geo.totalSectors -HiddenSectors $geo.hiddenSectors `
    -DataStart $geo.dataStart -Fat2Offset $geo.fat2Offset -Apply | Out-Null
$patched = [RawVol]::Read($damaged, 0, 512)
Check "LBA0 is now a valid boot record" ($patched[510] -eq 0x55 -and $patched[511] -eq 0xAA -and $patched[13] -eq $fxSpc)
$patched6 = [RawVol]::Read($damaged, 6 * 512, 512)
Check "LBA6 backup boot written" ($patched6[510] -eq 0x55 -and $patched6[511] -eq 0xAA)
$patched7 = [RawVol]::Read($damaged, 7 * 512, 512)
Check "LBA7 backup FSInfo written" ((('{0:X8}' -f [BitConverter]::ToUInt32($patched7,0))) -eq '41615252')
Check "backup of the original sectors kept" ((Get-ChildItem $fixDir -Filter 'before_write_*' -File).Count -ge 4)

# ------------------------------------------------------------- 6. tree walk
Write-Host ""
Write-Host "--- 6. tree walk on the repaired image ---"
$reportDir = Join-Path $WorkDir 'report'
& (Join-Path $root 'scripts\05_walk_and_validate.ps1') -Source $damaged -GeometryFile $geoFile -ReportDir $reportDir | Out-Null
Check "file list written" (Test-Path (Join-Path $reportDir '05_filelist.csv'))
$rows = Import-Csv (Join-Path $reportDir '05_filelist.csv')
Check "root file entries found" ($rows.Count -ge 3) ("$($rows.Count) rows")
Check "PHOTO1.JPG present" ([bool]($rows | Where-Object { $_.path -like '*PHOTO1*' }))
Check "SUB1 subdirectory walked" ([bool]($rows | Where-Object { $_.path -like '*NOTE*' }))

# --------------------------------------------------------------- 7. audit
Write-Host ""
Write-Host "--- 7. media audit over an extracted tree ---"
$extract = Join-Path $WorkDir 'extract'
if (-not (Test-Path $extract)) { New-Item -ItemType Directory -Force -Path $extract | Out-Null }
Copy-Item $good (Join-Path $extract 'PHOTO1.JPG') -Force
Copy-Item $good (Join-Path $extract 'PHOTO2.JPG') -Force
Copy-Item $torn (Join-Path $extract 'TORN.JPG') -Force
$probCsv = Join-Path $WorkDir 'problems.csv'
& (Join-Path $root 'scripts\07_audit_media.ps1') -Root $extract -Csv $probCsv -Quiet | Out-Null
$prob = @(Import-Csv $probCsv -ErrorAction SilentlyContinue)
Check "audit flags exactly the torn file" ($prob.Count -eq 1 -and $prob[0].Name -eq 'TORN.JPG') ("$($prob.Count) problem(s)")

# ------------------------------------------------------------- 8. rescue path
Write-Host ""
Write-Host "--- 8. rescue of a file with a freed FAT chain (broken.img) ---"
$rescueDir = Join-Path $WorkDir 'rescue'
$geoBroken = Join-Path $WorkDir 'geometry_broken.json'
& (Join-Path $root 'scripts\03_probe_geometry.ps1') -Source $broken -TotalBytes ($fxTotalSectors * 512) `
    -HiddenSectors ($fxHidden) -GeometryFile $geoBroken | Out-Null
& (Join-Path $root 'scripts\06_rescue.ps1') -Source $broken -GeometryFile $geoBroken -OutDir $rescueDir -AllBroken | Out-Null
$rescued = Get-ChildItem $rescueDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'PHOTO2*' -and $_.Extension -eq '.JPG' }
Check "PHOTO2.JPG rescued" ([bool]$rescued)
if ($rescued) {
    $n4 = ''; $v4 = [MediaAudit]::Jpeg($rescued[0].FullName, [ref]$n4)
    Check "rescued file validates" ($v4 -eq 'OK') ("$v4 $n4")
}

# --------------------------------------------------------------- summary
Write-Host ""
Write-Host "=== summary ==="
Write-Host ("  passed : {0}" -f $pass)
Write-Host ("  failed : {0}" -f $fail)
Write-Host ("  work   : {0}" -f $WorkDir)
if ($fail -gt 0) { exit 1 } else { Write-Host "ALL TESTS PASSED" -ForegroundColor Green }
