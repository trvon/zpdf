from __future__ import annotations
from typing import Iterator, Optional, Union
from pathlib import Path

from ._ffi import ffi, lib
from .exceptions import ZpdfError, InvalidPdfError, PageNotFoundError, ExtractionError

__version__ = "0.1.0"
__all__ = ["Document", "PageInfo", "ZpdfError", "InvalidPdfError", "PageNotFoundError", "ExtractionError"]


class PageInfo:
    __slots__ = ("width", "height", "rotation")

    def __init__(self, width: float, height: float, rotation: int):
        self.width = width
        self.height = height
        self.rotation = rotation

    def __repr__(self):
        return f"PageInfo(width={self.width}, height={self.height}, rotation={self.rotation})"


class Document:
    __slots__ = ("_handle", "_closed")

    def __init__(self, source: Union[str, Path, bytes]):
        self._closed = False

        if isinstance(source, bytes):
            self._handle = lib.zpdf_open_memory(source, len(source))
        else:
            path = str(source).encode("utf-8")
            self._handle = lib.zpdf_open(path)

        if self._handle == ffi.NULL:
            raise InvalidPdfError(f"Failed to open PDF: {source}")

    def __enter__(self) -> "Document":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()

    def __del__(self):
        if not self._closed:
            self.close()

    def close(self) -> None:
        if not self._closed and self._handle != ffi.NULL:
            lib.zpdf_close(self._handle)
            self._handle = ffi.NULL
            self._closed = True

    def _check_open(self) -> None:
        if self._closed:
            raise ValueError("Document is closed")

    @property
    def page_count(self) -> int:
        self._check_open()
        count = lib.zpdf_page_count(self._handle)
        if count < 0:
            raise InvalidPdfError("Failed to get page count")
        return count

    def get_page_info(self, page_num: int) -> PageInfo:
        self._check_open()
        width = ffi.new("double*")
        height = ffi.new("double*")
        rotation = ffi.new("int*")

        result = lib.zpdf_get_page_info(self._handle, page_num, width, height, rotation)
        if result != 0:
            raise PageNotFoundError(f"Page {page_num} not found")

        return PageInfo(width[0], height[0], rotation[0])

    def extract_page(self, page_num: int) -> str:
        self._check_open()
        if page_num < 0 or page_num >= self.page_count:
            raise PageNotFoundError(f"Page {page_num} not found")

        out_len = ffi.new("size_t*")
        buf_ptr = lib.zpdf_extract_page(self._handle, page_num, out_len)

        if buf_ptr == ffi.NULL:
            raise ExtractionError(f"Failed to extract page {page_num}")

        try:
            data = ffi.buffer(buf_ptr, out_len[0])[:]
            return data.decode("utf-8", errors="replace")
        finally:
            lib.zpdf_free_buffer(buf_ptr, out_len[0])

    def extract_all(self, parallel: bool = True) -> str:
        self._check_open()
        out_len = ffi.new("size_t*")

        if parallel:
            buf_ptr = lib.zpdf_extract_all_parallel(self._handle, out_len)
        else:
            buf_ptr = lib.zpdf_extract_all(self._handle, out_len)

        if buf_ptr == ffi.NULL:
            raise ExtractionError("Failed to extract text")

        try:
            data = ffi.buffer(buf_ptr, out_len[0])[:]
            return data.decode("utf-8", errors="replace")
        finally:
            lib.zpdf_free_buffer(buf_ptr, out_len[0])

    def __iter__(self) -> Iterator[str]:
        for i in range(self.page_count):
            yield self.extract_page(i)

    def __len__(self) -> int:
        return self.page_count
