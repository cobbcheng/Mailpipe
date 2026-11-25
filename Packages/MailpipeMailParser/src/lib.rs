mod html;

use std::borrow::Cow;
use std::slice;

use encoding_rs::Encoding;
use mail_parser::{ContentType, HeaderName, HeaderValue, Message, MessageParser, MimeHeaders, PartType};
use serde::Serialize;

const RAW_CEILING: usize = 4 * 1024 * 1024;
const EXTRACT_CAP: usize = 256 * 1024;
const MAX_DEPTH: usize = 8;
const MAX_PARTS: usize = 64;

#[derive(Serialize)]
struct ParseResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    truncated: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    attachments: Option<Vec<AttachmentNote>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rejection: Option<&'static str>,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct AttachmentNote {
    filename: Option<String>,
    media_type: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Rejection {
    MessageTooLarge,
    EncryptedContent,
    SignedOpaque,
    AttachmentOnly,
    CalendarOnly,
    MalformedMIME,
    UnsupportedCharset,
    UnsupportedContent,
    EmptyBody,
}

impl Rejection {
    fn as_str(self) -> &'static str {
        match self {
            Rejection::MessageTooLarge => "messageTooLarge",
            Rejection::EncryptedContent => "encryptedContent",
            Rejection::SignedOpaque => "signedOpaque",
            Rejection::AttachmentOnly => "attachmentOnly",
            Rejection::CalendarOnly => "calendarOnly",
            Rejection::MalformedMIME => "malformedMIME",
            Rejection::UnsupportedCharset => "unsupportedCharset",
            Rejection::UnsupportedContent => "unsupportedContent",
            Rejection::EmptyBody => "emptyBody",
        }
    }
}

#[derive(Default)]
struct EntityResult {
    body: Option<String>,
    plain: Option<String>,
    html: Option<String>,
    media_type: String,
    attachments: Vec<AttachmentNote>,
    encrypted: bool,
    opaque_signature: bool,
    calendar: bool,
    unsupported: bool,
    charset_failed: bool,
    truncated: bool,
}

impl EntityResult {
    fn with_type(media_type: String) -> Self {
        Self {
            media_type,
            ..Self::default()
        }
    }

    fn merge_flags_into(&self, other: &mut EntityResult) {
        other.attachments.extend(self.attachments.iter().cloned());
        other.encrypted |= self.encrypted;
        other.opaque_signature |= self.opaque_signature;
        other.calendar |= self.calendar;
        other.unsupported |= self.unsupported;
        other.charset_failed |= self.charset_failed;
        other.truncated |= self.truncated;
    }
}

#[no_mangle]
pub unsafe extern "C" fn mailpipe_parse_mail_body(
    raw: *const u8,
    raw_len: usize,
    for_display: bool,
    from_mailkit: bool,
    out_len: *mut usize,
) -> *mut u8 {
    let bytes = if raw.is_null() || raw_len == 0 {
        &[]
    } else {
        slice::from_raw_parts(raw, raw_len)
    };

    let result = std::panic::catch_unwind(|| parse_mail_body(bytes, for_display, from_mailkit))
        .unwrap_or(Err(Rejection::MalformedMIME));

    let response = match result {
        Ok((text, truncated, attachments)) => ParseResponse {
            ok: true,
            text: Some(text),
            truncated: Some(truncated),
            attachments: Some(attachments),
            rejection: None,
        },
        Err(reason) => ParseResponse {
            ok: false,
            text: None,
            truncated: None,
            attachments: None,
            rejection: Some(reason.as_str()),
        },
    };

    let mut json = serde_json::to_vec(&response).unwrap_or_else(|_| {
        br#"{"ok":false,"rejection":"malformedMIME"}"#.to_vec()
    });
    json.shrink_to_fit();
    let len = json.len();
    let ptr = json.as_mut_ptr();
    std::mem::forget(json);
    if !out_len.is_null() {
        *out_len = len;
    }
    ptr
}

#[no_mangle]
pub unsafe extern "C" fn mailpipe_decode_encoded_words(
    input: *const u8,
    input_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let bytes = if input.is_null() || input_len == 0 {
        &[]
    } else {
        slice::from_raw_parts(input, input_len)
    };
    let text = String::from_utf8_lossy(bytes);
    let decoded = std::panic::catch_unwind(|| decode_encoded_words_strict(&text))
        .unwrap_or_else(|_| text.into_owned());
    let mut buf = decoded.into_bytes();
    buf.shrink_to_fit();
    let len = buf.len();
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    if !out_len.is_null() {
        *out_len = len;
    }
    ptr
}

#[no_mangle]
pub unsafe extern "C" fn mailpipe_mail_parser_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        let _ = Vec::from_raw_parts(ptr, len, len);
    }
}

fn parse_mail_body(
    raw: &[u8],
    for_display: bool,
    from_mailkit: bool,
) -> Result<(String, bool, Vec<AttachmentNote>), Rejection> {
    if raw.len() > RAW_CEILING {
        return Err(Rejection::MessageTooLarge);
    }
    let Some((header_bytes, body_bytes)) = split_headers(raw) else {
        return Err(Rejection::MalformedMIME);
    };

    // Recover Apple MailKit top-level multipart messages whose outer Content-Type omitted boundary.
    let prepared: Cow<[u8]> = if from_mailkit {
        match recover_mailkit_outer_boundary(header_bytes, body_bytes)? {
            Some(buf) => Cow::Owned(buf),
            None => Cow::Borrowed(raw),
        }
    } else {
        Cow::Borrowed(raw)
    };

    let message = MessageParser::default()
        .parse(&prepared)
        .ok_or(Rejection::MalformedMIME)?;

    let mut counter = 0usize;
    let entity = walk_part(&message, 0, 0, for_display, &mut counter)?;
    let readable = entity
        .body
        .as_deref()
        .map(str::trim)
        .unwrap_or("");

    if readable.is_empty() {
        if entity.encrypted {
            return Err(Rejection::EncryptedContent);
        }
        if entity.opaque_signature {
            return Err(Rejection::SignedOpaque);
        }
        if entity.charset_failed {
            return Err(Rejection::UnsupportedCharset);
        }
        if entity.calendar
            && entity
                .attachments
                .iter()
                .all(|a| is_calendar(&a.media_type))
        {
            return Err(Rejection::CalendarOnly);
        }
        if !entity.attachments.is_empty() {
            return Err(Rejection::AttachmentOnly);
        }
        if entity.unsupported {
            return Err(Rejection::UnsupportedContent);
        }
        if entity.calendar {
            return Err(Rejection::CalendarOnly);
        }
        return Err(Rejection::EmptyBody);
    }

    Ok((readable.to_string(), entity.truncated, entity.attachments))
}

fn walk_part(
    message: &Message<'_>,
    part_id: u32,
    depth: usize,
    for_display: bool,
    counter: &mut usize,
) -> Result<EntityResult, Rejection> {
    *counter += 1;
    if *counter > MAX_PARTS || depth > MAX_DEPTH {
        return Err(Rejection::MalformedMIME);
    }
    let part = message.part(part_id).ok_or(Rejection::MalformedMIME)?;

    let (media_type, ct_opt) = part_media_type(part);

    // Attachment disposition applies to containers and embedded messages too.
    // Never decode or recurse into attached containers/messages.
    if let Some(disp) = part.content_disposition() {
        if disp.ctype().eq_ignore_ascii_case("attachment") {
            let mut res = EntityResult::with_type(media_type.clone());
            res.attachments.push(attachment_note(part, &media_type));
            res.calendar = is_calendar(&media_type);
            return Ok(res);
        }
    }

    if is_opaque_signed(&media_type, ct_opt) {
        let mut res = EntityResult::with_type(media_type);
        res.opaque_signature = true;
        return Ok(res);
    }

    if is_encrypted(&media_type) || media_type == "multipart/encrypted" {
        let mut res = EntityResult::with_type(media_type);
        res.encrypted = true;
        return Ok(res);
    }

    if media_type.starts_with("multipart/") {
        // Validate that this multipart container actually had a declared boundary and valid structure.
        let boundary = ct_opt.and_then(|ct| ct.attribute("boundary"));
        let Some(boundary) = boundary else {
            return Err(Rejection::MalformedMIME);
        };
        if boundary.is_empty() || boundary.len() > 70 {
            return Err(Rejection::MalformedMIME);
        }

        let PartType::Multipart(children_ids) = &part.body else {
            return Err(Rejection::MalformedMIME);
        };
        if children_ids.is_empty() {
            return Err(Rejection::MalformedMIME);
        }
        // Verify opening and closing boundary markers exist in this part's raw body.
        let raw_slice = message
            .raw_message()
            .get(part.offset_body as usize..part.offset_end as usize)
            .unwrap_or(&[]);
        if !has_valid_multipart_delimiters(raw_slice, boundary) {
            return Err(Rejection::MalformedMIME);
        }

        let mut children = Vec::with_capacity(children_ids.len());
        for &child_id in children_ids {
            match walk_part(message, child_id, depth + 1, for_display, counter) {
                Ok(child) => children.push(child),
                Err(Rejection::UnsupportedCharset) => {
                    let mut failed = EntityResult::default();
                    failed.charset_failed = true;
                    children.push(failed);
                }
                Err(e) => return Err(e),
            }
        }

        if media_type == "multipart/signed" {
            let Some(content) = children
                .into_iter()
                .find(|c| !is_detached_signature(&c.media_type))
            else {
                let mut res = EntityResult::with_type(media_type);
                res.opaque_signature = true;
                return Ok(res);
            };
            let mut result = content;
            result.media_type = media_type;
            if result
                .body
                .as_deref()
                .map(str::trim)
                .unwrap_or("")
                .is_empty()
            {
                result.opaque_signature = true;
            }
            return Ok(result);
        }

        if media_type == "multipart/alternative" {
            return Ok(merge_alternative(children, media_type));
        }
        return Ok(merge_mixed(children, media_type));
    }

    if media_type == "message/rfc822" || media_type == "message/global" {
        if let PartType::Message(inner) = &part.body {
            return walk_part(inner, 0, depth + 1, for_display, counter);
        }
        // Fallback if mail-parser stored raw bytes for an inline embedded message.
        let inner_bytes = part.contents();
        let inner_msg = MessageParser::default()
            .parse(inner_bytes)
            .ok_or(Rejection::MalformedMIME)?;
        return walk_part(&inner_msg, 0, depth + 1, for_display, counter);
    }

    if is_calendar(&media_type) {
        let mut res = EntityResult::with_type(media_type.clone());
        res.attachments.push(attachment_note(part, &media_type));
        res.calendar = true;
        return Ok(res);
    }

    if media_type == "text/plain" || media_type == "text/html" {
        return extract_text_part(message, part, &media_type, ct_opt, for_display);
    }

    if is_attachment_media_type(&media_type) {
        let mut res = EntityResult::with_type(media_type.clone());
        res.attachments.push(attachment_note(part, &media_type));
        return Ok(res);
    }

    let mut res = EntityResult::with_type(media_type);
    res.unsupported = true;
    Ok(res)
}

fn extract_text_part(
    message: &Message<'_>,
    part: &mail_parser::MessagePart<'_>,
    media_type: &str,
    ct_opt: Option<&ContentType<'_>>,
    for_display: bool,
) -> Result<EntityResult, Rejection> {
    // Reject explicitly declared unknown charsets rather than silently falling back to lossy UTF-8.
    let declared_charset = ct_opt.and_then(|ct| ct.attribute("charset"));
    if let Some(charset) = declared_charset {
        if !charset.trim().is_empty() && resolve_encoding(charset).is_none() {
            return Err(Rejection::UnsupportedCharset);
        }
    }

    // If an HTML part omits a header charset, check the original part bytes for <meta charset="...">.
    let mut decoded_text: String = if media_type == "text/html" && declared_charset.is_none() {
        let raw_slice = message
            .raw_message()
            .get(part.offset_body as usize..part.offset_end as usize)
            .unwrap_or(&[]);
        let transfer_decoded = decode_transfer_bytes(raw_slice, part.encoding);
        if let Some(meta) = html_meta_charset(&transfer_decoded) {
            if let Some(enc) = resolve_encoding(&meta) {
                if transfer_decoded.contains(&0) {
                    return Err(Rejection::MalformedMIME);
                }
                let (cow, _, _) = enc.decode(&transfer_decoded);
                cow.into_owned()
            } else {
                return Err(Rejection::UnsupportedCharset);
            }
        } else {
            decode_part_body(part, declared_charset, true)?
        }
    } else {
        decode_part_body(part, declared_charset, media_type == "text/html")?
    };

    if decoded_text.contains('\0') {
        return Err(Rejection::MalformedMIME);
    }

    let mut truncated = false;
    if !for_display && decoded_text.len() > EXTRACT_CAP {
        decoded_text = html::utf8_prefix(&decoded_text, EXTRACT_CAP).to_string();
        truncated = true;
    }

    let looks_like_html_doc = for_display && starts_like_html_document(&decoded_text);
    let converted = if media_type == "text/html" || looks_like_html_doc {
        html::to_plain_text(&decoded_text)
    } else {
        unwrap_pgp_armor(&decoded_text)?
    };

    let text = if for_display {
        html::normalize_text(&converted, false, false)
    } else {
        html::normalize_text(&converted, true, true)
    };

    if text.contains('\0') {
        return Err(Rejection::MalformedMIME);
    }

    let mut result = EntityResult::with_type(media_type.to_string());
    result.truncated = truncated;
    if media_type == "text/html" {
        result.html = Some(text.clone());
        result.body = Some(text);
    } else {
        result.plain = Some(text.clone());
        result.body = Some(text);
    }
    Ok(result)
}

