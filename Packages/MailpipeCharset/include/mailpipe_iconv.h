#ifndef MAILPIPE_ICONV_H
#define MAILPIPE_ICONV_H

#include <stddef.h>
#include <stdint.h>

/* Local charset conversion. No network.
   Returns 0 on full conversion, 1 if output was capped at max_out, -1 on failure.
   On 0 or 1, *output is malloc'd and must be released with mailpipe_iconv_free. */
int mailpipe_iconv_utf8(const char *from_charset,
                        const uint8_t *input, size_t input_len,
                        size_t max_out,
                        uint8_t **output, size_t *output_len);

void mailpipe_iconv_free(void *pointer);

#endif
