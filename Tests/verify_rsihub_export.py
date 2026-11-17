#!/usr/bin/env python3
"""Verify the two halves of the exported RSIHub bilingual PDF."""

import argparse
import json
import re
import unicodedata
from collections import Counter
from pathlib import Path

import pymupdf


def normalized(text: str) -> str:
    return unicodedata.normalize("NFKC", text)


def image_positions(page, horizontal_offset: float, width: float) -> Counter:
    positions = Counter()
    for image in page.get_image_info(hashes=True):
        bounds = pymupdf.Rect(image["bbox"])
        if horizontal_offset - 0.1 <= bounds.x0 < horizontal_offset + width:
            coordinates = (
                bounds.x0 - horizontal_offset,
                bounds.y0,
                bounds.x1 - horizontal_offset,
                bounds.y1,
            )
            positions[(image["digest"].hex(), *(round(v, 1) for v in coordinates))] += 1
    return positions


def validate(source_path: Path, export_path: Path, allow_translated_labels: bool) -> dict:
    issues: list[str] = []
    all_images = 0
    translated_text_pages = 0
    left_pixel_exact_pages = 0
    table_caption_pages: list[int] = []
    draw_counts: dict[int, tuple[int, int]] = {}
    labels = ("Evolution Driver", "Evolution Loop", "Protected Runtime")
    found_labels: list[str] = []

    with pymupdf.open(source_path) as source, pymupdf.open(export_path) as export:
        if len(source) != len(export):
            issues.append(f"Expected {len(source)} pages, got {len(export)}")
        for index, (original, bilingual) in enumerate(zip(source, export), start=1):
            width, height = original.rect.width, original.rect.height
            left = pymupdf.Rect(0, 0, width, height)
            right = pymupdf.Rect(width, 0, width * 2, height)
            if abs(bilingual.rect.width - width * 2) > 0.1 or abs(bilingual.rect.height - height) > 0.1:
                issues.append(f"Page {index}: unexpected bilingual page geometry")
                continue

            src_pix = original.get_pixmap(matrix=pymupdf.Matrix(0.5, 0.5))
            left_pix = bilingual.get_pixmap(matrix=pymupdf.Matrix(0.5, 0.5), clip=left)
            if src_pix.samples != left_pix.samples:
                issues.append(f"Page {index}: original half differs from source rendering")
            else:
                left_pixel_exact_pages += 1

            original_images = image_positions(original, 0, width)
            translated_images = image_positions(bilingual, width, width)
            missing_images = sum((original_images - translated_images).values())
            if missing_images:
                issues.append(f"Page {index}: {missing_images} source images differ or moved")
            all_images += sum(original_images.values())

            source_text = normalized(original.get_text())
            translated_text = normalized(bilingual.get_text(clip=right))
            if re.search(r"[\u3400-\u9fff]", translated_text):
                translated_text_pages += 1
            elif re.search(r"\b[A-Za-z]{4,}\b", source_text):
                issues.append(f"Page {index}: no Chinese in the translated half")

            if index == 1:
                for marker in ("τ", "pass@1", "13.5"):
                    if marker not in translated_text:
                        issues.append(f"Page 1: missing abstract marker {marker}")

            if index == 2:
                figure_text = normalized(bilingual.get_text(clip=pymupdf.Rect(width, 65, width * 2, 315)))
                found_labels = [label for label in labels if label in figure_text]
                if not allow_translated_labels and len(found_labels) != len(labels):
                    issues.append("Page 2: in-figure labels do not all remain English")
                for n, page, offset in ((0, original, 0), (1, bilingual, width)):
                    paths = sum(
                        offset <= d["rect"].x0 and d["rect"].x1 <= offset + width
                        and d["rect"].y0 >= 65 and d["rect"].y1 <= 315
                        for d in page.get_drawings()
                    )
                    draw_counts[n] = paths
                if draw_counts[1] < draw_counts[0]:
                    issues.append("Page 2: vector graphic paths are missing")
                caption_text = normalized(bilingual.get_text(clip=pymupdf.Rect(width, 315, width * 2, 393)))
                if not re.search(r"图\s*1\s*RSIHub", caption_text):
                    issues.append("Page 2: Chinese Figure 1 caption was not found")

            source_captions = re.findall(r"(?m)^\s*Table\s+(\d+)\s+[A-Z]", source_text)
            if source_captions and re.search(r"(?m)^\s*(?:表|表格)\s*\d+", translated_text):
                table_caption_pages.append(index)

        return {
            "source_pages": len(source),
            "export_pages": len(export),
            "pixel_exact_source_halves": left_pixel_exact_pages,
            "pages_with_translated_text": translated_text_pages,
            "source_images_checked": all_images,
            "figure_1_vector_paths_source_and_translation": [draw_counts.get(0), draw_counts.get(1)],
            "figure_1_english_labels_preserved": found_labels,
            "pages_with_chinese_table_captions": table_caption_pages,
            "issues": issues,
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("export", type=Path)
    parser.add_argument("--allow-translated-figure-labels", action="store_true")
    args = parser.parse_args()
    result = validate(args.source, args.export, args.allow_translated_figure_labels)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(bool(result["issues"]))
