# disk-triage · 磁盘只读取证与最小写入修复

> **Read-only triage and minimal-write repair for volumes Windows refuses to mount.**

U 盘、移动硬盘、SD 卡打不开、Windows 提示「需要格式化」时，坏的往往只是引导记录那一小块；
数据、FAT 表、目录树通常都还在。这个工具不格式化、不跑 `chkdsk /f`，
而是 **只读取证 → 反推几何 → 镜像优先 → 最小写入重建引导记录 → 结构校验 → 抢救**。

---

## 先分清：哪个盘是外接的，哪个是本机的

这个工具会**读**一整块盘、并在写回阶段**向那块盘写入 1.5 KB**。
所以第一件事永远是确认盘符——文档里的 `E:` 和 `D:` 只是示例占位。

| 角色 | 示例（仅示例） | 是什么 | 传给哪些参数 | 本工具对它做什么 |
|---|---|---|---|---|
| **外接故障盘** | `E:` / `\\.\E:` | 打不开、提示格式化的那块 U 盘 / 移动硬盘 / SD 卡 | `-Source`、`-Volume` | 全程只读；仅在 `04 -Apply` 时写入 3 个扇区（1.5 KB） |
| **本机工作盘** | `D:\case` | 本机固定硬盘上的一个目录，用来放镜像、导出文件、报告 | `-OutDir`、`-ReportDir`、`-Csv` | 普通文件读写；不碰设备 |

**怎么看出来的**——用总线类型区分，不要靠盘符猜：

```powershell
.\scripts\00_show_devices.ps1
```

输出里每一块盘都带角色标记：

```
  No   Role       Model                      Bus        SizeGB  State
  0    [INTERNAL] UMIS RPJYJ1T24RLS1QWY      NVMe        953.9  Online/Healthy
  1    [EXTERNAL] aigo U351 USB Device       USB          58.6  Online/Healthy
```

`[EXTERNAL]` = USB / SD / MMC 等可移动介质 → 故障盘，指向它的是 `-Source` / `-Volume`。
`[INTERNAL]` = NVMe / SATA 等固定盘 → 工作盘，指向它的是 `-OutDir` / `-ReportDir`。

还可以直接校验你打算用的这一对路径是否分属两块不同物理盘：

```powershell
.\scripts\00_show_devices.ps1 -Source '\\.\E:' -WorkDir 'D:\case'
```

若两者落在同一块物理盘上，脚本会红字报 `STOP`——镜像和故障盘同盘，等于没有备份。

> **本仓库不含任何默认盘符。** 所有 `-Source` / `-Volume` / `-OutDir` / `-ReportDir` / `-Root`
> 都必须显式传入；`01`/`02` 的目标盘参数是 `Mandatory`，漏传会直接报错而不是"默认拿 E 盘试试"。
>
> 反过来说：**照抄文档示例是有风险的**。如果你的机器上 `D:` 恰好就是那块外接盘，
> 照抄 `-OutDir 'D:\...'` 就会把 58 GB 镜像写回故障盘本身。所以下面快速开始用变量，而不是写死盘符。

---

## 方法论

```
只读取证  →  判定损坏层次  →  镜像/头部保险  →  几何反推  →  生成 BPB  →  演练  →  写回  →  校验  →  抢救  →  清单
```

四条不可妥协的纪律：

1. **不写入，直到只读取证完成**
2. **先镜像，后操作**（卷头所在的 NAND 擦除块可能与 FAT 起始区同块）
3. **每次写入前备份原始扇区、现场复核、写后回读校验**
4. **结论来自证据**——「能救多少」由指纹扫描等证据给出，不由工具承诺

## 快速开始

```powershell
# 0. 先看设备，确认哪个字母是外接故障盘、哪个是本机工作盘
.\scripts\00_show_devices.ps1

# 1. 设两个变量，后面所有命令都用它们，避免照抄盘符出错
$src  = '\\.\E:'      # ← 换成你的【外接故障盘】
$work = 'D:\case'     # ← 换成空间足够的【本机目录】（需要 ≥ 源盘容量的空闲空间）

# 顺便校验这两个不在同一块物理盘上
.\scripts\00_show_devices.ps1 -Source $src -WorkDir $work

# 2. 只读取证：这个卷到底坏在哪一层（不需要管理员）
.\scripts\01_triage.ps1 -Volume $src

# 3. 只读镜像 + 头部保险（可续跑、带重试阶梯与坏块记录；期间不要碰这块盘）
.\scripts\02_image.ps1 -Volume $src -OutDir "$work\00_IMAGE"

# 4. 从残留结构反推文件系统几何
.\scripts\03_probe_geometry.ps1 -Source $src -GeometryFile "$work\geometry.json"

# 5. 生成引导记录并演练（默认不写入）
.\scripts\04_rebuild_bpb.ps1 -Source $src -GeometryFile "$work\geometry.json" -OutDir "$work\10_FIXED"

# 6. 复核通过、镜像已具备、且已提权，才真正写回（仅 3 个扇区 / 1.5 KB）
#    建议同时传 -ExpectFriendlyName 防止写错设备
.\scripts\04_rebuild_bpb.ps1 -Source $src -GeometryFile "$work\geometry.json" -OutDir "$work\10_FIXED" `
    -ExpectFriendlyName 'aigo' -Apply

