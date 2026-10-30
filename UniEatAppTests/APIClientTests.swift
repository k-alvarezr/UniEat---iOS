import XCTest
@testable import UniEat

@MainActor
final class APIClientTests: XCTestCase {
    func testIdentityChangeWhileObtainingTokenCancelsBeforeSending() async {
        var identity = UUID()
        let api = APIClient(configuration: AppConfiguration(supabaseURL: "https://example.invalid", publishableKey: "test"),
            sessionIdentity: { identity }) {
                identity = UUID()
                return "test-token"
            }
        do {
            let _: FeedResponse = try await api.get("feed")
            XCTFail("A response for another identity must never be applied")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation before any network request, got \(error)") }
    }

    func testUnauthorizedResponseNotifiesSessionOwnerAndPreservesServerError() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnauthorizedProtocol.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        let api = APIClient(configuration: AppConfiguration(supabaseURL: "https://example.invalid", publishableKey: "test"),
            session: transport) { "test-token" }
        var invalidated = false
        api.onUnauthorized = { invalidated = true }
        do {
            let _: FeedResponse = try await api.get("feed")
            XCTFail("Must fail with AUTH_REQUIRED")
        } catch let failure as APIFailure { XCTAssertEqual(failure.code, "AUTH_REQUIRED") }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(invalidated)
    }
}

private final class UnauthorizedProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"error\":{\"code\":\"AUTH_REQUIRED\",\"message\":\"Inicia sesión\"}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