fn decode_part_body(
    part: &mail_parser::MessagePart<'_>,
    declared_charset: Option<&str>,
    allow_html_meta: bool,
) -> Result<String, Rejection> {
    match &part.body {
        PartType::Text(s) | PartType::Html(s) => Ok(s.as_ref().to_string()),
        PartType::Binary(b) | PartType::InlineBinary(b) => {
            if b.contains(&0) {
                return Err(Rejection::MalformedMIME);
            }
            decode_bytes_with_charset(b, declared_charset, allow_html_meta)
        }
        _ => Err(Rejection::MalformedMIME),
    }
}

fn decode_transfer_bytes<'a>(raw: &'a [u8], encoding: mail_parser::Encoding) -> Cow<'a, [u8]> {
    match encoding {
        mail_parser::Encoding::QuotedPrintable => {
            let mut out = Vec::with_capacity(raw.len());
            let mut i = 0;
            while i < raw.len() {
                if raw[i] == b'=' {
                    if i + 1 < raw.len() && raw[i + 1] == b'\n' {
                        i += 2;
                        continue;
                    }
                    if i + 2 < raw.len() && raw[i + 1] == b'\r' && raw[i + 2] == b'\n' {
                        i += 3;
                        continue;
                    }
                    if i + 2 < raw.len() {
                        if let (Some(h), Some(l)) = (hex_val(raw[i + 1]), hex_val(raw[i + 2])) {
                            out.push((h << 4) | l);
                            i += 3;
                            continue;
                        }
                    }
                }
                out.push(raw[i]);
                i += 1;
            }
            Cow::Owned(out)
        }
        mail_parser::Encoding::Base64 => {
            // Re-parse single part with mail-parser as octet-stream to reuse its base64 decoder.
            let mut synthetic = Vec::with_capacity(raw.len() + 80);
            synthetic.extend_from_slice(
                b"Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n",
            );
            synthetic.extend_from_slice(raw);
            if let Some(msg) = MessageParser::default().parse(&synthetic) {
                if let Some(p) = msg.part(0) {
                    return Cow::Owned(p.contents().to_vec());
                }
            }
            Cow::Borrowed(raw)
        }
        _ => Cow::Borrowed(raw),
    }
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'A'..=b'F' => Some(b - b'A' + 10),
        b'a'..=b'f' => Some(b - b'a' + 10),
        _ => None,
    }
}

fn merge_alternative(children: Vec<EntityResult>, media_type: String) -> EntityResult {
    let mut result = EntityResult::with_type(media_type);
    for child in &children {
        child.merge_flags_into(&mut result);
    }
    let plain = children
        .iter()
        .filter_map(|c| c.plain.as_ref())
        .find(|s| !s.trim().is_empty())
        .cloned();
    let html = children
        .iter()
        .filter_map(|c| c.html.as_ref())
        .find(|s| !s.trim().is_empty())
        .cloned();
    let fallback = children
        .iter()
        .filter_map(|c| c.body.as_ref())
        .find(|s| !s.trim().is_empty())
        .cloned();
    result.body = plain.clone().or_else(|| html.clone()).or(fallback);
    result.plain = plain;
    result.html = html;
    result
}

