use std::collections::BTreeMap;
use html5gum::{HtmlString, SpanBound, Spanned, Token, Tokenizer};

#[derive(Debug)]
struct Frame {
    name: String,
    skip: bool,
    quote: bool,
    pre: bool,
    anchor: Option<(String, usize)>,
}

struct ListState {
    ordered: bool,
    item: usize,
}

const QUOTE_START: char = '\u{E000}';
const QUOTE_END: char = '\u{E001}';
const PRE_START: char = '\u{E002}';
const PRE_END: char = '\u{E003}';

/// Converts HTML to clean readable plain text using html5gum's WHATWG HTML5 tokenizer.
/// No network access, no layout engine, strictly linear time.
pub fn to_plain_text(html: &str) -> String {
    let mut output = String::with_capacity(html.len().min(65_536));
    let mut stack: Vec<Frame> = Vec::new();
    let mut lists: Vec<ListState> = Vec::new();

    for token in Tokenizer::new(html).flatten() {
        match token {
            Token::StartTag(tag) => {
                let name = String::from_utf8_lossy(&tag.name).to_ascii_lowercase();
                let skipping = stack.iter().any(|f| f.skip);

                if matches!(
                    name.as_str(),
                    "script" | "style" | "head" | "title" | "svg" | "noscript"
                ) {
                    if !tag.self_closing {
                        stack.push(Frame {
                            name,
                            skip: true,
                            quote: false,
                            pre: false,
                            anchor: None,
                        });
                    }
                    continue;
                }

                if is_hidden(&tag.attributes) {
                    if !is_void(&name) && !tag.self_closing {
                        stack.push(Frame {
                            name,
                            skip: true,
                            quote: false,
                            pre: false,
                            anchor: None,
                        });
                    }
                    continue;
                }

                let mut frame = Frame {
                    name: name.clone(),
                    skip: false,
                    quote: false,
                    pre: false,
                    anchor: None,
                };

                if !skipping {
                    let classes = class_tokens(&tag.attributes);
                    if name == "blockquote"
                        || classes.iter().any(|c| c == "gmail_quote" || c == "moz-cite-prefix")
                    {
                        frame.quote = true;
                        output.push('\n');
                        output.push(QUOTE_START);
                    }
                    if classes
                        .iter()
                        .any(|c| c == "gmail_signature" || c == "moz-signature")
                    {
                        output.push_str("\n-- \n");
                    }
                    if name == "pre" {
                        frame.pre = true;
                        output.push(PRE_START);
                    }
                    if name == "br" || name == "hr" {
                        output.push('\n');
                        continue;
                    }
                    if name == "img" {
                        if let Some(alt) = attr_value(&tag.attributes, "alt") {
                            let trimmed = alt.trim();
                            if !trimmed.is_empty() && trimmed.len() <= 80 {
                                output.push_str(trimmed);
                            }
                        }
                        continue;
                    }
                    if name == "a" {
                        let href = attr_value(&tag.attributes, "href").unwrap_or_default();
                        frame.anchor = Some((href, output.len()));
                    }
                    if name == "ol" {
                        lists.push(ListState {
                            ordered: true,
                            item: 0,
                        });
                    } else if name == "ul" {
                        lists.push(ListState {
                            ordered: false,
                            item: 0,
                        });
                    }
                    if is_block(&name) {
                        output.push('\n');
                    }
                    if name == "li" {
                        let indent = "  ".repeat(lists.len().saturating_sub(1));
                        if let Some(list) = lists.last_mut() {
                            list.item += 1;
                            output.push_str(&indent);
                            if list.ordered {
                                output.push_str(&format!("{}. ", list.item));
                            } else {
                                output.push_str("- ");
                            }
                        } else {
                            output.push_str("- ");
                        }
                    }
                }

                if !is_void(&name) && !tag.self_closing {
                    stack.push(frame);
                }
            }
            Token::EndTag(tag) => {
                let name = String::from_utf8_lossy(&tag.name).to_ascii_lowercase();
                if name == "ol" || name == "ul" {
                    lists.pop();
                }
                if let Some(found) = stack.iter().rposition(|f| f.name == name) {
                    let removed: Vec<Frame> = stack.drain(found..).collect();
                    let still_skipping = stack.iter().any(|f| f.skip);
                    for frame in removed.into_iter().rev() {
                        if !still_skipping && !frame.skip {
                            if let Some((href, offset)) = frame.anchor {
                                let start = offset.min(output.len());
                                if output.is_char_boundary(start) {
                                    let added = output[start..].to_string();
                                    let rendered = render_link(&added, &href);
                                    output.truncate(start);
                                    output.push_str(&rendered);
                                }
                            }
                            if frame.quote {
                                output.push('\n');
                                output.push(QUOTE_END);
                            }
                            if frame.pre {
                                output.push(PRE_END);
                            }
                            if is_block(&frame.name) {
                                output.push('\n');
                            }
                        }
                    }
                }
            }
            Token::String(text) => {
                if !stack.iter().any(|f| f.skip) {
                    let s = String::from_utf8_lossy(&text);
                    for ch in s.chars() {
                        if !is_invisible_filler(ch) {
                            output.push(ch);
                        }
                    }
                }
            }
            Token::Comment(_) | Token::Doctype(_) | Token::ProcessingInstruction(_) | Token::Error(_) => {}
        }
    }

    let finished = finish_regions(&output);
    normalize_text(&finished, true, true)
}

