import Foundation

public enum ReplySyntheticFixture {
    public static let message = MailInput(
        messageRef: "synthetic-question",
        subject: "Example project question",
        body: "Synthetic email from colleague@example.com: Could you confirm receipt of the example project brief? Please reply with an acknowledgement. This is test data."
    )
    public static let draft = Data(#"{"schema_version":1,"request_id":"synthetic-question-draft","triage_request_id":"synthetic-question-triage","message_ref":"synthetic-question","subject":"Re: Example project question","body":"Thank you. I confirm receipt of the example project brief."}"#.utf8)
}
