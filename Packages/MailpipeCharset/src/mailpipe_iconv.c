#include "mailpipe_iconv.h"

#include <errno.h>
#include <iconv.h>
#include <stdlib.h>
#include <string.h>

int mailpipe_iconv_utf8(const char *from_charset,
                        const uint8_t *input, size_t input_len,
                        size_t max_out,
                        uint8_t **output, size_t *output_len) {
    if (output == NULL || output_len == NULL || from_charset == NULL || from_charset[0] == '\0') return -1;
    *output = NULL;
    *output_len = 0;
    if (max_out == 0) return -1;
    if (input_len > 0 && input == NULL) return -1;

    iconv_t cd = iconv_open("UTF-8", from_charset);
    if (cd == (iconv_t)-1) return -1;

    uint8_t *buffer = (uint8_t *)malloc(max_out);
    if (buffer == NULL) {
        iconv_close(cd);
        return -1;
    }

    char *inbuf = (char *)input;
    size_t inleft = input_len;
    char *outbuf = (char *)buffer;
    size_t outleft = max_out;
    /* glibc and the macOS SDK both take char ** here. */
    size_t converted = iconv(cd, &inbuf, &inleft, &outbuf, &outleft);
    int error = errno;
    iconv_close(cd);

    if (converted == (size_t)-1 && error != E2BIG) {
        free(buffer);
        return -1;
    }
    *output = buffer;
    *output_len = max_out - outleft;
    return (converted == (size_t)-1) ? 1 : 0;
}

void mailpipe_iconv_free(void *pointer) {
    free(pointer);
}
