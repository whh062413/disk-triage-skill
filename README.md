# disk-triage

**Read-only triage and minimal-write repair for volumes Windows refuses to mount.**

U 盘、移动硬盘、SD 卡打不开，Windows 提示「需要格式化」时，坏的往往只是引导记录那一小块；
数据、FAT 表、目录树通常都还在。这个技能不格式化、不跑 `chkdsk /f`，
而是**只读取证 → 反推几何 → 镜像优先 → 最小写入重建引导记录**。

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
# 0. 打开【管理员】PowerShell（写回阶段需要；只读阶段不需要）

# 1. 只读取证：这个卷到底坏在哪一层
.\scripts\01_triage.ps1 -Volume '\\.\E:'

# 2. 只读镜像 + 头部保险（可续跑，带重试阶梯与坏块记录）
.\scripts\02_image.ps1 -Volume '\\.\E:' -OutDir 'D:\E_recovery\00_IMAGE'

# 3. 从残留结构反推文件系统几何
.\scripts\03_probe_geometry.ps1 -Volume '\\.\E:'

# 4. 生成引导记录（默认演练，不写入）
.\scripts\04_rebuild_bpb.ps1 -Volume '\\.\E:' -DataStart 15384576 -Fat2Offset 7706112 -FatSizeSectors 14997 -ReservedSectors 54 -SectorsPerCluster 64 -TotalSectors 122879584

# 5. 复核通过、镜像已具备后，才真正写回（仅 3 个扇区）
.\scripts\04_rebuild_bpb.ps1 ... -Apply

# 6. 拔插重挂后：遍历校验 / 抢救 / 媒体结构审计
.\scripts\05_walk_and_validate.ps1 -Volume '\\.\E:' -ReportDir 'D:\E_recovery\30_REPORT'
.\scripts\06_rescue.ps1 -Volume '\\.\E:' -OutDir 'D:\E_recovery\40_RESCUE' -Targets .\targets.txt
.\scripts\07_audit_media.ps1 -Root 'D:\E_recovery\20_EXTRACT'
```

## 目录结构

```
SKILL.md                          技能入口：铁律、决策树、写盘准入门槛
README.md                         本文件
lib/FatLib.ps1                    共享引擎（C#）：卷读写、FAT 链、LFN 遍历、指纹雕刻、媒体结构审计、BPB 构造
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

不需要真盘、不需要管理员：

```powershell
.\tests\run_tests.ps1
```

它合成 64 MB 的 FAT32 镜像并跑通全流程——含"引导记录被覆盖"与"FAT 链被释放"两种故障形态，
断言几何反推出的四个关键值与构造值逐字节一致。当前结果：**31 passed / 0 failed**。

## 适用 / 不适用

**适用**：单分区 FAT32/exFAT 可移动介质；引导记录（BPB）丢失或损坏；备份引导与 FSInfo 同样损坏；
FAT1/FAT2 不一致；目录树完好但有少量文件簇链损坏。

**不适用**：分区表损坏（需物理盘级工具）、物理层故障（需专业恢复）、加密卷、
硬件加密主控（部分国产 U 盘）——这些场景本技能只做只读判定与移交。

## 输出纪律

- 未恢复的文件必须**逐条列清单**（文件名、大小、日期、判断依据、找回建议）
- 校验结果必须区分：结构完好 / 结构完好但有尾部附加数据 / 内容不可用
- 报告必须写明「哪一步是只读、哪一步写了多少字节」

## 许可

脚本与文档按 MIT 使用。案例中的设备序列号等标识已做脱敏说明。
