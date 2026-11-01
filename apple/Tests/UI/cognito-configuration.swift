import Foundation

@main struct CognitoConfigurationCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let apple = try Data(contentsOf: root.appendingPathComponent("apple/Sources/Logseq/Resources/logseq-auth.json"))
        let android = try Data(contentsOf: root.appendingPathComponent("android/app/src/main/res/raw/logseq_auth.json"))
        let values = try JSONSerialization.jsonObject(with: apple) as! [String: String]
        let androidValues = try JSONSerialization.jsonObject(with: android) as! [String: String]
        precondition(values == androidValues)
        precondition(values["region"] == "us-east-1")
        precondition(values["appClientId"]?.isEmpty == false)
        precondition(values["oauthDomain"] == nil)
        print("Verified matching public Cognito clients without Hosted UI configuration")
    }
}
