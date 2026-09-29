# make_fixture.ps1 - build small FAT32 test images so the whole pipeline can be
# exercised without any hardware.
#
# Produces three images in -OutDir:
#   clean.img    valid FAT32, small tree, two synthetic JPEGs
#   damaged.img  same, but LBA0 / LBA6 / LBA7 overwritten with foreign data
#                (LBA1 FSInfo deliberately left intact - the case signature)
#   broken.img   damaged.img plus one file whose FAT chain was freed
#
# Geometry: 64 MB, 512 B/sector, 1 sector/cluster (512 B), reserved 32,
#           2 FATs x 1009 sectors, data start at 1,049,600, ~129,022 clusters.
#           (cluster count must stay above 65,525 or it is not valid FAT32)
#
#   .\make_fixture.ps1 -OutDir 'D:\project\disk-triage-skill\tests\fixture'

[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'fixture')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\FatLib.ps1')

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$cs = @'
using System;
using System.IO;
using System.Text;

public class Fixture
{
    public const int BytesPerSector = 512;
    public const int SectorsPerCluster = 1;
    public const int ReservedSectors = 32;
    public const int NumFats = 2;
    public const long FatSizeSectors = 1009;
    public const long TotalSectors = 131072;          // 64 MB
    public const long HiddenSectors = 2048;
    public const long DataStart = (ReservedSectors + NumFats * FatSizeSectors) * BytesPerSector;  // 1,049,600
    public const long Fat1Offset = (long)ReservedSectors * BytesPerSector;                        // 16,384
    public const long Fat2Offset = (ReservedSectors + FatSizeSectors) * BytesPerSector;           // 532,992
    public const int ClusterSize = BytesPerSector * SectorsPerCluster;                            // 512
    public const long TotalClusters = (TotalSectors - (ReservedSectors + NumFats * FatSizeSectors)) / SectorsPerCluster;

    public static byte[] SyntheticJpeg(int size)
    {
        byte[] b = new byte[size];
        int i = 0;
        b[i++] = 0xFF; b[i++] = 0xD8;                                   // SOI
        b[i++] = 0xFF; b[i++] = 0xE0; b[i++] = 0x00; b[i++] = 0x10;     // APP0 len 16
        for (int k = 0; k < 14; k++) b[i++] = 0x20;
        b[i++] = 0xFF; b[i++] = 0xC0; b[i++] = 0x00; b[i++] = 0x11;     // SOF0 len 17
        b[i++] = 0x08; b[i++] = 0x00; b[i++] = 0x03; b[i++] = 0x00; b[i++] = 0x02;
        b[i++] = 0x03;
        b[i++] = 0x01; b[i++] = 0x11; b[i++] = 0x00;
        b[i++] = 0x02; b[i++] = 0x11; b[i++] = 0x01;
        b[i++] = 0x03; b[i++] = 0x11; b[i++] = 0x01;
        b[i++] = 0xFF; b[i++] = 0xDA; b[i++] = 0x00; b[i++] = 0x08;     // SOS len 8
        b[i++] = 0x01; b[i++] = 0x01; b[i++] = 0x00; b[i++] = 0x00; b[i++] = 0x3F; b[i++] = 0x00;
        while (i < size - 2) b[i++] = 0x5A;
        b[size - 2] = 0xFF; b[size - 1] = 0xD9;                          // EOI
        return b;
    }

    static void PutEntry(byte[] dir, int off, string name, string ext, byte attr, uint firstCluster, long size)
    {
        for (int i = 0; i < 11; i++) dir[off + i] = 0x20;
        for (int i = 0; i < name.Length && i < 8; i++) dir[off + i] = (byte)name[i];
        for (int i = 0; i < ext.Length && i < 3; i++) dir[off + 8 + i] = (byte)ext[i];
        dir[off + 11] = attr;
        dir[off + 20] = (byte)((firstCluster >> 16) & 0xFF);
        dir[off + 26] = (byte)(firstCluster & 0xFF);
        dir[off + 27] = (byte)((firstCluster >> 8) & 0xFF);
        dir[off + 28] = (byte)(size & 0xFF);
        dir[off + 29] = (byte)((size >> 8) & 0xFF);
        dir[off + 30] = (byte)((size >> 16) & 0xFF);
        dir[off + 31] = (byte)((size >> 24) & 0xFF);
    }

