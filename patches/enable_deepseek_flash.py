"""Apply PaperReader's DeepSeek Flash compatibility fix to a staged build."""

from pathlib import Path
import sys


ORIGINAL = (
    '        if self.deepseek_model and self.deepseek_model.startswith("deepseek-v4-"):\n'
)
PATCHED = (
    '        if self.deepseek_model == "deepseek-flash" or (\n'
    '            self.deepseek_model and self.deepseek_model.startswith("deepseek-v4-")\n'
    "        ):\n"
)


def main():
    translator_path = (
        Path(sys.argv[1]) / "pdf2zh_next/config/translate_engine_model.py"
    )
    source = translator_path.read_text(encoding="utf-8")
    if source.count(PATCHED) == 1:
        return
    if source.count(ORIGINAL) != 1:
        raise SystemExit("PDFMathTranslate-next does not match the expected patch context.")
    translator_path.write_text(source.replace(ORIGINAL, PATCHED, 1), encoding="utf-8")


if __name__ == "__main__":
    main()
