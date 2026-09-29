# FatLib.ps1 - shared engine for disk-triage
#
# ASCII-only on purpose: non-ASCII characters written into a .ps1 file get mangled by
# some PowerShell / console encoding paths, which has broken Add-Type compilation in
# practice. Keep this file ASCII. User-facing Chinese belongs in the .md files.
#
# Usage:  . "$PSScriptRoot\..\lib\FatLib.ps1"   (dot-source, types persist in the session)

if ($Global:DiskTriageLibLoaded) { return }
$Global:DiskTriageLibLoaded = $true

$cs = @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

// ---------------------------------------------------------------------------
// RawVol: sector-aligned raw access to a volume or disk device path.
// PITFALL: volume handles reject non-512-aligned offsets and will surface
// confusing errors (ERROR_INVALID_PARAMETER / "Handle does not support
// synchronous operations"). Always use ReadAny() for unaligned needs.
// ---------------------------------------------------------------------------
public class RawVol
{
    public const int SectorSize = 512;

    public static byte[] Read(string vol, long offset, int len)
    {
        if (offset < 0) throw new ArgumentException("offset < 0");
        if (offset % SectorSize != 0) throw new ArgumentException("offset must be " + SectorSize + "-byte aligned: " + offset);
        using (FileStream fs = new FileStream(vol, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            byte[] b = new byte[len];
            fs.Position = offset;
            int got = 0;
            while (got < len) { int n = fs.Read(b, got, len - got); if (n <= 0) break; got += n; }
            return b;
        }
    }

    public static byte[] ReadAny(string vol, long offset, int len)
    {
        long blk = offset - (offset % SectorSize);
        int lead = (int)(offset - blk);
        int need = ((lead + len + SectorSize - 1) / SectorSize) * SectorSize;
        byte[] raw = Read(vol, blk, need);
        byte[] res = new byte[len];
        int avail = raw.Length - lead;
        Array.Copy(raw, lead, res, 0, avail < len ? avail : len);
        return res;
    }

    public static void WriteSectors(string vol, long offset, byte[] data)
    {
        if (offset % SectorSize != 0) throw new ArgumentException("offset must be " + SectorSize + "-byte aligned");
        if (data.Length % SectorSize != 0) throw new ArgumentException("length must be a multiple of " + SectorSize);
        using (FileStream fs = new FileStream(vol, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            fs.Position = offset;
            fs.Write(data, 0, data.Length);
            fs.Flush(true);
        }
    }

    public static bool CanRead(string vol, out string err)
    {
        err = "";
        try { using (FileStream fs = new FileStream(vol, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) { } return true; }
        catch (Exception ex) { err = ex.Message; return false; }
    }

    public static bool CanWrite(string vol, out string err)
    {
        err = "";
        try { using (FileStream fs = new FileStream(vol, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { } return true; }
        catch (Exception ex) { err = ex.Message; return false; }
    }

    public static string Hex(byte[] b, int off, int len)
    {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < len && off + i < b.Length; i++) sb.Append(b[off + i].ToString("X2")).Append(' ');
        return sb.ToString().TrimEnd();
    }
}

// ---------------------------------------------------------------------------
// BpbBuilder: synthesize a FAT32 BIOS Parameter Block.
// Never invent values: every field must be derived from surviving structures
// (FAT media descriptors, data area alignment, partition table hidden sectors).
// ---------------------------------------------------------------------------
public class BpbBuilder
{
    public static byte[] BuildFat32(int bytesPerSector, int sectorsPerCluster, int reservedSectors,
        int numFats, long totalSectors, long fatSizeSectors, long hiddenSectors, long rootCluster,
        int fsInfoSector, int backupBootSector, string volumeLabel, uint volumeId)
    {
        byte[] b = new byte[bytesPerSector];
        b[0] = 0xEB; b[1] = 0x58; b[2] = 0x90;
        PutS(b, 3, "MSWIN4.1");
        PutU16(b, 11, bytesPerSector);
        b[13] = (byte)sectorsPerCluster;
        PutU16(b, 14, reservedSectors);
        b[16] = (byte)numFats;
        PutU16(b, 17, 0);
        PutU16(b, 19, 0);
        b[21] = 0xF8;
        PutU16(b, 22, 0);
        PutU16(b, 24, 63);
        PutU16(b, 26, 255);
        PutU32(b, 28, hiddenSectors);
        PutU32(b, 32, totalSectors);
        PutU32(b, 36, fatSizeSectors);
        PutU16(b, 40, 0);
        PutU16(b, 42, 0);
        PutU32(b, 44, rootCluster);
        PutU16(b, 48, fsInfoSector);
        PutU16(b, 50, backupBootSector);
        b[64] = 0x80; b[66] = 0x29;
        PutU32(b, 67, volumeId);
        PutS(b, 71, Pad11(volumeLabel));
        PutS(b, 82, "FAT32   ");
        b[510] = 0x55; b[511] = 0xAA;
        return b;
    }

    // Cross-check the synthesized BPB against measured values. Any mismatch means
    // the candidate geometry is wrong: do not write.
    public static string SelfCheck(byte[] bs, long measuredDataStart, long measuredFat2Offset)
    {
        long bps = BitConverter.ToUInt16(bs, 11);
        long spc = bs[13];
        long rsvd = BitConverter.ToUInt16(bs, 14);
        long numf = bs[16];
        long fatsz = BitConverter.ToUInt32(bs, 36);
        long tot = BitConverter.ToUInt32(bs, 32);
        long dataStart = (rsvd + numf * fatsz) * bps;
        long fat2 = (rsvd + fatsz) * bps;
        long clusters = (tot - (rsvd + numf * fatsz)) / spc;
        StringBuilder sb = new StringBuilder();
        sb.AppendLine("bytesPerSector=" + bps + " sectorsPerCluster=" + spc + " reserved=" + rsvd + " fats=" + numf + " fatSectors=" + fatsz + " totalSectors=" + tot);
        sb.AppendLine("derived dataStart=" + dataStart + " measured=" + measuredDataStart + " => " + (dataStart == measuredDataStart ? "MATCH" : "MISMATCH"));
        sb.AppendLine("derived FAT2 offset=" + fat2 + " measured=" + measuredFat2Offset + " => " + (fat2 == measuredFat2Offset ? "MATCH" : "MISMATCH"));
        sb.AppendLine("cluster count=" + clusters);
        if (clusters < 65525) sb.AppendLine("WARNING: cluster count below FAT32 minimum (65525) - this is not a valid FAT32 geometry");
        return sb.ToString();
    }

    static string Pad11(string s)
    {
        if (s == null) s = "";
        if (s.Length > 11) s = s.Substring(0, 11);
        return s.PadRight(11, ' ');
    }
    static void PutS(byte[] b, int o, string s) { for (int i = 0; i < s.Length; i++) b[o + i] = (byte)s[i]; }
    static void PutU16(byte[] b, int o, int v) { b[o] = (byte)(v & 0xFF); b[o + 1] = (byte)((v >> 8) & 0xFF); }
    static void PutU32(byte[] b, int o, long v) { for (int i = 0; i < 4; i++) b[o + i] = (byte)((v >> (8 * i)) & 0xFF); }
}

// ---------------------------------------------------------------------------
// FatImage: FAT table access + cluster chain walking over a volume or image file.
// Geometry is always supplied by the caller (derived in 03_probe_geometry).
// Keeps both FAT copies so callers can arbitrate FAT1-vs-FAT2 by validation
// instead of assuming FAT1 is correct.
// ---------------------------------------------------------------------------
public class FatImage
{
    public string Path;
    public long DataStart;
    public int ClusterSize;
    public long Fat1Offset, Fat2Offset, FatBytes;
    public int TotalClusters;
    public uint[] Fat1, Fat2;
    public bool[] Conflict;

    FileStream fs;

    public FatImage(string path, long dataStart, int clusterSize, long fat1Offset, long fat2Offset, long fatBytes, int totalClusters)
    {
        Path = path; DataStart = dataStart; ClusterSize = clusterSize;
        Fat1Offset = fat1Offset; Fat2Offset = fat2Offset; FatBytes = fatBytes; TotalClusters = totalClusters;
        fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        Fat1 = LoadFat(fat1Offset);
        Fat2 = LoadFat(fat2Offset);
        Conflict = new bool[Fat1.Length];
        for (int i = 0; i < Fat1.Length; i++) Conflict[i] = Fat1[i] != Fat2[i];
    }

    uint[] LoadFat(long off)
    {
        byte[] b = new byte[FatBytes];
        fs.Position = off;
        int got = 0;
        while (got < b.Length) { int n = fs.Read(b, got, b.Length - got); if (n <= 0) break; got += n; }
        uint[] a = new uint[FatBytes / 4];
        for (int i = 0; i < a.Length; i++) a[i] = BitConverter.ToUInt32(b, i * 4) & 0x0FFFFFFFu;
        return a;
    }

    public long ClusterOffset(long c) { return DataStart + (c - 2) * ClusterSize; }

    public byte[] ReadCluster(uint c)
    {
        byte[] b = new byte[ClusterSize];
        fs.Position = ClusterOffset(c);
        int got = 0;
        while (got < b.Length) { int n = fs.Read(b, got, b.Length - got); if (n <= 0) break; got += n; }
        return b;
    }

    // Reads the full cluster and copies only `len` bytes: the tail of a file is
    // rarely a whole number of clusters, and partial-length device reads fail.
    public int ReadInto(uint c, byte[] buf, int off, int len)
    {
        byte[] cb = ReadCluster(c);
        int take = len < cb.Length ? len : cb.Length;
        Array.Copy(cb, 0, buf, off, take);
        return take;
    }

    public uint Next(uint c, bool useFat2) { return useFat2 ? Fat2[c] : Fat1[c]; }

    public List<uint> Chain(uint start, bool useFat2, out string issue)
    {
        issue = "";
        List<uint> c = new List<uint>();
        HashSet<uint> seen = new HashSet<uint>();
        uint cur = start;
        int guard = 0;
        while (true)
        {
            if (guard++ > 4000000) { issue = "guard exceeded"; break; }
            if (cur < 2 || cur >= TotalClusters) { issue = "cluster out of range: " + cur; break; }
            if (!seen.Add(cur)) { issue = "loop at cluster " + cur; break; }
            c.Add(cur);
            uint nx = Next(cur, useFat2);
            if (nx >= 0x0FFFFFF8) break;
            if (nx == 0) { issue = "reaches a FREE cluster after " + cur; break; }
            if (nx == 0x0FFFFFF7) { issue = "reaches a BAD-marked cluster after " + cur; break; }
            cur = nx;
        }
        return c;
    }

    public static long NeedClusters(long size, int clusterSize)
    {
        if (size <= 0) return 0;
        return (size + clusterSize - 1) / clusterSize;
    }

    public void Close() { fs.Close(); }
}

// ---------------------------------------------------------------------------
// TreeWalker: LFN-aware directory tree walk with per-file chain validation.
// ---------------------------------------------------------------------------
public class FileRec
{
    public string Name = "", ShortName = "", Dir = "";
    public long Size;
    public uint FirstCluster;
    public bool IsDir;
    public int Chain1Count, Chain2Count;
    public string Chain1Issue = "", Chain2Issue = "";
    public string Path { get { return Dir.Length == 0 ? Name : Dir + "\\" + Name; } }
}

public class TreeWalker
{
    FatImage img;
    uint rootCluster;
    public List<FileRec> Files = new List<FileRec>();
    public List<string> Dirs = new List<string>();
    public int DeletedEntries = 0;
    public List<string> Issues = new List<string>();

    public TreeWalker(FatImage image, uint root)
    {
        img = image; rootCluster = root;
    }

    public void Walk() { WalkDir(rootCluster, "", 0); }

    static string San(string s)
    {
        char[] bad = new char[] { ':', '*', '?', '"', '<', '>', '|', '\\', '/' };
        StringBuilder sb = new StringBuilder();
        foreach (char ch in s) sb.Append(Array.IndexOf(bad, ch) >= 0 ? '_' : (ch < 32 ? '_' : ch));
        while (sb.Length > 0 && (sb[sb.Length - 1] == '.' || sb[sb.Length - 1] == ' ')) sb.Length--;
        return sb.Length == 0 ? "_" : sb.ToString();
    }

    static string DecodeLfn(List<byte[]> parts, byte[] dir, int off)
    {
        if (parts.Count == 0) return "";
        byte sum = 0;
        for (int i = 0; i < 11; i++) sum = (byte)(((sum & 1) << 7) + (sum >> 1) + dir[off + i]);
        foreach (byte[] e in parts) if (e[13] != sum) return "";
        parts.Sort((a, b) => (a[0] & 0x3F).CompareTo(b[0] & 0x3F));
        for (int k = 0; k < parts.Count; k++) if ((parts[k][0] & 0x3F) != k + 1) return "";
        int[] o1 = new int[] { 1, 3, 5, 7, 9 };
        int[] o2 = new int[] { 14, 16, 18, 20, 22, 24 };
        int[] o3 = new int[] { 28, 30 };
        int[][] all = new int[][] { o1, o2, o3 };
        StringBuilder sb = new StringBuilder();
        foreach (byte[] e in parts)
            foreach (int[] arr in all)
                foreach (int k in arr)
                {
                    int ch = e[k] | (e[k + 1] << 8);
                    if (ch == 0) return sb.ToString();
                    if (ch == 0xFFFF) continue;
                    sb.Append((char)ch);
                }
        return sb.ToString();
    }

    void WalkDir(uint cluster, string parent, int depth)
    {
        if (depth > 40) { Issues.Add("depth limit reached at " + parent); return; }
        string issue;
        List<uint> chain = img.Chain(cluster, false, out issue);
        if (issue != "")
        {
            string i2; List<uint> c2 = img.Chain(cluster, true, out i2);
            if (i2 == "" || c2.Count > chain.Count) { chain = c2; Issues.Add("dir " + parent + " read via FAT2 (" + issue + ")"); }
        }
        List<byte[]> lfn = new List<byte[]>();
        foreach (uint c in chain)
        {
            byte[] buf;
            try { buf = img.ReadCluster(c); } catch (Exception ex) { Issues.Add("dir cluster read failed at " + c + ": " + ex.Message); return; }
            for (int i = 0; i + 32 <= img.ClusterSize; i += 32)
            {
                byte first = buf[i];
                if (first == 0x00) return;
                byte attr = buf[i + 11];
                if (first == 0xE5) { DeletedEntries++; lfn.Clear(); continue; }
                if (attr == 0x0F) { byte[] e = new byte[32]; Array.Copy(buf, i, e, 0, 32); lfn.Add(e); continue; }
                if ((attr & 0x08) != 0 && (attr & 0x10) == 0) { lfn.Clear(); continue; }
                if (buf[i] == '.') { lfn.Clear(); continue; }
                string shortName = Encoding.ASCII.GetString(buf, i, 8).TrimEnd(' ') + "." + Encoding.ASCII.GetString(buf, i + 8, 3).TrimEnd(' ');
                string longName = DecodeLfn(lfn, buf, i);
                lfn.Clear();
                string nm = longName.Length > 0 ? longName : shortName;
                uint hi = (uint)(buf[i + 20] | (buf[i + 21] << 8));
                uint lo = (uint)(buf[i + 26] | (buf[i + 27] << 8));
                uint fc = (hi << 16) | lo;
                long size = BitConverter.ToUInt32(buf, i + 28);
                bool isDir = (attr & 0x10) != 0;
                if (isDir)
                {
                    Dirs.Add(parent + "\\" + San(nm));
                    if (fc >= 2 && fc < img.TotalClusters) WalkDir(fc, parent + "\\" + San(nm), depth + 1);
                    continue;
                }
                FileRec r = new FileRec();
                r.Name = nm; r.ShortName = shortName; r.Dir = parent; r.Size = size; r.FirstCluster = fc; r.IsDir = false;
                if (size > 0 && fc >= 2 && fc < img.TotalClusters)
                {
                    r.Chain1Count = img.Chain(fc, false, out r.Chain1Issue).Count;
                    r.Chain2Count = img.Chain(fc, true, out r.Chain2Issue).Count;
                }
                Files.Add(r);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Carver: recovery of files whose FAT chain is destroyed.
// Strategy 1 - contiguous run: camera/app writes are usually contiguous; verify
//              with the file's own structural markers, never assume.
// Strategy 2 - fingerprint: search cluster-aligned starts whose EOI/marker lands
//              exactly at start+size-2. The EOI probe MUST use an aligned read.
// ---------------------------------------------------------------------------
public class Carver
{
    FatImage img;
    public Carver(FatImage image) { img = image; }

    public long ReadContiguous(uint cluster, long size, string outPath, out string err)
    {
        err = "";
        long written = 0;
        try
        {
            using (FileStream o = new FileStream(outPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
            {
                long remain = size;
                long c = cluster;
                byte[] buf = new byte[img.ClusterSize];
                while (remain > 0)
                {
                    buf = img.ReadCluster((uint)c);
                    int take = (int)(remain < img.ClusterSize ? remain : img.ClusterSize);
                    o.Write(buf, 0, take);
                    written += take; remain -= take; c++;
                }
                o.Flush(true);
            }
        }
        catch (Exception ex) { err = ex.Message; }
        return written;
    }

    public bool HasJpegEnding(string path, long declaredSize)
    {
        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (fs.Length < declaredSize) return false;
                fs.Position = declaredSize - 2;
                int a = fs.ReadByte(), b = fs.ReadByte();
                return a == 0xFF && b == 0xD9;
            }
        }
        catch { return false; }
    }

    public string FindJpegBySize(uint fc, long size, int radius, string outPath, out long foundCluster)
    {
        foundCluster = -1;
        byte[] hdr = new byte[4];
        for (int r = 0; r <= radius; r++)
        {
            for (int s = 0; s < 2; s++)
            {
                if (r == 0 && s == 1) continue;
                long cc = (long)fc + (s == 0 ? r : -r);
                if (cc < 2 || cc >= img.TotalClusters) continue;
                long off = img.ClusterOffset(cc);
                try
                {
                    hdr = RawVol.ReadAny(img.Path, off, 4);
                }
                catch { continue; }
                if (!(hdr[0] == 0xFF && hdr[1] == 0xD8 && hdr[2] == 0xFF)) continue;
                long eoiOff = off + size - 2;
                byte[] tail;
                try { tail = RawVol.ReadAny(img.Path, eoiOff, 2); } catch { continue; }
                if (!(tail[0] == 0xFF && tail[1] == 0xD9)) continue;
                string err;
                long w = ReadContiguous((uint)cc, size, outPath, out err);
                if (w == size) { foundCluster = cc; return "MATCH cluster " + cc + " (delta " + (cc - fc) + ")"; }
                return "match at " + cc + " but copy failed: " + err;
            }
        }
        return "not found within +/- " + radius + " clusters";
    }
}

// ---------------------------------------------------------------------------
// MediaAudit: structural validation of copied media.
// This is what catches "copied without error but the content is wrong" - a
// byte-for-byte comparison cannot, because both sides read the same wrong data.
//
// PITFALL: phone media commonly carries trailing data after the JPEG EOI
// (motion photos, depth maps, camera firmware metadata) and MP4s may carry a
// non-ISO trailer. Verdicts must tolerate that: look for the marker anywhere
// after SOS / after the last box, not only at EOF.
// ---------------------------------------------------------------------------
public class MediaAudit
{
    public static string Jpeg(string path, out string note)
    {
        note = "";
        byte[] b = File.ReadAllBytes(path);
        if (b.Length < 8) return "TOO-SMALL";
        if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47)
        {
            // IEND chunk type sits at length-8 in a well-formed PNG; search from
            // length-4 so truncated/CRC-less variants are still recognised.
            for (int k = b.Length - 4; k >= 0 && k > b.Length - 65536; k--)
                if (b[k] == 0x49 && b[k + 1] == 0x45 && b[k + 2] == 0x4E && b[k + 3] == 0x44) { note = "PNG"; return "OK"; }
            note = "PNG without IEND"; return "PNG-TRUNCATED";
        }
        if (!(b[0] == 0xFF && b[1] == 0xD8)) { note = "head " + b[0].ToString("X2") + " " + b[1].ToString("X2"); return "NO-SOI"; }
        int i = 2, w = 0, h = 0, segs = 0; bool sos = false;
        while (i + 3 < b.Length)
        {
            if (b[i] != 0xFF) { note = "at " + i; return "BROKEN-HEADER"; }
            byte m = b[i + 1];
            if (m == 0xFF) { i++; continue; }
            if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
            if (m == 0xD9) break;
            if (m == 0xDA) { sos = true; break; }
            int sl = (b[i + 2] << 8) | b[i + 3];
            if (sl < 2 || i + 2 + sl > b.Length) { note = "at " + i; return "SEG-OVERRUN"; }
            if ((m >= 0xC0 && m <= 0xC3) || (m >= 0xC5 && m <= 0xC7) || (m >= 0xC9 && m <= 0xCB) || (m >= 0xCD && m <= 0xCF))
            { h = (b[i + 5] << 8) | b[i + 6]; w = (b[i + 7] << 8) | b[i + 8]; }
            segs++; i += 2 + sl;
        }
        if (!sos) return "NO-SOS";
        long eoi = -1;
        for (long k = i + 2; k + 1 < b.Length; k++) if (b[k] == 0xFF && b[k + 1] == 0xD9) { eoi = k; break; }
        if (eoi < 0) { note = w + "x" + h; return "NO-EOI"; }
        note = w + "x" + h + " segs=" + segs + " trailer=" + (b.Length - eoi - 2) + "B";
        return "OK";
    }

    public static string Mp4(string path)
    {
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            long len = fs.Length, pos = 0; bool moov = false; int boxes = 0;
            byte[] hdr = new byte[16];
            while (pos + 8 <= len && boxes < 500)
            {
                fs.Position = pos;
                int got = fs.Read(hdr, 0, 16);
                if (got < 8) break;
                long size = ((long)hdr[0] << 24) | ((long)hdr[1] << 16) | ((long)hdr[2] << 8) | hdr[3];
                string type = Encoding.ASCII.GetString(hdr, 4, 4);
                if (size == 1 && got >= 16)
                    size = ((long)hdr[8] << 56) | ((long)hdr[9] << 48) | ((long)hdr[10] << 40) | ((long)hdr[11] << 32) | ((long)hdr[12] << 24) | ((long)hdr[13] << 16) | ((long)hdr[14] << 8) | hdr[15];
                if (size < 8) return "BAD-BOX@" + pos + " after " + boxes + " boxes";
                if (type == "moov") moov = true;
                boxes++; pos += size;
            }
            if (!moov) return "NO-MOOV (" + boxes + " boxes)";
            if (pos > len) return "WALK-PAST-END";
            long gap = len - pos;
            if (gap == 0) return "OK (exact, " + boxes + " boxes)";
            byte[] tb = new byte[16];
            fs.Position = pos;
            int g = 0;
            while (g < 16) { int n = fs.Read(tb, g, 16 - g); if (n <= 0) break; g += n; }
            string asc = "";
            for (int k = 0; k < 12 && k < g; k++) asc += (tb[k] >= 32 && tb[k] < 127) ? (char)tb[k] : '.';
            return "OK (trailer " + gap + "B: '" + asc + "')";
        }
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp
