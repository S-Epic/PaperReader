"""JSON-lines interface from the macOS reader to the local PDF translation engine."""

import asyncio
import json
import math
import os
import signal
import sys
import tomllib
from contextlib import aclosing
from pathlib import Path

STAGES = {
    "Parse PDF and Create Intermediate Representation": "读取原文",
    "DetectScannedFile": "检查页面文字",
    "Parse Page Layout": "分析原始版面",
    "Parse Paragraphs": "识别段落",
    "Parse Formulas and Styles": "识别公式和样式",
    "Automatic Term Extraction": "提取术语",
    "Translate Paragraphs": "翻译正文和图注",
    "Typesetting": "排版中文译文",
    "Add Fonts": "嵌入字体",
    "Generate drawing instructions": "生成页面内容",
    "Subset font": "处理字体",
    "Save PDF": "保存译文与双语 PDF",
}


class BridgeError(Exception):
    """An error with a message safe to show in the reader."""


def exclude_rectangle(rectangle, excluded):
    x0, y0, x1, y1 = rectangle
    sx0, sy0, sx1, sy1 = excluded
    ix0, iy0 = max(x0, sx0), max(y0, sy0)
    ix1, iy1 = min(x1, sx1), min(y1, sy1)
    if ix0 >= ix1 or iy0 >= iy1:
        return [rectangle]
    return [
        part
        for part in (
            (x0, y0, x1, iy0),
            (x0, iy1, x1, y1),
            (x0, iy0, ix0, iy1),
            (ix1, iy0, x1, iy1),
        )
        if part[0] < part[2] and part[1] < part[3]
    ]


def install_figure_protection():
    from babeldoc.format.pdf import high_level

    class FigurePreservingLayout(high_level.LayoutService):
        def next_page(self):
            page = super().next_page()
            if page is None:
                return None
            index, size, boxes = page
            captions = [
                tuple(value for _, value in coordinates)
                for coordinates, _, label in boxes
                if label
                in {"figure_caption", "table_caption", "caption", "formula_caption"}
            ]
            preserved = []
            for coordinates, confidence, label in boxes:
                if label != "figure" or confidence < 0.5:
                    continue
                parts = [tuple(value for _, value in coordinates)]
                for caption in captions:
                    parts = [
                        remaining
                        for part in parts
                        for remaining in exclude_rectangle(part, caption)
                    ]

                # BabelDOC 0.7.1 otherwise generates fallback text lines over figures.
                # Its isolated-formula layout class takes priority over fallback lines
                # and keeps original glyphs in the PDF without translating them.
                # Retain the original figure classification for vector graphics.
                preserved.extend(
                    (
                        tuple((64, value) for value in part),
                        confidence,
                        "isolate_formula",
                    )
                    for part in parts
                )
            return index, size, boxes + preserved

    high_level.LayoutService = FigurePreservingLayout


def read_deepseek_key():
    for variable in ("PDF2ZH_DEEPSEEK_API_KEY", "DEEPSEEK_API_KEY"):
        key = os.environ.get(variable, "").strip()
        if key and key != "null":
            return key

    from pdf2zh_next.const import DEFAULT_CONFIG_FILE

    try:
        with DEFAULT_CONFIG_FILE.open("rb") as config_file:
            key = (
                tomllib.load(config_file)
                .get("deepseek_detail", {})
                .get("deepseek_api_key")
            )
    except FileNotFoundError:
        key = None
    except (OSError, ValueError, AttributeError) as exc:
        raise BridgeError("无法读取 PDFMathTranslate-next 的本机配置。") from exc
    if not isinstance(key, str) or key.strip() in {"", "null"}:
        raise BridgeError(
            "未找到 DeepSeek API 密钥，请先在本机 PDFMathTranslate-next 中配置。"
        )
    return key.strip()


def source_page_count(source):
    import pymupdf

    if source.suffix.lower() != ".pdf" or not source.is_file():
        raise BridgeError("请选择一个可读取的 PDF 文件。")
    try:
        with pymupdf.open(source) as document:
            if not document.is_pdf or document.page_count < 1:
                raise BridgeError("此文件不是有效的 PDF。")
            if document.needs_pass:
                raise BridgeError("此 PDF 需要密码。请先解除密码保护再导入。")
            if not any(page.get_text().strip() for page in document):
                raise BridgeError("这份 PDF 没有可选文字。首版暂不支持扫描件。")
            return document.page_count
    except (pymupdf.FileDataError, OSError) as exc:
        raise BridgeError("无法读取此 PDF，文件可能已经损坏。") from exc


