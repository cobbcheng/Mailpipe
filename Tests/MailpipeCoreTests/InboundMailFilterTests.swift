import XCTest
@testable import MailpipeCore

final class InboundMailFilterTests: XCTestCase {
    private let automaticSender = "no-reply@example.com"
    private let listHeaders = ["List-Unsubscribe": ["<mailto:unsubscribe@example.com>"]]

    private func skips(_ subject: String, from sender: String? = nil, headers: [String: [String]] = [:]) -> Bool {
        InboundMailFilter.shouldSkip(subject: subject, sender: sender, headers: headers)
    }

    func testTopLevelProtocolReportsAndAutomaticReplies() {
        let delivery = ["cOnTeNt-TyPe": ["multipart/report; boundary=sample; report-type=\"delivery-status\""]]
        XCTAssertTrue(skips("Delivery failed", headers: delivery))
        XCTAssertFalse(skips("Fwd: Delivery failed", from: "colleague@example.com", headers: [
            "Content-Type": ["message/rfc822"]
        ]))
        XCTAssertFalse(skips("Delivery failed", headers: [
            "Content-Type": ["multipart/mixed; boundary=\"delivery-status\""]
        ]))

        let vacation = ["AUTO-SUBMITTED": ["auto-replied"], "In-Reply-To": ["<ticket@example.com>"]]
        XCTAssertTrue(skips("Out of office", headers: vacation))
        XCTAssertFalse(skips("Fwd: Out of office", from: "colleague@example.com", headers: vacation))
        XCTAssertFalse(skips("Out of office", headers: ["Auto-Submitted": ["no", "auto-replied"]]))
        XCTAssertFalse(skips("Out of office", headers: ["Auto-Submitted": ["auto-replied-later"]]))
    }

    func testMachineSenderAndNarrowNotificationTemplateAreBothRequired() {
        for subject in ["您的登录验证码为 123456", "Your verification code is 123456", "Verification code: 123456", "您的订单已发货",
                        "Your order has shipped", "New sign-in to your account"] {
            XCTAssertTrue(skips(subject, from: automaticSender), subject)
            XCTAssertFalse(skips(subject, from: "customer@example.com"), subject)
        }
        XCTAssertTrue(skips("您的订单已发货", headers: ["Auto-Submitted": ["auto-generated"]]))
        XCTAssertFalse(skips("您的登录验证码为 123456", from: "no-reply@example.com, customer@example.com"))
        XCTAssertFalse(skips("我为什么收不到登录验证码？", from: automaticSender))
        XCTAssertFalse(skips("Your order has shipped. Can you confirm the new address?", from: automaticSender))
    }

    func testCampaignNeedsBothASaleSubjectAndBulkEvidence() {
        for subject in ["会员专享，全场七折", "限时抢购：全场 5 折", "Save 20% today", "20% off sitewide", "Flash sale: 30% off"] {
            XCTAssertTrue(skips(subject, from: "offers@example.com", headers: listHeaders), subject)
            XCTAssertFalse(skips(subject, from: "offers@example.com"), subject)
        }
        XCTAssertTrue(skips("Save 20% today", headers: ["Precedence": ["bulk"]]))
        XCTAssertTrue(skips("Save 20% today", headers: ["LIST-UNSUBSCRIBE": [
            "<https://example.com/opt-out>,\r\n <mailto:unsubscribe@example.com>"
        ]]))
        XCTAssertFalse(skips("Save 20% today", headers: ["List-Unsubscribe": ["contact our support team"]]))
        XCTAssertFalse(skips("Save 20% today", headers: ["List-Id": ["Team updates <team.example.com>"]]))
        XCTAssertFalse(skips("团队周报", headers: listHeaders))
        XCTAssertFalse(skips("你对这个报价怎么看？", headers: listHeaders))
    }

    func testBroadcastNewslettersProductUpdatesAndSeasonalOffers() {
        let subjects = [
            "Here’s your February newsletter", "Your weekly newsletter", "本週產品簡報",
            "What’s new in Sample Studio",
            "🗓️ Sample Black Friday starts tomorrow", "Black Friday savings start today"
        ]
        for subject in subjects {
            XCTAssertTrue(skips(subject, from: "hello@example.com", headers: listHeaders), subject)
            XCTAssertTrue(skips(subject, from: "News@example.com"), subject)
            XCTAssertFalse(skips(subject, from: "person@example.com"), subject)
        }
        XCTAssertFalse(skips("Your weekly newsletter", from: "Newsletter <editor@example.com>"))
        XCTAssertFalse(skips("Your weekly newsletter", from: "news+team@example.com"))
        XCTAssertFalse(skips("Important update", from: "newsletter@example.com", headers: listHeaders))
        XCTAssertFalse(skips("去海边还是上山？选择旅行目的地", headers: listHeaders))
    }

    func testPaymentReceiptsRequireAutomationAndClosedPaymentWording() {
        let service = ["Auto-Submitted": ["auto-generated"]]
        for subject in ["Payment received", "Your payment receipt", "付款成功"] {
            XCTAssertTrue(skips(subject, from: "billing@example.com", headers: service), subject)
            XCTAssertTrue(skips(subject, from: automaticSender), subject)
            XCTAssertFalse(skips(subject, from: "billing@example.com"), subject)
        }
        for subject in ["Customer invoice", "Invoice overdue", "Please confirm payment", "Payment received?"] {
            XCTAssertFalse(skips(subject, from: automaticSender, headers: service), subject)
        }
    }

