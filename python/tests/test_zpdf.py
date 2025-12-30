import pytest
import zpdf
from pathlib import Path

TEST_PDF = Path(__file__).parent.parent.parent / "test.pdf"


class TestDocument:
    def test_open_file(self):
        with zpdf.Document(TEST_PDF) as doc:
            assert doc.page_count > 0

    def test_page_count(self):
        with zpdf.Document(TEST_PDF) as doc:
            assert isinstance(doc.page_count, int)
            assert doc.page_count >= 1

    def test_extract_page(self):
        with zpdf.Document(TEST_PDF) as doc:
            text = doc.extract_page(0)
            assert isinstance(text, str)
            assert len(text) > 0

    def test_extract_all_parallel(self):
        with zpdf.Document(TEST_PDF) as doc:
            text = doc.extract_all(parallel=True)
            assert isinstance(text, str)

    def test_extract_all_sequential(self):
        with zpdf.Document(TEST_PDF) as doc:
            text = doc.extract_all(parallel=False)
            assert isinstance(text, str)

    def test_page_info(self):
        with zpdf.Document(TEST_PDF) as doc:
            info = doc.get_page_info(0)
            assert info.width > 0
            assert info.height > 0

    def test_iteration(self):
        with zpdf.Document(TEST_PDF) as doc:
            pages = list(doc)
            assert len(pages) == doc.page_count

    def test_context_manager(self):
        with zpdf.Document(TEST_PDF) as doc:
            _ = doc.page_count
        with pytest.raises(ValueError, match="closed"):
            _ = doc.page_count

    def test_invalid_page(self):
        with zpdf.Document(TEST_PDF) as doc:
            with pytest.raises(zpdf.PageNotFoundError):
                doc.extract_page(9999)

    def test_open_bytes(self):
        with open(TEST_PDF, "rb") as f:
            data = f.read()
        with zpdf.Document(data) as doc:
            assert doc.page_count > 0