fn merge_mixed(children: Vec<EntityResult>, media_type: String) -> EntityResult {
    let mut result = EntityResult::with_type(media_type);
    let mut texts = Vec::new();
    for child in &children {
        child.merge_flags_into(&mut result);
        if let Some(body) = child.body.as_deref().map(str::trim) {
            if !body.is_empty() {
                texts.push(body.to_string());
            }
        }
    }
    if !texts.is_empty() {
        let joined = texts.join("\n\n");
        result.body = Some(joined.clone());
        result.plain = Some(joined);
    }
    result
}

fn part_media_type<'a>(part: &'a mail_parser::MessagePart<'a>) -> (String, Option<&'a ContentType<'a>>) {
    if let Some(ct) = part.content_type() {
        let main = ct.ctype().to_ascii_lowercase();
        let full = match ct.subtype() {
            Some(sub) if !sub.is_empty() => format!("{main}/{}", sub.to_ascii_lowercase()),
            _ => main,
        };
        return (full, Some(ct));
    }
    ("text/plain".to_string(), None)
}

fn attachment_note(part: &mail_parser::MessagePart<'_>, media_type: &str) -> AttachmentNote {
    let filename = part
        .attachment_name()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| decode_encoded_words_strict(s));
    AttachmentNote {
        filename,
        media_type: media_type.to_string(),
    }
}

fn resolve_encoding(charset: &str) -> Option<&'static Encoding> {
    let cleaned = charset.trim().trim_matches('"').to_ascii_lowercase();
    let normalized = cleaned.replace('_', "-");
    if normalized == "us-ascii" || normalized == "ascii" || normalized == "ansi-x3.4-1968" {
        return Some(encoding_rs::UTF_8);
    }
    Encoding::for_label(normalized.as_bytes())
}

fn decode_bytes_with_charset(
    bytes: &[u8],
    declared: Option<&str>,
    allow_html_meta: bool,
) -> Result<String, Rejection> {
    let charset_owned: Option<String> = declared
        .map(str::to_string)
        .or_else(|| if allow_html_meta { html_meta_charset(bytes) } else { None });
    let charset = charset_owned.as_deref().unwrap_or("utf-8");
    let enc = resolve_encoding(charset).ok_or(Rejection::UnsupportedCharset)?;
    let (cow, _, _) = enc.decode(bytes);
    Ok(cow.into_owned())
}

