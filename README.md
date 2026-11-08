# DisplayToggle

[![CI](https://github.com/huangzx8090/DisplayToggle/actions/workflows/ci.yml/badge.svg)](https://github.com/huangzx8090/DisplayToggle/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/huangzx8090/DisplayToggle)](https://github.com/huangzx8090/DisplayToggle/releases/latest)

macOS 菜单栏小工具：**接外屏时按需关掉 MacBook 内屏，拔线时保证你还有一块亮着的屏。**

不止是"一键关内屏"——它把这件事变成了有状态、有兜底的行为，用起来不需要惦记。

---

## 你可能也遇到过这些问题

**1. 拔掉外接线，内屏是黑的，机器等于砖头**

用命令行工具（比如 `displaytoggle off`）关掉内屏后，如果忘了先开回来就拔线，内屏不会自己亮。macOS 不会帮你恢复，因为它不知道你想恢复。

**2. 想"只用外屏"，每次都要手动关内屏、再手动开回来**

插上线 → 关内屏 → 拔线 → 摸黑开内屏。一天来回几次就烦了。

**3. 内屏关了，键盘背光还亮着**

内屏根本不亮，键盘灯却按环境光在亮，白耗电，看着也怪。

**4. 合盖用外屏时，内屏被意外点亮**

笔记本合着盖，内屏却在耗电发热；或者反过来，只掀开一点点盖子，内屏就亮起来刺眼。系统不给你这个粒度的控制。

**5. 装了虚拟屏 / 分辨率工具之后，"有没有外接屏"这个判断彻底失真**

这是最坑的一类：某些工具会在显示器拔掉后留一块**虚拟屏**顶替。所有靠"数一数有几个显示器"来判断的工具（包括这个项目的前几版）都会被骗——以为外接屏还在，于是永远不会帮你恢复内屏。

**6. 息屏、锁屏、睡眠唤醒后状态乱掉**

外接屏进入睡眠被误判成"拔线"，于是内屏被点亮；或者唤醒后系统把内屏重置成亮的，策略失效。

---

## 这个工具怎么处理

| 场景 | 行为 |
|---|---|
| 接上外接屏 | 按你选定的策略处理内屏（见下节），不是无脑关 |
| **拔掉全部外接屏** | **1.5 秒内点亮内屏**，不看当前策略、不看角度，安全网优先 |
| 外接屏还在但**没有画面**（虚拟屏/镜像坏掉/只连了个空壳） | 可选的第二道安全网，勾上后同样会点亮内屏 |
| 外接屏进入息屏睡眠 | 不当作拔线，内屏不动，避免你离开电脑时被点亮 |
| 盖子是合着的 | **默认绝不点亮内屏**，交回系统原生 clamshell 行为 |
| 唤醒后系统重置了显示状态 | 按策略重新生效 |
| 退出 / ⌘Q / 注销 / `SIGTERM` | 先把内屏恢复再走 |
| 内屏被外部手段关掉（CLI、别的工具） | App 接管这个状态，拔线时照样会救回来 |

判定的关键点：**只把"真正在出画的物理屏"算作外接屏**。离线幽灵、`1x1` 占位屏、虚拟屏、镜像从屏都被排除，所以第 5 条那种坑不会再踩。

---

## 三档「接外屏时」策略

菜单里三选一，互斥：

| 策略 | 行为 | 适合谁 |
|---|---|---|
| **按开盖角度切换**（默认） | 读盖子真实角度：≥ 阈值（默认 100°）认为你在用内屏 → 点亮；≤ 阈值−5° → 关内屏 | 平常合盖挂外屏办公，掀开盖子就用内屏的人 |
| **接外屏后关闭内屏** | 外接屏稳定 1 秒后就关内屏，拔线靠安全网恢复 | 想"插上就只用一个屏"的人 |
| **不自动切换** | 完全不动手，内屏开关全交给你（⌘D / ⌘O） | 讨厌工具自作主张的人 |

角度策略带 **5° 回差 + 0.8 秒稳定判定**，手扶盖子或临界角度不会反复闪。
阈值菜单 30°–135° 可调（5° 步长），想"掀开就亮"调低，想"掀再大也别亮"调高。

手动 ⌘D / ⌘O 之后有 **5 分钟手动优先期**，期间自动策略不会立刻把你刚做的选择推翻。

---

## 安全网：不会把自己关在黑屏里

这是这个项目和普通"一键关内屏"最大的区别：

- **看门狗**：每 0.4 秒检查状态；"内屏是黑的 + 没有正在出画的物理外接屏 + 系统没在息屏"持续 1.5 秒后首次尝试点亮。仅内屏时同样尊重系统息屏，避免反复唤醒。配置进行中不重复提交，成功后等待 2 秒让状态稳定；失败按 2、4、8、16、30 秒退避重试（最长 30 秒），拔线后需要反向点亮时立即允许尝试，手动操作也可立即重试。
- **合盖保护写在最底层**：拦截点在真正执行"点亮内屏"的那一层，不管从菜单、快捷键还是命令行进来都拦得住。合盖检测读不到状态时按"开盖"处理——黑屏比多亮一块屏严重得多。
- **内屏 ID 三级兜底**：内屏被关掉后会从在线列表里消失，所以用能列出"已关闭显示器"的私有接口查，再退到缓存和常见值，每个候选都真的试一遍并校验结果。
- **退出即还原**：正常退出、注销、`SIGTERM` 都会先恢复内屏。

---

## 键盘背光 & 原彩显示

- **键盘背光跟随内屏有没有画面**：内屏不出画时把背光按住不亮（含抑制系统的闲置变暗和自动调节顶回来），内屏重新出画立刻交还系统控制。合盖时不接管（此时键盘本身不可用）。亮度原值会被记录，异常退出后下次启动补恢复。
- **原彩显示（True Tone）自动切换**：内屏在出画时开启，只用外屏时关闭，减少你在两个屏幕间来回看时的色温落差。

## 外接屏设置

菜单里可以直接改外接屏的**分辨率 / 刷新率 / 旋转**，以及通过 **DDC/CI** 调显示器自己的**亮度、对比度**等硬件控制。改动带预览期，超时未确认会自动还原，不会把显示器调成再也调不回来的状态。

---

## 安装

到 [Releases](https://github.com/huangzx8090/DisplayToggle/releases/latest) 下载
`DisplayToggle-vX.Y.Z-macos-universal.zip`（Apple Silicon 与 Intel 通用），解压后把
`DisplayToggle.app` 放进 `~/Applications` 或 `/Applications`。

首次打开若被 Gatekeeper 拦下（未签名，ad-hoc），执行一次：

```bash
xattr -cr /Applications/DisplayToggle.app
```

或者右键 → 打开。

菜单栏图标：笔记本（不带斜杠）= 内屏在出画；带斜杠 = 内屏已关。

建议在菜单里打开 **开机自动启动**，否则重启后没有守护进程，拔线就没有安全网了。

## 更新

- 菜单里有 **检查更新…（v当前版本）**，会拉取 GitHub 最新 Release；
- 启动后如果距上次检查超过 24 小时，会静默检查一次，有新版本才弹窗；
- 弹窗里会列出**这个版本改了什么**（Release 说明），确认后自动下载、校验包标识，
  然后由一个独立脚本完成替换：**旧版本先备份，新版本启动失败会自动回滚**，不会把自己更新成砖头；
- 更新源可以在 `Updater.swift` 的 `repository` 里改成自己的 fork。

从源码构建（需要 Xcode Command Line Tools）：

```bash
git clone https://github.com/huangzx8090/DisplayToggle.git
cd DisplayToggle
./build.sh
cp -R build/DisplayToggle.app ~/Applications/
xattr -cr ~/Applications/DisplayToggle.app
open ~/Applications/DisplayToggle.app
```

构建脚本支持自定义包标识与版本号：

```bash
DISPLAYTOGGLE_BUNDLE_ID=com.example.mine DISPLAYTOGGLE_VERSION=2.0.0 ./build.sh
```

命令行入口（可选）：

```bash
cat > ~/.local/bin/displaytoggle <<'EOF'
#!/bin/bash
exec "$HOME/Applications/DisplayToggle.app/Contents/MacOS/DisplayToggle" "$@"
EOF
chmod +x ~/.local/bin/displaytoggle
```

```bash
displaytoggle status      # 内屏开关 / 外接屏数量 / 盖子状态
displaytoggle on|off|toggle
displaytoggle lid         # 只读合盖状态
displaytoggle lid-angle   # 盖子角度
displaytoggle true-tone   # 原彩状态
displaytoggle diagnose    # 拓扑与判定详情
displaytoggle hidpi-list  # 可用显示模式
displaytoggle ddc-status  # 显示器硬件控制支持情况
```

---

## 已知限制与风险

- **依赖多个 macOS 私有接口**：`SkyLight`（`SLSConfigureDisplayEnabled` / `SLSGetDisplayList`）、`CoreBrightness`（键盘背光）、`I2C`（DDC/CI）。系统大版本升级后可能失效，行为以实测为准。
- **不是 App Store 分发**，使用 ad-hoc 签名，首次运行需要 `xattr -cr` 或右键打开。
- **合盖保护默认开启**：合盖状态下内屏不会亮，除非在菜单里显式打开「合盖时保持内屏点亮」。
- **显示器 ID 不稳定**：重新插拔、换线、分辨率变化都会让 ID 变化，代码里所有缓存都只作为兜底，不做唯一依据。
- 角度传感器依赖 Apple 的 HID Feature Report，非 Apple 设备或传感器不可用时角度策略会暂停，不会偷偷降级成别的策略。

## 开发与测试

```bash
tests/run.sh          # 纯逻辑单测（策略、协议解析、模式目录等），不需要 GUI
```

调试开关（都会写日志到 `~/Library/Logs/DisplayToggle.log`）：

```bash
DT_DEBUG=1 <app>/Contents/MacOS/DisplayToggle     # 日志同时输出到 stderr
DT_DEV=1  <app>/Contents/MacOS/DisplayToggle      # 打开下面这些伪造钩子
```

只有在 `DT_DEV=1` 时才生效的自测钩子：

```bash
touch /tmp/dt_no_external                 # 假装外接屏消失了（验证拔线自动恢复）
DT_FAKE_LID=closed|open|unknown ...       # 假装合盖状态
DT_FAKE_LID_FILE=/tmp/dt_lid ...          # 从文件读合盖状态，可动态改
DT_FAKE_ANGLE=120 ...                     # 假装盖子角度
```

## 目录结构

```
main.swift              菜单栏 App、状态机、CLI、旧版本迁移
Updater.swift           GitHub Release 检查 / 下载 / 原子替换
Version.swift           版本号比较
DisplayPolicy.swift     三档外屏策略定义
AnglePolicy.swift       角度判定（回差 + 稳定）
LidAngle.swift          盖子角度传感器
KeyboardBacklight.swift CoreBrightness 桥接与背光保持
HiDPI.swift             显示模式读取 / 切换
DDCService.swift        DDC/CI 硬件控制
DDCProtocol.swift       DDC 报文编解码
TrueToneService.swift   原彩切换
build.sh                构建 .app（swiftc + iconset + Info.plist）
tests/                  纯逻辑单测
.github/workflows/      CI 与 tag 触发的自动发布
```

## 许可与致谢

MIT，见 [LICENSE](LICENSE)。

角度读取参考 [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor)；
键盘背光桥接与抑制状态处理参考 [Dim Keys](https://github.com/dmartoon/MacBook-Keyboard-Backlight-Limiter) 与
[LidSleepToggle](https://github.com/Sufxx/LidSleepToggle)；
DDC/CI 协议实现参考 [AppleSiliconDDC](https://github.com/waydabber/BetterDisplay) 与
[Hammerspoon](https://github.com/Hammerspoon/hammerspoon)。
各自的 MIT 许可原文保存在 `THIRD_PARTY_LICENSES/`。