pub fn normalize_text(text: &str, strip_bom: bool, collapse_blank_lines: bool) -> String {
    let mut out = String::with_capacity(text.len());
    let mut pending_cr = false;
    let mut consecutive_newlines = 0usize;

    let emit_newline = |out: &mut String, count: &mut usize| {
        *count += 1;
        if !collapse_blank_lines || *count <= 2 {
            out.push('\n');
        }
    };

    for ch in text.chars() {
        if strip_bom && ch == '\u{FEFF}' {
            continue;
        }
        if pending_cr {
            pending_cr = false;
            if ch == '\n' {
                emit_newline(&mut out, &mut consecutive_newlines);
                continue;
            }
            emit_newline(&mut out, &mut consecutive_newlines);
        }
        if ch == '\r' {
            pending_cr = true;
        } else if ch == '\n' {
            emit_newline(&mut out, &mut consecutive_newlines);
        } else {
            consecutive_newlines = 0;
            out.push(ch);
        }
    }
    if pending_cr {
        emit_newline(&mut out, &mut consecutive_newlines);
    }

    if collapse_blank_lines {
        out.trim().to_string()
    } else {
        out
    }
}

fn is_invisible_filler(ch: char) -> bool {
    matches!(
        ch,
        '\u{034F}' // Combining Grapheme Joiner (&#847; in marketing preheaders)
        | '\u{200B}' // Zero Width Space
        | '\u{200C}' // Zero Width Non-Joiner (&zwnj;)
        | '\u{200D}' // Zero Width Joiner
        | '\u{FEFF}' // BOM / ZWNBSP
        | '\u{00AD}' // Soft Hyphen
    )
}

fn finish_regions(text: &str) -> String {
    let mut quote = 0usize;
    let mut pre = false;
    let mut result = String::with_capacity(text.len());
    let mut line_start = true;

    for ch in text.chars() {
        match ch {
            QUOTE_START => {
                quote += 1;
                continue;
            }
            QUOTE_END => {
                quote = quote.saturating_sub(1);
                continue;
            }
            PRE_START => {
                pre = true;
                continue;
            }
            PRE_END => {
                pre = false;
                continue;
            }
            '\n' => {
                result.push('\n');
                line_start = true;
                continue;
            }
            _ => {}
        }

        if line_start {
            if quote > 0 {
                for _ in 0..quote {
                    result.push_str("> ");
                }
            }
            line_start = false;
        }

        if !pre && (ch == ' ' || ch == '\t' || ch == '\u{00A0}') {
            if matches!(result.chars().last(), Some(' ' | '\n' | '>')) {
                continue;
            }
            result.push(' ');
        } else {
            result.push(ch);
        }
    }
    result
}

fn attr_value<S: SpanBound>(attrs: &BTreeMap<HtmlString, Spanned<HtmlString, S>>, name: &str) -> Option<String> {
    attrs
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name.as_bytes()))
        .map(|(_, v)| String::from_utf8_lossy(&v.value).into_owned())
}

fn class_tokens<S: SpanBound>(attrs: &BTreeMap<HtmlString, Spanned<HtmlString, S>>) -> Vec<String> {
    attr_value(attrs, "class")
        .map(|v| {
            v.split_whitespace()
                .map(|t| t.to_ascii_lowercase())
                .collect()
        })
        .unwrap_or_default()
}

fn is_hidden<S: SpanBound>(attrs: &BTreeMap<HtmlString, Spanned<HtmlString, S>>) -> bool {
    if attrs
        .keys()
        .any(|k| k.eq_ignore_ascii_case(b"hidden"))
    {
        return true;
    }
    let Some(style) = attr_value(attrs, "style") else {
        return false;
    };
    let compact: String = style
        .chars()
        .filter(|c| !c.is_whitespace())
        .map(|c| c.to_ascii_lowercase())
        .collect();
    if compact.contains("display:none")
        || compact.contains("visibility:hidden")
        || compact.contains("mso-hide:all")
    {
        return true;
    }
    // Common marketing email preheader hiding technique: zero height/font/opacity with overflow:hidden.
    let overflow_hidden = compact.contains("overflow:hidden");
    let zero_box = compact.contains("max-height:0")
        || compact.contains("opacity:0")
        || compact.contains("font-size:0");
    overflow_hidden && zero_box
}

fn is_block(name: &str) -> bool {
    matches!(
        name,
        "p" | "div"
            | "tr"
            | "table"
            | "section"
            | "article"
            | "header"
            | "footer"
            | "h1"
            | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "blockquote"
            | "ul"
            | "ol"
            | "pre"
            | "li"
    )
}

fn is_void(name: &str) -> bool {
    matches!(
        name,
        "br" | "hr"
            | "img"
            | "meta"
            | "link"
            | "input"
            | "source"
            | "wbr"
            | "area"
            | "base"
            | "col"
            | "embed"
            | "param"
            | "track"
    )
}

fn render_link(text: &str, href: &str) -> String {
    let visible = text.trim();
    let url = href.trim();
    let lower = url.to_ascii_lowercase();
    if url.is_empty()
        || lower.starts_with("javascript:")
        || lower.starts_with("data:")
        || lower.starts_with("cid:")
    {
        return visible.to_string();
    }
    if !(lower.starts_with("http://")
        || lower.starts_with("https://")
        || lower.starts_with("mailto:"))
    {
        return visible.to_string();
    }
    let shown = readable_url(url);
    if visible.is_empty() {
        return shown;
    }
    if visible == url || visible.contains(url) {
        return visible.to_string();
    }
    format!("{visible} ({shown})")
}

fn readable_url(url: &str) -> String {
    if url.len() <= 300 {
        return url.to_string();
    }
    if let Some(q) = url.find('?') {
        let base = &url[..q];
        if base.len() <= 300 {
            return base.to_string();
        }
    }
    utf8_prefix(url, 300).to_string()
}

pub fn utf8_prefix(text: &str, budget: usize) -> &str {
    if text.len() <= budget {
        return text;
    }
    let mut end = budget;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}
