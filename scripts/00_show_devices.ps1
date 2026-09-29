# 00_show_devices.ps1 - which disk is external, which is internal, and is your
# source/work pair actually on two different physical disks?
#
# Run this BEFORE anything else. Every path in disk-triage is a parameter; this
# script exists so you never have to guess which drive letter is which.
#
#   .\00_show_devices.ps1
#   .\00_show_devices.ps1 -Source '\\.\E:' -WorkDir 'D:\case'
#
# READ ONLY.

[CmdletBinding()]
param(
    [string]$Source = '',
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'

# buses that mean "removable / external" for our purposes
$externalBuses = @('USB', 'SD', 'MMC', 'iSCSI', 'Fibre Channel')

Write-Host "=== disk-triage / 00_show_devices (read only) ==="
Write-Host ""

function Get-DiskLabel($disk) {
    if ($externalBuses -contains $disk.BusType) { return '[EXTERNAL]' }
    return '[INTERNAL]'
}

# ---------------------------------------------------------------- physical disks
Write-Host "--- physical disks ---"
Write-Host ("  {0,-4} {1,-9} {2,-26} {3,-8} {4,10}  {5}" -f 'No', 'Role', 'Model', 'Bus', 'SizeGB', 'State')
foreach ($d in (Get-Disk | Sort-Object Number)) {
    $state = "$($d.OperationalStatus)/$($d.HealthStatus)"
    if ($d.IsOffline) { $state += " OFFLINE" }
    if ($d.IsReadOnly) { $state += " READONLY" }
    Write-Host ("  {0,-4} {1,-9} {2,-26} {3,-8} {4,10:N1}  {5}" -f `
        $d.Number, (Get-DiskLabel $d), $d.FriendlyName, $d.BusType, ($d.Size/1GB), $state)
}
Write-Host ""
Write-Host "  [EXTERNAL] = removable media: the subject device. This is what -Source / -Volume points at."
Write-Host "  [INTERNAL] = a fixed disk: the work target. This is what -OutDir / -ReportDir / -Csv point at."

# ---------------------------------------------------------------- partitions
Write-Host ""
Write-Host "--- partitions and drive letters ---"
Write-Host ("  {0,-8} {1,-8} {2,-8} {3,-10} {4,10}  {5}" -f 'Letter', 'Disk', 'Part', 'Type', 'SizeGB', 'Role')
foreach ($p in (Get-Partition | Sort-Object DiskNumber, PartitionNumber)) {
    $disk = Get-Disk -Number $p.DiskNumber -ErrorAction SilentlyContinue
    $letter = if ($p.DriveLetter) { $p.DriveLetter + ':' } else { '(none)' }
    $role = if ($disk) { Get-DiskLabel $disk } else { '' }
    $type = if ($p.MbrType) { "MBR:$($p.MbrType)" } else { $p.Type }
    Write-Host ("  {0,-8} {1,-8} {2,-8} {3,-10} {4,10:N1}  {5}" -f `
        $letter, $p.DiskNumber, $p.PartitionNumber, $type, ($p.Size/1GB), $role)
}

# ---------------------------------------------------------------- volumes
Write-Host ""
Write-Host "--- volumes (filesystem view) ---"
Write-Host ("  {0,-8} {1,-10} {2,-16} {3,-10} {4,10} {5,10}" -f 'Letter', 'FS', 'Label', 'Health', 'SizeGB', 'FreeGB')
foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter)) {
    Write-Host ("  {0,-8} {1,-10} {2,-16} {3,-10} {4,10:N1} {5,10:N1}" -f `
        ($v.DriveLetter + ':'), $v.FileSystem, $v.FileSystemLabel, $v.HealthStatus, ($v.Size/1GB), ($v.SizeRemaining/1GB))
}

# ------------------------------------------------- resolve a path to a disk number
function Resolve-DiskNumber([string]$path) {
    if (-not $path) { return $null }
    $letter = $null
    if ($path -match '^\\\\\.\\([A-Za-z]):') { $letter = $Matches[1] }
    elseif ($path -match '^([A-Za-z]):') { $letter = $Matches[1] }
    elseif (Test-Path -LiteralPath $path) { $letter = (Split-Path -Qualifier (Resolve-Path -LiteralPath $path).Path).TrimEnd(':') }
    if (-not $letter) { return $null }
    $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $part) { return $null }
    return [pscustomobject]@{ Letter = $letter.ToUpper(); DiskNumber = $part.DiskNumber; PartitionNumber = $part.PartitionNumber }
}

# ---------------------------------------------------------------- pair check
if ($Source -or $WorkDir) {
    Write-Host ""
    Write-Host "--- source / work pair check ---"
    $s = Resolve-DiskNumber $Source
    $w = Resolve-DiskNumber $WorkDir

    if ($Source) {
        if ($s) {
            $sd = Get-Disk -Number $s.DiskNumber
            Write-Host ("  source    {0}  -> disk {1} '{2}' ({3}) {4}" -f $Source, $s.DiskNumber, $sd.FriendlyName, $sd.BusType, (Get-DiskLabel $sd))
        } else { Write-Host ("  source    {0}  -> cannot resolve to a disk (typo? device absent?)" -f $Source) }
    }
    if ($WorkDir) {
        if ($w) {
            $wd = Get-Disk -Number $w.DiskNumber
            $free = (Get-Volume -DriveLetter $w.Letter).SizeRemaining
            Write-Host ("  work dir  {0}  -> disk {1} '{2}' ({3}) {4}, free {5:N1} GB" -f $WorkDir, $w.DiskNumber, $wd.FriendlyName, $wd.BusType, (Get-DiskLabel $wd), ($free/1GB))
        } else { Write-Host ("  work dir  {0}  -> cannot resolve to a disk" -f $WorkDir) }
    }

    if ($s -and $w) {
        Write-Host ""
        if ($s.DiskNumber -eq $w.DiskNumber) {
            Write-Host "  STOP: source and work directory are on the SAME physical disk." -ForegroundColor Red
            Write-Host "        An image written next to the failing volume shares its fate, and any" -ForegroundColor Red
            Write-Host "        device-level problem can take both. Choose a work directory on another disk." -ForegroundColor Red
        } else {
            Write-Host "  OK: source and work directory are on different physical disks." -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "reminder: nothing in disk-triage has a default drive letter. Always pass"
Write-Host "          -Source/-Volume (the failing EXTERNAL device) and"
Write-Host "          -OutDir/-ReportDir/-Csv (a directory on an INTERNAL disk)."
