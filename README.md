# 论文译读 · PaperReader

PaperReader 是一个面向 Apple 芯片 Mac 的原生 PDF 论文阅读器。拖入带可选文字的英文 PDF 后，可以立即阅读原文，并在后台翻译全文。完成后，左侧显示英文，右侧显示简体中文，可以同步滚动、缩放和导出左右对照 PDF。

App 用 SwiftUI 和 PDFKit 显示 PDF，使用 PDFMathTranslate-next 和 BabelDOC 翻译及排版。默认调用 DeepSeek Flash，关闭思考模式并保留自动术语提取。图注参与翻译，识别为图内标签的文字尽量保留。当前版本面向有文字层的 PDF。

## 构建

需要运行 macOS 15 或更高版本的 Apple 芯片 Mac、Xcode Command Line Tools 和 [uv](https://docs.astral.sh/uv/getting-started/installation/)。从项目目录运行：

```sh
bash bootstrap.sh
bash build.sh
open dist/PaperReader.app
```

构建将 Python 和翻译依赖放入本机 App。之后可在 Finder 中双击 `dist/PaperReader.app`。首次翻译时，BabelDOC 可能需要联网下载版面模型和字体。

## 配置 DeepSeek

App 复用本机 PDFMathTranslate-next 的 DeepSeek 设置。也可以在 `~/.config/pdf2zh/config.v3.toml` 的 `[deepseek_detail]` 段填入自己的 `deepseek_api_key`。从终端直接运行 App 可使用进程环境变量 `DEEPSEEK_API_KEY`。模型调用需要联网，DeepSeek 根据用量计费。

## 验证

`Tests/ReaderSyncCheck.swift` 用真实的 AppKit/PDFKit 窗口检查导入、双向滚动与缩放同步和导出。它接受本地测试 PDF 路径，也支持显式启动一次真实翻译。`Tests/verify_rsihub_export.py` 对 RSIHub 及其双语输出检查页数、左右版面、图像、图注和图内标签。测试 PDF 由运行者提供。

## 许可证与上游

本仓库采用 [GNU AGPL-3.0](LICENSE)。本地翻译运行时使用 [PDFMathTranslate-next 2.10.2](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next/tree/v2.10.2) 和 [BabelDOC 0.7.1](https://github.com/funstory-ai/BabelDOC/tree/v0.7.1)，两者均采用 AGPL-3.0。构建步骤包含让官方模型名 `deepseek-flash` 正确传递思考模式参数的兼容修改。