    public static string Build(string path, bool damageBoot, bool breakChain)
    {
        long totalBytes = TotalSectors * BytesPerSector;
        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            fs.SetLength(totalBytes);

            // --- boot record. Built inline on purpose: a fixture must not depend on
            //     the code under test, or a bug in that code would make the fixture
            //     wrong in the same way and hide itself.
            byte[] bs = LocalBpb();
            fs.Position = 0; fs.Write(bs, 0, bs.Length);

            // --- FSInfo at LBA1 (+ backup at LBA7)
            byte[] fsi = new byte[512];
            PutU32(fsi, 0, 0x41615252);
            PutU32(fsi, 0x1E4, 0x61417272);
            PutU32(fsi, 0x1E8, (uint)(TotalClusters - 20));
            PutU32(fsi, 0x1EC, 12);
            PutU32(fsi, 0x1FC, 0xAA550000);
            fs.Position = 512; fs.Write(fsi, 0, 512);
            fs.Position = 7 * 512; fs.Write(fsi, 0, 512);

            // --- backup boot record at LBA6
            fs.Position = 6 * 512; fs.Write(bs, 0, bs.Length);

            // --- FAT1 (FAT2 is a byte copy of it)
            byte[] fat = new byte[FatSizeSectors * BytesPerSector];
            PutU32(fat, 0, 0x0FFFFFF8);
            PutU32(fat, 4, 0x0FFFFFFF);
            PutU32(fat, 2 * 4, 0x0FFFFFFF);          // cluster 2  root dir  - end of chain
            PutU32(fat, 3 * 4, 0x0FFFFFFF);          // cluster 3  SUB1      - end of chain
            PutU32(fat, 4 * 4, 5);                   // PHOTO1.JPG: 4 -> 5 -> 6 -> 7
            PutU32(fat, 5 * 4, 6);
            PutU32(fat, 6 * 4, 7);
            PutU32(fat, 7 * 4, 0x0FFFFFFF);
            PutU32(fat, 8 * 4, 9);                   // PHOTO2.JPG: 8 -> 9 -> 10 -> 11
            PutU32(fat, 9 * 4, 10);
            PutU32(fat, 10 * 4, 11);
            PutU32(fat, 11 * 4, 0x0FFFFFFF);
            PutU32(fat, 12 * 4, 0x0FFFFFFF);         // SUB1 directory content
            if (breakChain) PutU32(fat, 8 * 4, 0);   // PHOTO2 loses its chain after cluster 8
            fs.Position = Fat1Offset; fs.Write(fat, 0, fat.Length);
            fs.Position = Fat2Offset; fs.Write(fat, 0, fat.Length);

            // --- root directory (cluster 2)
            byte[] root = new byte[ClusterSize];
            PutEntry(root, 0,  "VOLUMELABEL", "", 0x08, 0, 0);
            PutEntry(root, 32, "SUB1",        "", 0x10, 3, 0);
            PutEntry(root, 64, "PHOTO1",     "JPG", 0x20, 4, 2048);
            PutEntry(root, 96, "PHOTO2",     "JPG", 0x20, 8, 2048);
            fs.Position = ClusterOffset(2); fs.Write(root, 0, root.Length);

            // --- SUB1 directory (cluster 3)
            byte[] sub = new byte[ClusterSize];
            PutEntry(sub, 0,  ".",          "", 0x10, 3, 0);
            PutEntry(sub, 32, "..",         "", 0x10, 0, 0);
            PutEntry(sub, 64, "NOTE",      "TXT", 0x20, 12, 40);
            fs.Position = ClusterOffset(3); fs.Write(sub, 0, sub.Length);

            // --- file data
            byte[] p1 = SyntheticJpeg(2048);
            fs.Position = ClusterOffset(4); fs.Write(p1, 0, 2048);
            byte[] p2 = SyntheticJpeg(2048);
            p2[600] = 0x41;
            fs.Position = ClusterOffset(8); fs.Write(p2, 0, 2048);
            byte[] note = Encoding.ASCII.GetBytes("disk-triage fixture note, 40 bytes long.");
            fs.Position = ClusterOffset(12); fs.Write(note, 0, note.Length);

            if (damageBoot)
            {
                // foreign structured junk where the boot record used to be - no 0x55AA,
                // no BPB. This is the signature seen in the real case.
                byte[] junk = new byte[512];
                for (int i = 0; i < 128; i++)
                {
                    junk[i * 4] = (byte)(i & 0xFF);
                    junk[i * 4 + 1] = (byte)((i * 7 + 0xE0) & 0xFF);
                    junk[i * 4 + 2] = (byte)((i * 3) & 0x1F);
                }
                fs.Position = 0; fs.Write(junk, 0, 512);
                byte[] junk6 = new byte[512];
                for (int i = 0; i < 512; i++) junk6[i] = (byte)((i * 13 + 5) & 0xFF);
                fs.Position = 6 * 512; fs.Write(junk6, 0, 512);
                byte[] junk7 = new byte[512];
                for (int i = 0; i < 512; i++) junk7[i] = (byte)((i * 29 + 11) & 0xFF);
                fs.Position = 7 * 512; fs.Write(junk7, 0, 512);
                // LBA1 (FSInfo) stays intact on purpose
            }
            fs.Flush(true);
        }
        return String.Format("built {0} totalBytes={1} dataStart={2} clusters={3} fat1={4} fat2={5} fatSectors={6}",
            Path.GetFileName(path), totalBytes, DataStart, TotalClusters, Fat1Offset, Fat2Offset, FatSizeSectors);
    }

    static long ClusterOffset(long c) { return DataStart + (c - 2) * ClusterSize; }
    static void PutU32(byte[] b, int o, uint v) { b[o] = (byte)(v & 0xFF); b[o+1] = (byte)((v >> 8) & 0xFF); b[o+2] = (byte)((v >> 16) & 0xFF); b[o+3] = (byte)((v >> 24) & 0xFF); }
    static void PutU16(byte[] b, int o, long v) { b[o] = (byte)(v & 0xFF); b[o+1] = (byte)((v >> 8) & 0xFF); }
    static void PutStr(byte[] b, int o, string s) { for (int i = 0; i < s.Length; i++) b[o + i] = (byte)s[i]; }

    static byte[] LocalBpb()
    {
        byte[] b = new byte[BytesPerSector];
        b[0] = 0xEB; b[1] = 0x58; b[2] = 0x90;
        PutStr(b, 3, "MSWIN4.1");
        PutU16(b, 11, BytesPerSector);
        b[13] = (byte)SectorsPerCluster;
        PutU16(b, 14, ReservedSectors);
        b[16] = (byte)NumFats;
        b[21] = 0xF8;
        PutU16(b, 24, 63);
        PutU16(b, 26, 255);
        PutU32(b, 28, (uint)HiddenSectors);
        PutU32(b, 32, (uint)TotalSectors);
        PutU32(b, 36, (uint)FatSizeSectors);
        PutU32(b, 44, 2);
        PutU16(b, 48, 1);
        PutU16(b, 50, 6);
        b[64] = 0x80; b[66] = 0x29;
        PutU32(b, 67, 0x1234ABCD);
        PutStr(b, 71, "TRIAGE     ");
        PutStr(b, 82, "FAT32   ");
        b[510] = 0x55; b[511] = 0xAA;
        return b;
    }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp

