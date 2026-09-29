# FAT32 几何：偏移、反推与验证

引导记录（BPB）丢失后，恢复所需的全部参数仍然可以从**残留结构**里反推。
这份文档给出偏移表、反推公式、以及每个值必须通过的验证。

---

## 1. 关键结构与其固定签名

| 结构 | 位置 | 签名 / 判据 |
|---|---|---|
| 引导记录 DBR | 卷偏移 0 | 末两字节 `55 AA` + BPB 字段自洽 |
| FSInfo | 卷偏移 512 | `0x41615252`（`RRaA`）、`0x1E4` 处 `0x61417272`（`rrAa`）、`0x1FC` 处 `0xAA550000` |
| 备份引导 | 卷偏移 6×512 | 与 DBR 逐字节相同 |
| 备份 FSInfo | 卷偏移 7×512 | 与 FSInfo 逐字节相同 |
| FAT1 | `保留扇区数 × 512` | 首 4 字节 `F8 FF FF 0F`，第 5–8 字节 `FF FF FF 0F` |
| FAT2 | `(保留 + FAT扇区数) × 512` | 同上 |
| 数据区起点 | `(保留 + FAT份数 × FAT扇区数) × 512` | 簇 2 必须是根目录 |
| 根目录 | 数据区起点（簇 2） | 32 字节目录项，合法属性字节，存在 `0x00` 终止项 |

> **为什么要检查两个 FAT 的签名**：FAT1 与 FAT2 的偏移之差**就是** FAT 的大小，
> 这是重新推导几何的锚点。

---

## 2. 反推公式

设：
- `totalSectors` = 分区（或镜像）字节数 / 512
- `fat1Off`、`fat2Off` = 两个 `F8 FF FF 0F` 命中的偏移

```
FAT字节数        fatBytes      = fat2Off - fat1Off
FAT扇区数        fatSizeSectors= fatBytes / 512
保留扇区数       reserved      = fat1Off / 512
FAT 条目数       entries       = fatBytes / 4
最大簇数         maxClusters   = entries - 2
```

`sectorsPerCluster` 由"条目数必须够用"反解，并向上取 2 的幂：

```
numFATs ∈ {2, 1}
dataSectors = totalSectors - reserved - numFATs × fatSizeSectors
spc         = 2^ceil(log2(dataSectors / maxClusters))
dataStart   = (reserved + numFATs × fatSizeSectors) × 512
clusters    = floor(dataSectors / spc)
```

判优标准：**`clusters` 与 `maxClusters` 的相对误差最小**，且 `clusters ≥ 65525`
（低于此值就不是合法 FAT32）。

`hiddenSectors` 取自 MBR 的分区起始 LBA，**不是猜的**：

```
hiddenSectors = 分区偏移字节数 / 512
```

---

## 3. 必须通过的验证（缺一不可）

| 检查 | 判据 | 不通过意味着 |
|---|---|---|
| 簇 2 是目录 | 存在合法目录项 + 存在 `0x00` 终止项 + 非全零 | 几何错，或簇大小错 |
| FAT2 偏移自洽 | `(reserved + fatSizeSectors) × 512 == fat2Off` | FAT 份数或大小推错 |
| 簇数下界 | `clusters ≥ 65525` | 不是合法 FAT32 几何 |
| 条目误差 | `|clusters - maxClusters| / maxClusters ≤ 1%` | 推导不可信，禁止写入 |
| 分区起始 | `hiddenSectors` 与 MBR 记录一致 | 写进 BPB 会让工具误判卷位置 |

---

## 4. 实例一：真实事故（aigo U351，58.6 GB）

实测锚点：FAT1 @ 27,648 字节、FAT2 @ 7,706,112 字节。

```
fatBytes       = 7,706,112 - 27,648 = 7,678,464
fatSizeSectors = 7,678,464 / 512    = 14,997
reserved       = 27,648 / 512       = 54
entries        = 7,678,464 / 4      = 1,919,616
maxClusters    = 1,919,614
totalSectors   = 62,914,347,008 / 512 = 122,879,584
numFATs        = 2
dataSectors    = 122,879,584 - 54 - 2×14,997 = 122,849,536
spc            = 122,849,536 / 1,919,614 ≈ 64.0  ->  64
dataStart      = (54 + 2×14,997) × 512 = 15,384,576
clusters       = 122,849,536 / 64 = 1,919,524      (误差 0.005%)
hiddenSectors  = 32,768 / 512 = 64                 (与 MBR 分区项一致)
```

验证：簇 2 @ 15,384,576 读出的第一项是 `LOST    DIR`（属性 0x10，目录），
偏移 +64 是 `ANDROID    ` —— **目录项与推导位置逐字节吻合**。

写回的引导记录参数：

```
512 字节/扇区, 64 扇区/簇, 保留 54, FAT 份数 2, FAT 14,997 扇区/份,
总扇区 122,879,584, 根目录簇 2, FSInfo 1, 备份引导 6, 隐藏扇区 64, 卷标 NO NAME
```

结果：卷被系统正常识别为 FAT32，全部目录可读。

---

## 5. 实例二：合成测试镜像（tests/fixture）

用于在**没有硬件**的情况下验证整条流水线：

```
总量 64 MB, 512 字节/扇区, 1 扇区/簇（512 字节）, 保留 32,
FAT 份数 2, 每份 1,009 扇区, 隐藏扇区 2,048
FAT1 @ 16,384   FAT2 @ 532,992
dataStart = (32 + 2×1,009) × 512 = 1,049,600
clusters  = (131,072 - 2,050) / 1 = 129,022      (≥ 65,525，合法 FAT32)
```

夹具把这台"盘"做出三种形态：

| 文件 | 状态 |
|---|---|
| `clean.img` | 完好 |
| `damaged.img` | LBA0 / LBA6 / LBA7 被外来数据覆盖，**LBA1 FSInfo 故意保留**（事故特征） |
| `broken.img` | 在 damaged 基础上再释放一个文件的 FAT 链（练抢救路径） |

`03_probe_geometry.ps1` 对 `damaged.img` 反推出的四个关键值（保留 32 / FAT 大小 1,009 /
簇 512 / 数据区 1,049,600）与构造成值**完全一致**，自洽判定为 true。

---

## 6. 卷大小从哪里来

| 场景 | 来源 | 注意 |
|---|---|---|
| 分区可识别 | `Get-Partition -DriveLetter X` 的 `Size` / `Offset` | `Offset/512` 就是 hiddenSectors |
| 卷对象异常（Size=0） | 只能靠分区 | 这正是"文件系统无法识别"的典型表现 |
| 镜像文件 | 文件长度 | 分区级镜像，不包含 MBR |

**分区大小 ≠ 磁盘大小**：两者差值是分区表之外的保留区，不要把磁盘大小当成卷大小，
否则 `totalSectors` 会偏大、簇数误差上升。

---

## 7. 不能靠反推解决的情况

- **分区表本身损坏** → 需要物理盘级工具，本技能只做只读判定
- **FAT 两份都被清零** → 没有 FAT 大小锚点，反推不成立
- **exFAT / NTFS** → 引导记录是必需的语义载体（exFAT 还带校验和、NTFS 带 `$MFT` 指针），
  不适合"重建引导记录"这条路，应转数据雕刻或专业恢复
- **硬件加密主控的 U 盘** → 卷层看到的可能是解密后的视图，重建没有意义
