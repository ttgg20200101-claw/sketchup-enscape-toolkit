# sketchup-enscape-toolkit

给用 **SketchUp + Enscape** 的室内设计、工装团队用的模型资产工具：体检贴图会不会断链、批量建资产索引、把调好的材质和灯光「锁定」后随时比对和回滚、组件入库和一键投放、批量统计模型规范、给组件出标准图。

解决的是这些老问题：
- 模型拷到别的电脑，Enscape 一渲染，贴图全丢了
- 灯光和材质调好了，被人动过，回不去
- 公司攒了几百个模型，好用的组件找不到，每次重新建
- 模型里一堆 `Material #12`、`Component#3`，没人知道是什么

## 和 Enscape 的关系

[Enscape](https://www.enscape3d.com/) 是 SketchUp 上常用的实时渲染插件。它把自己的材质扩展设置（粗糙度、金属度、凹凸 / 粗糙度 / 高光 / 遮罩贴图）、视觉设置（曝光、灯光、阴影、出图分辨率）和灯光都存在 .skp 文件里，这套工具读的、管的主要就是这部分数据。

**贴图为什么会断链**：SketchUp 原生材质只有一张颜色贴图，会内嵌进 .skp；Enscape 额外加的凹凸、粗糙度等贴图，SketchUp 没地方存，只能记一个外部文件路径（比如 `C:\Users\张三\Desktop\xxx.jpg`），模型拷到别的电脑就找不到了。

## 两类工具

| 类别 | 工具 | 做什么 | 运行环境 | 需要 Enscape 数据吗 |
|---|---|---|---|---|
| **不用打开 SketchUp** | `standalone/skp_audit.py` | 单个模型的材质体检报告：贴图外部依赖（断链风险）、素材来源、命名、材质参数、出图分辨率 | Python 3，任意系统 | 需要 |
| | `standalone/gz_scan.py` | 批量扫描目录里的所有 .skp，生成资产索引 `assets.json`；支持增量（没改过的文件不重扫）；在 Windows 上会实际检查外链贴图在不在 | Python 3，任意系统 | 需要 |
| **在 SketchUp 里用** | `sketchup/gz_asset_plugin/` | 插件「工装资产」：锁定当前效果、与快照比对、回滚到快照、选中组件入库、资产库投放 | 按 SketchUp 2020（Ruby 2.5）写 | 部分：材质快照和组件库不需要；灯光、视觉设置需要 |
| | `sketchup/scripts/skp_batch.rb` | 在 SketchUp 里批量打开一个目录的模型，统计组件、材质、标签，检查命名规范，输出 JSON + CSV；模型一律不保存 | 按 SketchUp 2022 写 | 不需要 |
| | `sketchup/scripts/render_assets.rb` | 把当前模型的顶层组件逐个隔离，出正 / 侧 / 顶 / 轴测四张白底图 + 信息表；所有改动结束时撤销，不保存模型 | 按 SketchUp 2024 写 | 不需要 |
| | `sketchup/scripts/skp_report.rb` | 统计当前打开的模型：组件、组、材质、标签 | 按 SketchUp 2020 写 | 不需要 |

所有工具对原始 .skp 都是**只读**的，插件的回滚除外（回滚本身就是要改模型，且是一次可撤销操作）。

## 材质体检：`skp_audit.py`

```bash
python3 standalone/skp_audit.py 模型.skp -o 体检报告.md
```

只用 Python 标准库，不打开 SketchUp、不需要 GPU。1.6GB 的模型在 Apple 芯片上约 30 秒。

报告包括：

1. **数据盘点**：Enscape 材质块、灯光、设置字典各有多少
2. **贴图外部依赖（断链风险）**：按贴图槽 × 来源交叉统计，列出外部依赖的目录、路径里出现的 Windows 用户名
3. **贴图来源与命名**：第三方素材站指纹（3d66、知末、Quixel 等）、V-Ray / 3ds Max 残留命名、哈希式无意义文件名
4. **Enscape 材质格式版本分布**
5. **材质参数分布**：粗糙度、金属度、凹凸等，自动剔除 `-inf` 等非法值
6. **出图设置**：分辨率预设、可读写的视觉设置键
7. **结论**：按实际数据给出

一个关键判断：**断链风险由贴图的 `Source` 决定，不由路径决定**。路径指向 `%TEMP%` 的贴图看着危险，但只要 `Source=SKETCHUP`，像素已经内嵌在 .skp 里，换机后 Enscape 会自动重建；真正会丢的是 `Source=TEXTURE_PATH_ABSOLUTE` 的外部绝对路径，通常集中在 Enscape 专属的凹凸、粗糙度、高光、遮罩贴图槽，因为 SketchUp 原生材质没有这些槽位，无处内嵌。

**局限**：只解析 Enscape 写进 .skp 的材质信息。没用过 Enscape 的模型，报告会直接说明「没有找到 Enscape 材质数据」。

## 批量扫描：`gz_scan.py`

```bash
python3 standalone/gz_scan.py --index 索引目录 模型目录1 模型目录2
python3 standalone/gz_scan.py --index 索引目录          # 不带目录：重扫上次记住的全部目录
```

Windows 上可以把文件夹直接拖到 `standalone/scan.bat` 上，索引默认写到仓库根目录的 `index/`。`scan.bat` 优先用同目录下的便携版 `python\`，没有就用系统里装的 Python。

> 统计口径：扫描器的「外链贴图」是所有非内嵌、写了路径的贴图引用（含相对路径、旧格式里没写来源的），同样内容的材质会去重；体检报告的「真外部依赖」只算其中的 Windows 绝对路径。所以同一个模型，两边数字会不同。

## SketchUp 插件「工装资产」

**安装**：把插件打包成 `.rbz`，在 SketchUp 的「扩展程序管理器 → 安装扩展程序」里选它。

```bash
cd sketchup/gz_asset_plugin
zip -r ../gz_asset.rbz gz_asset.rb gz_asset
```

Windows 上可以用压缩软件把 `gz_asset.rb` 和 `gz_asset` 文件夹一起压成 zip，再把扩展名改成 `.rbz`。

装好后在菜单「扩展程序 → 工装资产」里：

| 菜单 | 作用 |
|---|---|
| 锁定当前效果… | 把当前模型的材质、Enscape 视觉设置、灯光状态存成一个快照（连同贴图） |
| 与快照比对… | 列出当前模型和某个快照相比，哪些材质、灯光、设置被改了，改成了什么 |
| 回滚到快照… | 把被改过的项改回快照里的值；快照之后新增的东西不会删除；可以一步撤销 |
| 选中组件入库… | 把选中的组件存进资产库，带缩略图 |
| 资产库 / 投放… | 搜索资产库（含扫描器建的索引），把组件放进当前模型 |
| 设置索引目录… | 选扫描器生成的那个索引目录，插件的快照和资产库也存在这里 |

索引目录结构：

```
assets.json        扫描器写
library.json       插件写（入库记录）
library/           入库的组件 .skp + 缩略图
snapshots/<模型>/<时间>/   锁定快照
```

## 批量脚本

在 SketchUp 的 Ruby 控制台里加载：

```ruby
load '/你的路径/sketchup/scripts/skp_batch.rb'
SkpBatch.run('D:/项目/模型', 3)    # 先试 3 个；去掉 3 = 全量
SkpBatch.stop                      # 中途停止，再次 run 会跳过已完成的

load '/你的路径/sketchup/scripts/render_assets.rb'
AssetRender.run(20)                # 当前模型前 20 个顶层组件出图
```

输出在桌面的 `skp_batch/`、`asset_render/` 目录。

## 成熟度和测试情况

这套工具来自一个室内设计公司的资产治理概念验证（PoC），**插件是 0.1.0 版本**，脚本按当时现场的 SketchUp 版本写，请先在模型副本上试用。

| 工具 | 测试情况 |
|---|---|
| `skp_audit.py` | ✅ 在 3 个真实模型上运行（1.6GB 含 Enscape 数据、690MB 无 Enscape 数据、空白模型），确认原文件未被修改 |
| `gz_scan.py` | ✅ 批量扫描上述 3 个模型，增量重扫正常 |
| 插件、Ruby 脚本 | ⚠️ 仅做了 Ruby 语法检查，**发布前没有在 SketchUp 里实测**；在其他 SketchUp 版本上能否运行未验证 |

## 作者

Bowen · 20 年产品人，亲手用 AI 解决 100 个真实问题 · AI 实战 100 例

抖音：[Bowen的AI实战笔记](https://www.douyin.com/user/MS4wLjABAAAAsVy4x0FpjE8j4epQQZtZkg2OOU2Vb3G5UweYp5ZZwd0)（抖音号 1083328779）

其他开源项目：
- [meeting-minutes](https://github.com/ttgg20200101-claw/meeting-minutes)：跟 AI 说「开会」就录音，说「结束」就出会议纪要并核实事实说法
- [workbuddy-bridge](https://github.com/ttgg20200101-claw/workbuddy-bridge)：让 AI 当监工、WorkBuddy 当员工
- [vibe-fx](https://github.com/ttgg20200101-claw/vibe-fx)：让 AI 写代码做动效视频的 Canvas 特效库

## License

MIT
