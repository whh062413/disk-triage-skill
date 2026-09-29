# 07_audit_media.ps1 - structural audit of an already-copied tree
#
# WHY THIS EXISTS: byte-for-byte verification cannot catch "copied without error but
# the content is wrong". When a directory entry or FAT chain points at the wrong
# clusters, both sides read the same wrong bytes and every hash matches - while the
# file is garbage. Parsing each file's own structure is what exposes it.
#
# Verdicts:
#   JPEG  OK / BROKEN-HEADER / SEG-OVERRUN / NO-SOS / NO-EOI / NO-SOI / PNG-*
#   MP4   OK (exact) / OK (trailer ..) / BAD-BOX / NO-MOOV / WALK-PAST-END
#
# Trailing data is NORMAL for phone media: motion photos append a video, camera apps
# append firmware metadata. The audit therefore looks for the end marker anywhere
# after the header, not only at EOF.
#
# READ ONLY.
#
#   .\07_audit_media.ps1 -Root 'D:\case\20_EXTRACT' -Csv 'D:\case\30_REPORT\problem_files.csv'

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string]$Csv = '',
    [int64]$MaxJpegBytes = 268435456,   # 256 MB: MediaAudit loads JPEGs into memory
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\FatLib.ps1')

if (-not (Test-Path -LiteralPath $Root)) { throw ("root not found: " + $Root) }
$Tag = ($Root.TrimEnd('\').Split('\')[-1])

Write-Host "=== disk-triage / 07_audit_media (read only) ==="
Write-Host ("root : {0}" -f $Root)

$sw = [Diagnostics.Stopwatch]::StartNew()
$files = Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue
Write-Host ("files: {0:N0}" -f $files.Count)

$counts = @{}
$problems = New-Object System.Collections.ArrayList
$i = 0
foreach ($f in $files) {
    $i++
    $ext = $f.Extension.ToLower()
    if ($ext -notin @('.jpg', '.jpeg', '.png', '.mp4', '.mov')) { continue }

    if ($ext -eq '.mp4' -or $ext -eq '.mov') {
        $v = [MediaAudit]::Mp4($f.FullName)
    } elseif ($f.Length -gt $MaxJpegBytes) {
        $v = 'SKIPPED-TOO-LARGE'
    } else {
        $note = ''
        $v = [MediaAudit]::Jpeg($f.FullName, [ref]$note)
        if ($note) { $v = $v + ' ' + $note }
    }

    $key = ($v -split ' ')[0]
    if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
    $counts[$key]++

    if ($key -ne 'OK') {
        [void]$problems.Add([pscustomobject]@{ Name = $f.Name; Bytes = $f.Length; Verdict = $v; Path = $f.FullName })
    }
    if (-not $Quiet -and $i % 2000 -eq 0) { Write-Host ("  ... {0:N0}/{1:N0}  ({2:N0}s)" -f $i, $files.Count, $sw.Elapsed.TotalSeconds) }
}

Write-Host ""
Write-Host ("--- verdicts ({0:N0}s) ---" -f $sw.Elapsed.TotalSeconds)
$counts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Host ("  {0,-22} {1,7:N0}" -f $_.Key, $_.Value) }

$okCount = 0
if ($counts.ContainsKey('OK')) { $okCount = $counts['OK'] }
Write-Host ""
Write-Host ("  structurally valid : {0:N0}" -f $okCount)
Write-Host ("  needing attention  : {0:N0}" -f $problems.Count)

if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "--- problem files (first 40) ---"
    $problems | Sort-Object Name | Select-Object -First 40 | ForEach-Object {
        Write-Host ("  {0,-46} {1,14:N0} B  {2}" -f $_.Name, $_.Bytes, $_.Verdict)
    }
    if ($Csv) {
        $dir = Split-Path $Csv -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $problems | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
        Write-Host ("report: {0}" -f $Csv)
    }
    Write-Host ""
    Write-Host "Next: for each problem file, re-extract from the source with 06_rescue.ps1"
    Write-Host "      (FAT2 chain -> contiguous -> truncate at EOI -> fingerprint)."
} else {
    Write-Host ""
    Write-Host "Every media file parses cleanly. No silent corruption found." -ForegroundColor Green
}