fn html_meta_charset(data: &[u8]) -> Option<String> {
    let sample = &data[..data.len().min(4096)];
    let text: String = sample.iter().map(|&b| b as char).collect();
    let lower = text.to_ascii_lowercase();
    let pos = lower.find("charset=")?;
    let mut rest = &text[pos + "charset=".len()..];
    if rest.starts_with('"') || rest.starts_with('\'') {
        rest = &rest[1..];
    }
    let end = rest
        .find(|c: char| matches!(c, '"' | '\'' | ';' | '>' | ' ' | '/' | '\r' | '\n'))
        .unwrap_or(rest.len());
    let name = rest[..end].trim();
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

fn starts_like_html_document(text: &str) -> bool {
    let trimmed = text.trim_start();
    let prefix: String = trimmed.chars().take(16).collect();
    let lower = prefix.to_ascii_lowercase();
    if lower.starts_with("<!doctype") {
        let rest = lower["<!doctype".len()..].trim_start();
        return rest.starts_with("html");
    }
    if lower.starts_with("<html") {
        return matches!(lower.as_bytes().get(5), Some(b'>') | Some(b' ') | Some(b'\t') | Some(b'\r') | Some(b'\n'));
    }
    false
}

fn unwrap_pgp_armor(text: &str) -> Result<String, Rejection> {
    if let Some(signed) = clear_signed_pgp(text) {
        return Ok(signed);
    }
    if let Some(start) = text.find("-----BEGIN PGP MESSAGE-----") {
        let after = text
            .find("-----END PGP MESSAGE-----")
            .map(|end| &text[end + "-----END PGP MESSAGE-----".len()..])
            .unwrap_or("");
        let rest = format!("{}{}", &text[..start], after);
        let trimmed = rest.trim();
        if trimmed.chars().count() < 20 {
            return Err(Rejection::EncryptedContent);
        }
        return Ok(format!("{trimmed}\n[encrypted part omitted]"));
    }
    Ok(text.to_string())
}

fn clear_signed_pgp(text: &str) -> Option<String> {
    let start = text.find("-----BEGIN PGP SIGNED MESSAGE-----")?;
    let sig = text.find("-----BEGIN PGP SIGNATURE-----")?;
    if sig <= start {
        return None;
    }
    let preface = text[..start].trim();
    let header_and_body = &text[start + "-----BEGIN PGP SIGNED MESSAGE-----".len()..sig];
    let normalized = header_and_body.replace("\r\n", "\n");
    let mut lines: Vec<&str> = normalized.split('\n').collect();
    if lines.first().map(|l| l.trim().is_empty()).unwrap_or(false) {
        lines.remove(0);
    }
    let blank = lines.iter().position(|l| l.trim().is_empty())?;
    let body = lines[blank + 1..]
        .iter()
        .map(|l| l.strip_prefix("- ").unwrap_or(l))
        .collect::<Vec<_>>()
        .join("\n");
    let body = body.trim();
    if body.is_empty() {
        return None;
    }
    if preface.is_empty() {
        Some(body.to_string())
    } else {
        Some(format!("{preface}\n{body}"))
    }
}

fn is_encrypted(media_type: &str) -> bool {
    matches!(
        media_type,
        "application/pkcs7-mime" | "application/x-pkcs7-mime" | "application/pgp-encrypted"
    )
}

fn is_opaque_signed(media_type: &str, ct: Option<&ContentType<'_>>) -> bool {
    if !matches!(media_type, "application/pkcs7-mime" | "application/x-pkcs7-mime") {
        return false;
    }
    ct.and_then(|c| c.attribute("smime-type"))
        .map(|v| v.eq_ignore_ascii_case("signed-data"))
        .unwrap_or(false)
}

fn is_detached_signature(media_type: &str) -> bool {
    matches!(
        media_type,
        "application/pgp-signature" | "application/pkcs7-signature" | "application/x-pkcs7-signature"
    )
}

fn is_calendar(media_type: &str) -> bool {
    matches!(media_type, "text/calendar" | "application/ics")
}

fn is_attachment_media_type(media_type: &str) -> bool {
    if media_type.starts_with("image/")
        || media_type.starts_with("audio/")
        || media_type.starts_with("video/")
    {
        return true;
    }
    matches!(
        media_type,
        "application/pdf"
            | "application/zip"
            | "application/gzip"
            | "application/octet-stream"
            | "application/msword"
            | "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            | "application/vnd.ms-excel"
            | "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            | "application/ms-tnef"
            | "application/vnd.ms-tnef"
            | "application/x-apple-msg-attachment"
    )
}

fn split_headers(data: &[u8]) -> Option<(&[u8], &[u8])> {
    let prefix_len = data.len().min(64 * 1024 + 4);
    let prefix = &data[..prefix_len];
    let crlfcrlf = prefix.windows(4).position(|w| w == b"\r\n\r\n");
    let lflf = prefix.windows(2).position(|w| w == b"\n\n");
    let (idx, sep_len) = match (crlfcrlf, lflf) {
        (Some(a), Some(b)) => {
            if a <= b {
                (a, 4)
            } else {
                (b, 2)
            }
        }
        (Some(a), None) => (a, 4),
        (None, Some(b)) => (b, 2),
        (None, None) => return None,
    };
    Some((&data[..idx], &data[idx + sep_len..]))
}

fn has_valid_multipart_delimiters(body: &[u8], boundary: &str) -> bool {
    let open = format!("--{boundary}");
    let close = format!("--{boundary}--");
    let mut saw_open = false;
    let mut saw_close = false;
    for raw_line in body.split(|&b| b == b'\n') {
        let mut line = raw_line;
        if line.ends_with(b"\r") {
            line = &line[..line.len() - 1];
        }
        while matches!(line.last(), Some(b' ' | b'\t')) {
            line = &line[..line.len() - 1];
        }
        if line == open.as_bytes() {
            saw_open = true;
        } else if line == close.as_bytes() {
            saw_close = true;
            break;
        }
    }
    saw_open && saw_close
}

/// Apple MailKit can omit the outer `boundary` parameter on `multipart/alternative`,
/// `multipart/mixed`, and `multipart/related` while keeping both delimiter lines intact.
fn recover_mailkit_outer_boundary(
    header_bytes: &[u8],
    body_bytes: &[u8],
) -> Result<Option<Vec<u8>>, Rejection> {
    // Parse only outer headers with mail-parser to inspect Content-Type cleanly.
    let mut probe = Vec::with_capacity(header_bytes.len() + 4);
    probe.extend_from_slice(header_bytes);
    probe.extend_from_slice(b"\r\n\r\n");
    let Some(parsed) = MessageParser::default().parse(&probe) else {
        return Ok(None);
    };
    let Some(ct) = parsed.content_type() else {
        return Ok(None);
    };
    if !ct.ctype().eq_ignore_ascii_case("multipart") {
        return Ok(None);
    }
    let subtype = ct.subtype().unwrap_or("").to_ascii_lowercase();
    if !matches!(subtype.as_str(), "alternative" | "mixed" | "related") {
        return Ok(None);
    }
    if ct.attribute("boundary").is_some() {
        return Ok(None);
    }

    let Some(boundary) = infer_enclosing_boundary(body_bytes) else {
        return Err(Rejection::MalformedMIME);
    };

    // Rewrite the outer Content-Type header line to include the inferred boundary.
    let mut out = Vec::with_capacity(header_bytes.len() + body_bytes.len() + boundary.len() + 32);
    let mut injected = false;
    let header_str = String::from_utf8_lossy(header_bytes);
    // Unfold only the Content-Type line cleanly while keeping other headers verbatim.
    let lines: Vec<&str> = header_str.split('\n').collect();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i].strip_suffix('\r').unwrap_or(lines[i]);
        if !injected && line.to_ascii_lowercase().starts_with("content-type:") {
            out.extend_from_slice(line.as_bytes());
            while i + 1 < lines.len()
                && (lines[i + 1].starts_with(' ') || lines[i + 1].starts_with('\t'))
            {
                i += 1;
                let cont = lines[i].strip_suffix('\r').unwrap_or(lines[i]);
                out.extend_from_slice(b"\r\n");
                out.extend_from_slice(cont.as_bytes());
            }
            out.extend_from_slice(b"; boundary=\"");
            out.extend_from_slice(boundary.as_bytes());
            out.extend_from_slice(b"\"\r\n");
            injected = true;
        } else {
            out.extend_from_slice(line.as_bytes());
            out.extend_from_slice(b"\r\n");
        }
        i += 1;
    }
    out.extend_from_slice(b"\r\n");
    out.extend_from_slice(body_bytes);
    Ok(Some(out))
}

