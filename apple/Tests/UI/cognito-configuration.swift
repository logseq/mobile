import Foundation

@main struct CognitoConfigurationCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: root.appendingPathComponent("apple/Sources/Logseq/Resources/logseq-auth.json"))
        let values = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let configuration = CognitoOAuthConfiguration(
            domain: values["oauthDomain"] as! String,
            clientID: values["appClientId"] as! String,
            redirectURI: values["redirectURI"] as! String,
            logoutURI: values["logoutURI"] as! String,
            scopes: values["scopes"] as! [String]
        )
        // These native callbacks are registered on the production Cognito client.
        precondition(configuration.redirectURI == "logseq://auth/callback", "Unregistered Cognito callback")
        precondition(configuration.logoutURI == "logseq://auth/logout", "Unregistered Cognito logout")
        let url = try CognitoOAuthRequest.authorizationURL(configuration: configuration, state: "state", codeChallenge: "challenge")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.first { $0.name == "redirect_uri" }?.value == configuration.redirectURI)
        let infoData = try Data(contentsOf: root.appendingPathComponent("apple/App/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as! [String: Any]
        let schemes = (info["CFBundleURLTypes"] as! [[String: Any]]).flatMap { $0["CFBundleURLSchemes"] as! [String] }
        precondition(schemes.contains(URL(string: configuration.redirectURI)!.scheme!), "App cannot receive Cognito callback")
        print("Verified registered Cognito callbacks and app URL scheme")
    }
}
