import Foundation

public enum ReplySyntheticFixture {
    public static let triage = ReplyTriageRequest(requestID: "synthetic-triage", message: MailInput(
        messageRef: "synthetic-question", subject: "Example project question",
        body: "Synthetic email from colleague@example.com: Could you confirm receipt of the example project brief? Please reply with an acknowledgement. This is test data."))
    public static let decision = Data(#"{"schema_version":1,"request_id":"synthetic-triage","message_ref":"synthetic-question","should_reply":"yes","category":"other","needs_action":"yes","summary":["A colleague requests acknowledgement."],"evidence":[{"field":"body","text":"Please reply with an acknowledgement."}]}"#.utf8)
    public static let draft = Data(#"{"schema_version":1,"request_id":"synthetic-draft","triage_request_id":"synthetic-triage","message_ref":"synthetic-question","subject":"Re: Example project question","body":"Thank you. I confirm receipt of the example project brief."}"#.utf8)
}