fn infer_enclosing_boundary(data: &[u8]) -> Option<String> {
    let start = data.iter().position(|&b| b != b'\n' && b != b'\r')?;
    let mut first = &data[start..];
    if let Some(nl) = first.iter().position(|&b| b == b'\n' || b == b'\r') {
        first = &first[..nl];
    }
    while matches!(first.last(), Some(b' ' | b'\t')) {
        first = &first[..first.len() - 1];
    }
    if !first.starts_with(b"--") || !(3..=72).contains(&first.len()) {
        return None;
    }
    let token = &first[2..];
    if !token.iter().all(|&b| (33..=126).contains(&b)) {
        return None;
    }
    let boundary = std::str::from_utf8(token).ok()?;
    let open = format!("--{boundary}");
    let close = format!("--{boundary}--");

    let mut opens = 0usize;
    let mut saw_close = false;
    for raw_line in data.split(|&b| b == b'\n') {
        let mut line = raw_line;
        if line.ends_with(b"\r") {
            line = &line[..line.len() - 1];
        }
        while matches!(line.last(), Some(b' ' | b'\t')) {
            line = &line[..line.len() - 1];
        }
        if saw_close {
            // Strict trailing check: no epilogue or duplicate closing delimiter allowed.
            if !line.is_empty() {
                return None;
            }
            continue;
        }
        if line == open.as_bytes() {
            opens += 1;
        } else if line == close.as_bytes() {
            saw_close = true;
        }
    }
    if opens > 0 && saw_close {
        Some(boundary.to_string())
    } else {
        None
    }
}

