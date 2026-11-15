import Foundation

/// Fixed, public, synthetic-only payload. No user-controlled email can enter a probe.
public enum SyntheticFixture {
    public static let request = ClassificationRequest(requestID: "mailpipe-m0-synthetic-v1", messages: [
        MailInput(messageRef: "synthetic-invoice", subject: "Example invoice",
                  body: "Synthetic invoice from shop@example.com. No payment is required. This is test data.")
    ])
    public static let response = Data(#"""
    {"schema_version":1,"request_id":"mailpipe-m0-synthetic-v1","results":[{"message_ref":"synthetic-invoice","category":"billing","needs_action":"no","summary":["A synthetic invoice requiring no payment."],"evidence":[{"field":"subject","text":"Example invoice"}]}]}
    """#.utf8)
}