    func testBroadcastEvidenceDoesNotOverrideRequestsOrConversationHeaders() {
        for subject in [
            "What’s new in Sample Studio: could you review this",
            "What’s new in Sample Studio: feedback requested",
            "What’s new in Sample Studio: send me your estimate",
            "Re: Your monthly newsletter", "轉寄：本週產品簡報"
        ] {
            XCTAssertFalse(skips(subject, from: "news@example.com", headers: listHeaders), subject)
        }
        for conflict in [["Reply-To": ["editor@example.com"]], ["Auto-Submitted": ["no"]],
                         ["In-Reply-To": ["<person@example.com>"]], ["References": ["<thread@example.com>"]]] {
            XCTAssertFalse(skips("Your monthly newsletter", from: "newsletter@example.com",
                                 headers: conflict.merging(listHeaders) { first, _ in first }))
        }
    }

    func testForwardsDiscussionsAndTicketMessagesContinue() {
        for subject in ["转发：会员专享，全场七折", "Fwd: Save 20% today", "Re: 20% off sitewide"] {
            XCTAssertFalse(skips(subject, from: "colleague@example.com", headers: listHeaders), subject)
        }
        var discussion = listHeaders
        discussion["References"] = ["<discussion@example.com>"]
        XCTAssertFalse(skips("会员专享，全场七折", headers: discussion))

        let service = ["Auto-Submitted": ["auto-generated"]]
        XCTAssertFalse(skips("工单更新：客户询问发货时间", from: automaticSender, headers: service))
        XCTAssertFalse(skips("Payment failed — approval required", from: automaticSender, headers: service))
        XCTAssertFalse(skips("Re: 您的登录验证码为 123456", from: automaticSender, headers: service))
        XCTAssertFalse(skips("请确认", headers: ["Auto-Submitted": ["auto-replied"]]))
        XCTAssertFalse(skips("Your order has shipped", from: automaticSender,
                             headers: ["Reply-To": ["seller@example.com"]]))
    }

    func testMissingAmbiguousAndUnrelatedEvidenceContinues() {
        XCTAssertFalse(skips("您的登录验证码为 123456"))
        XCTAssertFalse(skips("通知", from: automaticSender))
        XCTAssertFalse(skips("Newsletter", headers: ["List-Id": ["Team updates <team.example.com>"]]))
        XCTAssertFalse(skips("Returned mail", headers: [
            "Content-Type": ["multipart/report; report-type=delivery-status", "text/plain"]
        ]))
        XCTAssertFalse(skips("Mail delivery", headers: [
            "Auto-Submitted": ["no"], "auto-submitted": ["auto-replied"]
        ]))
        XCTAssertFalse(skips("Save 20% today", headers: [
            "X-Original-List-Unsubscribe": ["<mailto:unsubscribe@example.com>"]
        ]))
    }

    func testPrefixedNoReplyBroadcastsAndProductOnboardingSkipSafely() {
        let prefixed = "service-noreply@example.com"
        let commaUnsubscribe = ["List-Unsubscribe": ["<https://example.com/opt-out?a=1,2>, <mailto:unsubscribe@example.com>"]]

        XCTAssertTrue(skips("开始使用 Sample Pro 方案中的助手应用", from: prefixed, headers: commaUnsubscribe))
        XCTAssertTrue(skips("开始使用 Sample Pro 方案中的助手应用", from: prefixed))
        XCTAssertTrue(skips("Get started with Sample Cloud", from: "noreply-cloud@example.com"))
        XCTAssertTrue(skips("Welcome to Sample Studio", from: "hello@example.com", headers: listHeaders))
        XCTAssertTrue(skips("解锁更多云端空间", from: prefixed, headers: commaUnsubscribe))
        XCTAssertTrue(skips("Unlock new workspace features", from: "billing.no_reply@example.com", headers: [
            "Precedence": ["bulk"],
            "Reply-To": [prefixed]
        ]))

        // Human senders, replyable addresses, notifications, and actionable alerts continue.
        XCTAssertFalse(skips("开始使用 Sample Pro 方案中的助手应用", from: "colleague@example.com"))
        XCTAssertFalse(skips("Welcome to the team", from: "manager@example.com"))
        XCTAssertFalse(skips("开始使用新方案前请确认账户信息", from: prefixed, headers: listHeaders))
        XCTAssertFalse(skips("开始使用新方案了吗？", from: prefixed, headers: listHeaders))
        XCTAssertFalse(skips("解锁更多云端空间", from: prefixed, headers: [
            "List-Unsubscribe": ["<mailto:unsubscribe@example.com>"],
            "Reply-To": ["support@example.com"]
        ]))
        XCTAssertFalse(skips("New comment on roadmap", from: "notifications@example.com", headers: listHeaders))
        XCTAssertFalse(skips("解锁更多云端空间", from: "service-noreply+team@example.com", headers: listHeaders))
        for alert in ["Invoice overdue", "Customer invoice", "Payment failed", "账单已逾期", "安全警报：异常登录"] {
            XCTAssertFalse(skips(alert, from: prefixed, headers: listHeaders), alert)
        }
    }
}