/// Decodes RFC 2047 encoded-words while preserving unknown charsets or broken tokens literally.
fn decode_encoded_words_strict(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut rest = value;
    let mut pending_space = String::new();
    let mut last_was_word = false;

    while !rest.is_empty() {
        if let Some((decoded, consumed)) = parse_single_encoded_word(rest) {
            if !last_was_word {
                result.push_str(&pending_space);
            }
            pending_space.clear();
            result.push_str(&decoded);
            last_was_word = true;
            rest = &rest[consumed..];
            continue;
        }
        let ch = rest.chars().next().unwrap();
        if last_was_word && (ch == ' ' || ch == '\t') {
            pending_space.push(ch);
        } else {
            result.push_str(&pending_space);
            pending_space.clear();
            last_was_word = false;
            result.push(ch);
        }
        rest = &rest[ch.len_utf8()..];
    }
    result.push_str(&pending_space);
    result
}

fn parse_single_encoded_word(input: &str) -> Option<(String, usize)> {
    if !input.starts_with("=?") {
        return None;
    }
    let after_prefix = &input[2..];
    let q1 = after_prefix.find('?')?;
    if q1 == 0 {
        return None;
    }
    let charset = &after_prefix[..q1];
    // Reject unknown charset so invalid tokens stay literal (matches MailSourceEvidence contract).
    resolve_encoding(charset)?;

    let after_q1 = &after_prefix[q1 + 1..];
    let coding = after_q1.as_bytes().first().copied()?;
    if !matches!(coding, b'B' | b'b' | b'Q' | b'q') {
        return None;
    }
    if after_q1.as_bytes().get(1) != Some(&b'?') {
        return None;
    }
    let payload_start = &after_q1[2..];
    let end_rel = payload_start.find("?=")?;
    let payload = &payload_start[..end_rel];
    // Reject broken base64 tokens so they stay literal.
    if matches!(coding, b'B' | b'b') {
        let compact: Vec<u8> = payload
            .bytes()
            .filter(|b| !b.is_ascii_whitespace())
            .collect();
        if compact.len() % 4 != 0
            || !compact
                .iter()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='))
        {
            return None;
        }
    }

    let consumed = 2 + q1 + 1 + 2 + end_rel + 2;
    let token = &input[..consumed];

    // Delegate actual RFC 2047 decoding to stalwartlabs/mail-parser.
    let mut raw = Vec::with_capacity(12 + token.len());
    raw.extend_from_slice(b"Subject: ");
    raw.extend_from_slice(token.as_bytes());
    raw.extend_from_slice(b"\r\n\r\n");
    let msg = MessageParser::default().parse(&raw)?;
    let header = msg.header(HeaderName::Subject)?;
    let HeaderValue::Text(decoded) = header else {
        return None;
    };
    Some((decoded.as_ref().to_string(), consumed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_preheader_combining_marks_do_not_hang() {
        let raw = concat!(
            "Content-Type: text/html; charset=utf-8\r\n\r\n",
            "<html><body>",
            "<div style=\"display:none;max-height:0px;overflow:hidden\">Preview</div>",
            "<div style=\"max-height:0;overflow:hidden;opacity:0\">&#847;&zwnj;&nbsp;</div>",
            "<p>Intro</p>\r\n\r\n\r\n&#847;&nbsp;&#847;<p>Please review <a href=\"https://example.com/doc\">the doc</a>.</p>",
            "</body></html>"
        );
        let (text, truncated, attachments) = parse_mail_body(raw.as_bytes(), false, false).unwrap();
        assert!(!truncated);
        assert!(attachments.is_empty());
        assert!(text.contains("Intro"));
        assert!(text.contains("Please review the doc (https://example.com/doc)."));
        assert!(!text.contains("Preview"));
        assert!(!text.contains('\u{034F}'));
    }

    #[test]
    fn encoded_words_preserve_unknown_and_broken_tokens() {
        assert_eq!(decode_encoded_words_strict("=?UTF-8?B?6K+35rGC6K+B5piO?="), "请求证明");
        assert_eq!(decode_encoded_words_strict("=?utf-8?Q?Please?= =?utf-8?Q?_reply?="), "Please reply");
        assert_eq!(decode_encoded_words_strict("=?unknown?B?5L2g5aW9?="), "=?unknown?B?5L2g5aW9?=");
        assert_eq!(decode_encoded_words_strict("=?utf-8?B?broken?="), "=?utf-8?B?broken?=");
    }
}