Write-Host "=== building FAT32 test fixtures ==="
$clean   = Join-Path $OutDir 'clean.img'
$damaged = Join-Path $OutDir 'damaged.img'
$broken  = Join-Path $OutDir 'broken.img'

Write-Host ("  " + [Fixture]::Build($clean,   $false, $false))
Write-Host ("  " + [Fixture]::Build($damaged, $true,  $false))
Write-Host ("  " + [Fixture]::Build($broken,  $true,  $true))

Write-Host ""
Write-Host "--- fixture geometry (expected values for the tests) ---"
Write-Host ("  bytesPerSector    = {0}" -f [Fixture]::BytesPerSector)
Write-Host ("  sectorsPerCluster = {0}" -f [Fixture]::SectorsPerCluster)
Write-Host ("  reservedSectors   = {0}" -f [Fixture]::ReservedSectors)
Write-Host ("  numFats           = {0}" -f [Fixture]::NumFats)
Write-Host ("  fatSizeSectors    = {0}" -f [Fixture]::FatSizeSectors)
Write-Host ("  totalSectors      = {0}" -f [Fixture]::TotalSectors)
Write-Host ("  hiddenSectors     = {0}" -f [Fixture]::HiddenSectors)
Write-Host ("  dataStart         = {0}" -f [Fixture]::DataStart)
Write-Host ("  totalClusters     = {0}" -f [Fixture]::TotalClusters)
Write-Host ""
Write-Host ("fixtures in {0}" -f $OutDir)
