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
}
