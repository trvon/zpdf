typedef struct ZpdfDocument ZpdfDocument;

ZpdfDocument* zpdf_open(const char* path);
ZpdfDocument* zpdf_open_memory(const uint8_t* data, size_t len);
void zpdf_close(ZpdfDocument* doc);
int zpdf_page_count(ZpdfDocument* doc);
uint8_t* zpdf_extract_page(ZpdfDocument* doc, int page_num, size_t* out_len);
uint8_t* zpdf_extract_all(ZpdfDocument* doc, size_t* out_len);
uint8_t* zpdf_extract_all_parallel(ZpdfDocument* doc, size_t* out_len);
void zpdf_free_buffer(uint8_t* ptr, size_t len);
int zpdf_get_page_info(ZpdfDocument* doc, int page_num, double* width, double* height, int* rotation);
