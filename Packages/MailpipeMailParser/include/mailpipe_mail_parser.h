#ifndef MAILPIPE_MAIL_PARSER_H
#define MAILPIPE_MAIL_PARSER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Parses a raw RFC 5322 / MIME message locally with stalwartlabs/mail-parser
 * and converts HTML parts via html5gum. Performs no network or disk I/O.
 *
 * Returns a UTF-8 JSON buffer allocated by Rust and stores its byte length in
 * *out_len. Caller must release the buffer via mailpipe_mail_parser_free. */
uint8_t *mailpipe_parse_mail_body(
    const uint8_t *raw,
    size_t raw_len,
    bool for_display,
    bool from_mailkit,
    size_t *out_len
);

/* Decodes RFC 2047 encoded-words in a header string.
 * Unknown charsets or malformed encoded-word tokens remain literal.
 * Caller must release the returned UTF-8 buffer via mailpipe_mail_parser_free. */
uint8_t *mailpipe_decode_encoded_words(
    const uint8_t *input,
    size_t input_len,
    size_t *out_len
);

void mailpipe_mail_parser_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