# 7. 拔插重挂后：遍历校验 / 抢救 / 媒体结构审计
.\scripts\05_walk_and_validate.ps1 -Source $src -GeometryFile "$work\geometry.json" -ReportDir "$work\30_REPORT"
.\scripts\06_rescue.ps1 -Source $src -GeometryFile "$work\geometry.json" -OutDir "$work\40_RESCUE" -AllBroken
.\scripts\07_audit_media.ps1 -Root "$work\20_EXTRACT" -Csv "$work\30_REPORT\problem_files.csv"
```

`04_rebuild_bpb.ps1` 也支持传全部几何参数（`-SectorsPerCluster` `-ReservedSectors`
`-FatSizeSectors` `-TotalSectors` `-DataStart` `-Fat2Offset` 等）代替 `-GeometryFile`，
手抄参数时注意别串位——用 `03` 输出的 JSON 更安全。

## 目录结构

```
SKILL.md                          技能入口：铁律、决策树、写盘准入门槛
README.md                         本文件
lib/FatLib.ps1                    共享引擎（C#）：卷读写、FAT 链、LFN 遍历、指纹雕刻、媒体结构审计、BPB 构造
scripts/00_show_devices.ps1       盘符 → 物理盘映射，外接/本机判定，源/工作盘配对校验
scripts/01_triage.ps1             只读取证
scripts/02_image.ps1              只读镜像（可续跑）
scripts/03_probe_geometry.ps1     几何反推
scripts/04_rebuild_bpb.ps1        引导记录生成 / 写回（默认演练）
scripts/05_walk_and_validate.ps1  目录树遍历 + 簇链校验 + FAT 仲裁
scripts/06_rescue.ps1             连续簇抢救 + 指纹雕刻
scripts/07_audit_media.ps1        JPEG / MP4 结构校验
tests/make_fixture.ps1            合成 FAT32 测试镜像（clean / damaged / broken）
tests/run_tests.ps1               31 项端到端断言，无需硬件
references/pitfalls.md            12 条实战陷阱（必读）
references/fat32-geometry.md      FAT32 关键偏移与几何反推方法
references/case-aigo-u351.md      完整案例复盘
```

## 验证

不需要真盘、不需要管理员——测试全部跑在**合成镜像文件**上：

```powershell
.\tests\run_tests.ps1
```

它合成 64 MB 的 FAT32 镜像并跑通全流程，含「引导记录被覆盖」与「FAT 链被释放」两种故障形态，
断言几何反推出的四个关键值与构造值逐字节一致。当前结果：**31 passed / 0 failed**。

夹具是逻辑回归基线，不是硬件验证器：USB 桥异常、读超时、坏块这类问题无法在文件里合成，
由 `references/pitfalls.md` 与「先镜像」的纪律覆盖。夹具共 192 MB，已被 `.gitignore` 排除。

## 适用 / 不适用

**适用**：单分区 FAT32/exFAT 可移动介质；引导记录（BPB）丢失或损坏；备份引导与 FSInfo 同样损坏；
FAT1/FAT2 不一致；目录树完好但有少量文件簇链损坏。

**不适用**：分区表损坏（需物理盘级工具）、物理层故障（需专业恢复）、加密卷、
硬件加密主控（部分国产 U 盘）——这些场景本工具只做只读判定与移交。

## 输出纪律

- 未恢复的文件必须**逐条列清单**（文件名、大小、日期、判断依据、找回建议）
- 校验结果必须区分：结构完好 / 结构完好但有尾部附加数据 / 内容不可用
- 报告必须写明「哪一步是只读、哪一步写了多少字节」

## 许可

MIT，见 `LICENSE`。