def safe_error_message(event):
    # Engine exceptions may include headers, document text or provider payloads.
    # Only use known signals to choose a fixed user-facing message.
    value = " ".join(
        str(event.get(key, "")) for key in ("error", "error_type", "details")
    ).lower()
    if "401" in value or "authenticationerror" in value or "invalid api key" in value:
        return "DeepSeek 拒绝了 API 密钥，请检查本机配置。"
    if "402" in value or "insufficient balance" in value:
        return "DeepSeek 账户余额不足。"
    if "429" in value or "ratelimiterror" in value:
        return "DeepSeek 请求过于频繁，请稍后重试。"
    if "timeout" in value or "apiconnectionerror" in value or "connecterror" in value:
        return "连接 DeepSeek 失败，请检查网络后重试。"
    if "detected scanned" in value or "scanned pdf" in value:
        return "引擎识别到扫描页面。请选择带可选文字的论文 PDF。"
    return "翻译未能完成。请检查网络和 DeepSeek 配置后重试。"


async def translate(source, output, emit):
    from pdf2zh_next.config.model import PDFSettings, SettingsModel, TranslationSettings
    from pdf2zh_next.config.translate_engine_model import DeepSeekSettings
    from pdf2zh_next.high_level import do_translate_async_stream

    emit(type="progress", progress=0, stage="准备翻译")
    page_count = source_page_count(source)
    deepseek = DeepSeekSettings(
        deepseek_model="deepseek-flash",
        deepseek_thinking_mode="disabled",
        deepseek_api_key=read_deepseek_key(),
    )
    output.mkdir(parents=True, exist_ok=True)
    settings = SettingsModel(
        report_interval=0.25,
        translate_engine_settings=deepseek,
        translation=TranslationSettings(
            lang_in="en",
            lang_out="zh-CN",
            output=str(output),
            no_auto_extract_glossary=False,
        ),
        pdf=PDFSettings(
            watermark_output_mode="no_watermark",
            translate_table_text=False,
            ocr_workaround=False,
            auto_enable_ocr_workaround=False,
        ),
    )

    loop = asyncio.get_running_loop()
    task = asyncio.current_task()
    loop.add_signal_handler(signal.SIGTERM, task.cancel)
    try:
        async with aclosing(do_translate_async_stream(settings, source)) as events:
            async for event in events:
                event_type = event["type"]
                if event_type.startswith("progress_"):
                    progress = float(event.get("overall_progress") or 0) / 100
                    if math.isfinite(progress):
                        emit(
                            type="progress",
                            progress=min(max(progress, 0), 1),
                            stage=STAGES.get(event.get("stage"), "翻译处理中"),
                        )
                elif event_type == "finish":
                    result = event["translate_result"]
                    return validate_outputs(result, output, page_count)
                elif event_type == "error":
                    raise BridgeError(safe_error_message(event))
    finally:
        loop.remove_signal_handler(signal.SIGTERM)
    raise BridgeError("翻译引擎未返回完整的 PDF。")


def validate_outputs(result, output, page_count):
    import pymupdf

    paths = {}
    for name, value in (
        ("mono_path", result.mono_pdf_path),
        ("dual_path", result.dual_pdf_path),
    ):
        if value is None:
            raise BridgeError("翻译引擎未返回完整的 PDF。")
        path = Path(value).resolve()
        if not path.is_relative_to(output) or not path.is_file():
            raise BridgeError("找不到翻译引擎生成的 PDF。")
        with pymupdf.open(path) as document:
            if document.page_count != page_count:
                raise BridgeError("译文页数与原文不一致。")
        paths[name] = str(path)
    return paths


def main():
    # Native subprocesses write to the underlying descriptors directly. Keep a
    # separate descriptor for JSON and prevent engine output from reaching it.
    with os.fdopen(
        os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1
    ) as channel:
        sys.stdout.flush()
        sys.stderr.flush()
        with open(os.devnull, "wb") as quiet:
            os.dup2(quiet.fileno(), sys.stdout.fileno())
            os.dup2(quiet.fileno(), sys.stderr.fileno())

        def emit(**message):
            print(
                json.dumps(message, ensure_ascii=False, allow_nan=False), file=channel
            )

        try:
            if len(sys.argv) != 3:
                raise BridgeError("翻译任务缺少原文路径或输出目录。")
            source, output = (Path(argument).resolve() for argument in sys.argv[1:])
            install_figure_protection()
            result = asyncio.run(translate(source, output, emit))
            emit(type="result", **result)
            return 0
        except BridgeError as exc:
            emit(type="error", message=str(exc))
        except (asyncio.CancelledError, KeyboardInterrupt):
            emit(type="error", message="翻译已取消。")
            return 130
        except Exception as exc:  # noqa: BLE001 - Never print raw engine errors.
            emit(
                type="error",
                message=safe_error_message(
                    {"error": exc, "error_type": type(exc).__name__}
                ),
            )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
elif __name__ == "__mp_main__":
    # macOS runs the translation worker in a fresh spawned interpreter.
    install_figure_protection()
