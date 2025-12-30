#!/usr/bin/env python3
"""Compare parallel vs sequential extraction speed."""
import sys
import time
sys.path.insert(0, "python")

import zpdf

pdf_path = sys.argv[1] if len(sys.argv) > 1 else "test.pdf"

with zpdf.Document(pdf_path) as doc:
    print(f"Document: {pdf_path} ({doc.page_count} pages)")

    start = time.time()
    text = doc.extract_all(parallel=True)
    parallel_time = time.time() - start

    start = time.time()
    text = doc.extract_all(parallel=False)
    sequential_time = time.time() - start

    print(f"Parallel:   {parallel_time*1000:.1f}ms")
    print(f"Sequential: {sequential_time*1000:.1f}ms")
    print(f"Speedup:    {sequential_time/parallel_time:.1f}x")
