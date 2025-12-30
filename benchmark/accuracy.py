#!/usr/bin/env python3
"""
ZPDF Correctness Benchmark

Measures text extraction accuracy against MuPDF as reference.

Metrics:
- Character Accuracy: Sequence similarity (difflib.SequenceMatcher)
- Word Error Rate (WER): 1 - word sequence similarity

Usage:
    python benchmark/accuracy.py [pdf_files...]

If no files specified, tests all PDFs in project directory.
"""

import subprocess
import sys
import time
import difflib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "python"))
import zpdf


def normalize(text: str) -> str:
    """Normalize whitespace for comparison."""
    import re
    return re.sub(r'\s+', ' ', text).strip()


def char_accuracy(hyp: str, ref: str, sample_size: int = 15000) -> float:
    """Character-level sequence accuracy."""
    if not ref:
        return 1.0 if not hyp else 0.0
    matcher = difflib.SequenceMatcher(None, hyp[:sample_size], ref[:sample_size])
    return matcher.ratio()


def word_error_rate(hyp: str, ref: str, max_words: int = 2000) -> float:
    """Word Error Rate = 1 - word sequence accuracy."""
    hyp_words = hyp.split()[:max_words]
    ref_words = ref.split()[:max_words]
    if not ref_words:
        return 0.0 if not hyp_words else 1.0
    matcher = difflib.SequenceMatcher(None, hyp_words, ref_words)
    return 1.0 - matcher.ratio()


def extract_mutool(pdf_path: str) -> tuple:
    """Extract text using MuPDF (mutool)."""
    start = time.perf_counter()
    result = subprocess.run(
        ["mutool", "convert", "-F", "text", "-o", "-", pdf_path],
        capture_output=True, text=True
    )
    elapsed = (time.perf_counter() - start) * 1000
    return result.stdout, elapsed


def extract_zpdf(pdf_path: str) -> tuple:
    """Extract text using zpdf."""
    start = time.perf_counter()
    doc = zpdf.Document(pdf_path)
    text = doc.extract_all(parallel=True)
    pages = doc.page_count
    doc.close()
    elapsed = (time.perf_counter() - start) * 1000
    return text, elapsed, pages


def benchmark_pdf(pdf_path: str) -> dict:
    """Benchmark a single PDF."""
    zpdf_text, zpdf_time, pages = extract_zpdf(pdf_path)
    mutool_text, mutool_time = extract_mutool(pdf_path)

    zpdf_norm = normalize(zpdf_text)
    mutool_norm = normalize(mutool_text)

    acc = char_accuracy(zpdf_norm, mutool_norm)
    wer = word_error_rate(zpdf_norm, mutool_norm)
    speedup = mutool_time / zpdf_time if zpdf_time > 0 else 0

    return {
        "name": Path(pdf_path).name,
        "pages": pages,
        "zpdf_chars": len(zpdf_text),
        "mutool_chars": len(mutool_text),
        "char_accuracy": acc,
        "wer": wer,
        "zpdf_ms": zpdf_time,
        "mutool_ms": mutool_time,
        "speedup": speedup,
    }


def main():
    if len(sys.argv) > 1:
        pdf_files = [Path(p) for p in sys.argv[1:]]
    else:
        pdf_dir = Path(__file__).parent.parent
        pdf_files = sorted(pdf_dir.glob("*.pdf"))

    if not pdf_files:
        print("No PDF files found")
        sys.exit(1)

    print("=" * 80)
    print("ZPDF Correctness Benchmark (vs MuPDF reference)")
    print("=" * 80)
    print()

    mutool_version = subprocess.getoutput("mutool -v 2>&1").split()[2]
    print(f"Reference: MuPDF {mutool_version}")
    print(f"PDFs: {len(pdf_files)}")
    print()

    print(f"{'Document':<30} {'Pages':>6} {'Char Acc':>10} {'WER':>8} {'zpdf':>10} {'MuPDF':>10} {'Speedup':>8}")
    print("-" * 80)

    results = []
    for pdf in pdf_files:
        try:
            r = benchmark_pdf(str(pdf))
            results.append(r)
            print(f"{r['name']:<30} {r['pages']:>6} {r['char_accuracy']:>9.1%} {r['wer']:>7.1%} "
                  f"{r['zpdf_ms']:>8.0f}ms {r['mutool_ms']:>8.0f}ms {r['speedup']:>7.1f}x")
        except Exception as e:
            print(f"{pdf.name:<30} ERROR: {e}")

    if results:
        print("-" * 80)
        n = len(results)
        avg_acc = sum(r['char_accuracy'] for r in results) / n
        avg_wer = sum(r['wer'] for r in results) / n
        avg_speedup = sum(r['speedup'] for r in results) / n
        print(f"{'AVERAGE':<30} {'':<6} {avg_acc:>9.1%} {avg_wer:>7.1%} {'':<10} {'':<10} {avg_speedup:>7.1f}x")

        print()
        print("Metrics:")
        print("  Char Acc = Character sequence accuracy (higher = better, 100% = identical)")
        print("  WER = Word Error Rate (lower = better, 0% = identical)")


if __name__ == "__main__":
    main()
