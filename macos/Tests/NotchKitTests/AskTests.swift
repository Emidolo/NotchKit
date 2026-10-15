import Testing
@testable import NotchKit

@Test func readsTextFromStreamedLines() {
    #expect(Ask.delta(in: #"data: {"choices":[{"index":0,"delta":{"content":"Hel\"lo\n"}}]}"#) == "Hel\"lo\n")
    #expect(Ask.delta(in: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
    #expect(Ask.delta(in: #"data: {"choices":[]}"#) == nil)
    #expect(Ask.delta(in: "data: [DONE]") == nil)
    #expect(Ask.delta(in: "") == nil)
    #expect(Ask.delta(in: ": keep-alive") == nil)
}

@Test func explainsErrorResponses() {
    #expect(Ask.errorMessage(in: #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#, status: 401) == "Incorrect API key provided")
    #expect(Ask.errorMessage(in: "<html>", status: 502) == "OpenAI answered with status 502")
}
