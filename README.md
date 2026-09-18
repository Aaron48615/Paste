<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="RePaste">
</p>

<h1 align="center">RePaste</h1>

<p align="center">
  面向键盘工作流的原生 macOS 剪贴板历史工具<br>
  文本、代码、链接与图片捕获，全文和拼音搜索，以及快速粘贴
</p>

<p align="center">
  <a href="#使用方式">使用方式</a> ·
  <a href="#从源码构建">从源码构建</a>
</p>

<p align="center">
  <a href="README.md">简体中文</a>
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/storage-SQLite-2f74c0" alt="SQLite">
</p>

---

<p align="center">
  <img alt="RePaste 剪贴板历史窗口" src=".github/assets/app.png" width="860">
</p>

## 简介

RePaste 是一款原生 macOS 剪贴板历史工具，用一个随时呼出的轻量命令面板保存和检索你复制过的内容。它识别文本、代码、链接与图片，记录来源应用，并把搜索、选择和粘贴组织成一套无需离开键盘的工作流。

历史记录保存在本机 SQLite 数据库中，图片作为本地文件管理。搜索通过 SQLite FTS5 与拼音索引覆盖完整历史，即使中文内容只记得拼音全拼或首字母，也可以直接找到。

## 为什么开发 RePaste

系统剪贴板只保留最后一次复制，常见剪贴板工具又容易把大量功能和视觉层级塞进一个常驻窗口。RePaste 更接近一个专用命令面板：需要时出现，完成搜索与粘贴后立即回到原来的应用。

- **多类型捕获**：自动区分普通文本、代码、链接和图片
- **完整历史搜索**：SQLite FTS5 全文索引，不受内存窗口限制
- **中文拼音检索**：支持全拼与首字母，并高亮原文中的命中字符
- **键盘优先**：方向键选择、回车粘贴、快捷键固定、预览和打开操作菜单
- **图片预览**：缩略图按需解码，按空格打开适配屏幕空间的 Quick Look
- **来源感知**：展示复制来源应用，并将内容粘贴回呼出面板前的目标应用

## 使用方式

默认按 `Option + W` 呼出或隐藏面板。输入关键词搜索历史记录，使用方向键移动选择，然后按回车粘贴。

- `Return`：粘贴并关闭面板
- `Command + Return`：复制所选内容
- `Command + P`：固定或取消固定记录
- `Space`：预览图片
- 操作菜单：保持窗口打开并粘贴、在 Finder 中显示图片、删除记录等

呼出快捷键可以在设置中重新录制。也可以选择在面板打开时自动切换到英文输入法，直接进行拼音搜索。

## 本地存储与隐私

RePaste 的剪贴板数据库和图片均保存在本机，不依赖云端服务。历史保留时间可以设置为一天、一周、一个月、三个月、半年、一年或永久；固定记录不受自动清理影响。

可以配置禁止捕获的应用。默认排除“钥匙串访问”和“密码”应用，避免敏感内容进入历史记录。RePaste 需要辅助功能权限，才能把选中的内容可靠地发送回原目标应用。

## 其他功能

- 按固定、今天、昨天、过去七天、过去三十天与更早时间分组
- 代码语法高亮与链接识别
- 图片内存缓存与后台降采样，控制长历史列表的内存占用
- 登录时启动
- 跟随系统、浅色与深色外观
- 简体中文与英文界面

## 从源码构建

需要 macOS 26、Xcode 26 与 Swift 6。

```bash
git clone https://github.com/Aaron48615/Paste.git
cd Paste
open Paste.xcodeproj
```

在 Xcode 中选择 **Paste** scheme，然后执行 **Product → Run**。首次粘贴前，请按系统提示授予辅助功能权限。

## RePaste 独立版本

RePaste 是 Aaron 基于 [imeelinew/Paste](https://github.com/imeelinew/Paste) 开发的独立分支，保留原项目来源和 AGPL-3.0 许可证。

- 应用产物为 `RePaste.app`，Bundle ID 为 `com.aaron.RePaste`，命令行工具为 `repaste-cli`。
- 历史与图片保存在 `~/Library/Application Support/com.aaron.RePaste`，设置及辅助功能授权与原版分开。
- 原版数据不会自动迁移。如需复制，在首次运行 RePaste 前执行 `python3 scripts/import-paste-data.py`；已有 RePaste 数据时脚本拒绝覆盖。
- 自动更新暂未配置，不会下载原作者的 Paste 更新。发布配置见 [RELEASING.md](RELEASING.md)。
- Xcode 工程和 Scheme 继续叫 `Paste`，源码目录保持原结构，便于同步上游；构建产物和系统显示名称均为 RePaste。
- 默认临时签名仍可能在重新构建后要求重新授权；稳定授权需要配置你自己的固定签名身份。
- 两版同时运行时需在设置中使用不同的全局快捷键。

### 向上游贡献

保留 `upstream` 指向原项目。通用功能或修复应从 `upstream/main` 新建分支，只挑选功能提交，再从你的 fork 向原项目发起 PR；不要把 RePaste 的品牌、签名、更新渠道和数据迁移改动一起提交。
