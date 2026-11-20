import Foundation

/// Pure admission rule for automatic MailKit capture. Only outer message fields are inputs.
public enum InboundMailFilter {
    public static let requiredHeaders = [
        "Auto-Submitted", "Content-Type", "In-Reply-To", "References", "Reply-To",
        "List-Unsubscribe", "Precedence"
    ]

    public static func shouldSkip(subject: String, sender: String?, headers: [String: [String]]) -> Bool {
        guard subject.utf8.count <= MailBodyLimits.maxHeaderBytes,
              let fields = singleValues(headers) else { return false }
        let title = MailHeaderCodec.decodeEncodedWords(subject).precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty, !title.contains(where: \.isNewline), !title.contains("?"),
              !matches(title, #"^(?:re|回复|回覆|fw|fwd|转发|轉寄|轉發)\s*:"#),
              !matches(title, replyRequest)
        else { return false }

        // An explicit human submission, unsupported keyword or malformed value is ambiguous.
        var automatic: String?
        if let header = fields["auto-submitted"] {
            guard let parsed = parameterized(header),
                  ["auto-replied", "auto-generated"].contains(parsed.name) else { return false }
            automatic = parsed.name
        }
        if let replyTo = fields["reply-to"], !isMachineAddress(replyTo) { return false }

        // Reports and out-of-office replies often legitimately carry thread headers.
        if automatic == "auto-replied" { return true }
        if let contentType = fields["content-type"], let media = parameterized(contentType),
           media.name == "multipart/report", media.parameters["report-type"] == "delivery-status" {
            return true
        }

        guard fields["in-reply-to"] == nil, fields["references"] == nil else { return false }
        if (automatic == "auto-generated" || isMachineAddress(sender)),
           systemTitles.contains(title) || matches(title, verificationCode) {
            return true
        }
        let bulk = fields["precedence"] == "bulk" || fields["precedence"] == "list"
        let broadcast = bulk || hasUnsubscribeLinks(fields["list-unsubscribe"]) ||
            mailbox(sender, localPartMatching: #"news|newsletters?"#)
        return broadcast && campaignTitles.contains { matches(title, $0) }
    }

    private static let systemTitles: Set<String> = [
        "登录成功", "账户登录成功", "您的账户登录成功", "您的订单已发货", "订单已发货",
        "your order has shipped", "new sign-in to your account", "successful sign-in",
        "payment received", "payment confirmation", "invoice payment confirmation",
        "payment receipt", "your payment receipt", "your payment was successful",
        "支付成功", "付款成功", "付款回执", "付款收據", "付款收据"
    ]

    private static let verificationCode =
        #"^(?:(?:您的)?(?:登录|邮箱|身份验证)?验证码\s*(?:为|是|:)\s*|(?:your )?(?:verification|sign-in|login) code(?: is |:\s*))[0-9]{4,8}[.。]?$"#
    private static let replyRequest =
        #"工单|工單|客[户戶](?:提[问問]|[询詢][问問]|回复|回覆|留言)|[请請](?:您)?(?:回复|回覆|审批|審批|[确確][认認])|\b(?:ticket|customer (?:question|reply|message)|please|(?:could|can|would|will) you|(?:need|awaiting) your|(?:reply|response|feedback|approval|confirmation|action) (?:required|requested|needed))\b"#

    private static let campaignTitles = [
        #"^(?:会员专享|限时优惠|限时抢购)\s*[,!:]\s*全场\s*(?:[一二三四五六七八九]{1,2}|[1-9](?:\.[0-9])?)\s*折[!.。]?$"#,
        #"^save [1-9][0-9]?% (?:today|sitewide)[!.]?$"#,
        #"^[1-9][0-9]?% off (?:sitewide|everything)[!.]?$"#,
        #"^flash sale:\s*[1-9][0-9]?% off[!.]?$"#,
        #"^(?:(?:here['’]s )?your )?(?:daily|weekly|monthly|january|february|march|april|may|june|july|august|september|october|november|december) (?:newsletter|digest)[!.]?$"#,
        #"^what['’]s new (?:on|in|at|from) [\p{L}\p{N}][\p{L}\p{N}&.+-]*(?: [\p{L}\p{N}&.+-]+){0,3}[!.]?$"#,
        #"^(?:\p{So}\uFE0F?\s*)?(?:[\p{L}\p{N}&-]+ ){0,2}(?:black friday|cyber monday) (?:savings |deals |sale )?starts? (?:today|tomorrow|now|soon|this (?:week|weekend|friday))[!.]?$"#,
        #"^(?:本周|本週|本月|每周|每週|每月)(?:产品|產品|订阅|訂閱)(?:简报|簡報|通讯|通訊)[!。]?$"#
    ]

    private static func hasUnsubscribeLinks(_ header: String?) -> Bool {
        guard let header else { return false }
        return header.components(separatedBy: ",").allSatisfy { item in
            let link = item.trimmingCharacters(in: .whitespaces)
            guard link.first == "<", link.last == ">" else { return false }
            let target = link.dropFirst().dropLast()
            guard !target.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }),
                  let url = URLComponents(string: String(target)) else { return false }
            switch url.scheme {
            case "http", "https": return url.host?.isEmpty == false
            case "mailto": return matches(url.path, #"^[^@\s]+@[^@\s]+$"#)
            default: return false
            }
        }
    }

    /// MailKit provides the outer sender mailbox separately. Display-name text is never evidence.
    private static func isMachineAddress(_ value: String?) -> Bool {
        mailbox(value, localPartMatching: #"no[-_.]?reply|do[-_.]?not[-_.]?reply|notifications?"#)
    }

    private static func mailbox(_ value: String?, localPartMatching pattern: String) -> Bool {
        guard let value, value.utf8.count <= 254 else { return false }
        return matches(value.lowercased(), #"\A(?:\#(pattern))@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z"#)
    }

    /// Duplicates, including differently cased spellings of one field, cannot corroborate a decision.
    private static func singleValues(_ headers: [String: [String]]) -> [String: String]? {
        var fields: [String: String] = [:]
        for (key, values) in headers {
            let name = key.lowercased()
            guard fieldNames.contains(name) else { continue }
            guard fields[name] == nil, values.count == 1,
                  let value = values.first, value.utf8.count <= MailBodyLimits.maxHeaderBytes else { return nil }
            let unfolded = value.replacingOccurrences(of: #"\r?\n[ \t]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard !unfolded.isEmpty, unfolded.rangeOfCharacter(from: .newlines) == nil else { return nil }
            fields[name] = unfolded
        }
        return fields
    }

    private static let fieldNames = Set(requiredHeaders.map { $0.lowercased() })

    /// Accept simple token and quoted parameters. Unsupported syntax leaves the signal unavailable.
    private static func parameterized(_ value: String) -> (name: String, parameters: [String: String])? {
        let parts = value.components(separatedBy: ";")
        guard let first = parts.first else { return nil }
        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            let raw = pair[1].trimmingCharacters(in: .whitespaces)
            guard matches(key, #"^[a-z0-9_-]+$"#), parameters[key] == nil,
                  matches(raw, #"^(?:"[^"\\]*"|[a-z0-9!#$%&'*+.^_`|~-]+)$"#) else { return nil }
            parameters[key] = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return (first.trimmingCharacters(in: .whitespaces), parameters)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
