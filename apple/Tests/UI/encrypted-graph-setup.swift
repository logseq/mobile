import Foundation
import LogseqModel
import CryptoKit
import Darwin

@main struct EncryptedGraphSetupCheck {
    @MainActor static func main() async throws {
        func call(_ action: String, _ payload: String? = nil) throws -> LogseqRPCResponse {
            let source = LogseqStore.callForLaunch(LogseqRPCRequest(
                method: "dispatch", params: LogseqRPCParams(action: action, payload: payload)))
            return try JSONDecoder().decode(LogseqRPCResponse.self, from: Data(source.utf8))
        }
        _ = LogseqStore.callForLaunch(LogseqRPCRequest(method: "open", params: LogseqRPCParams(
            action: nil, path: URL.documentsDirectory.appendingPathComponent("encryption.sqlite").path)))
        let config = #"{"baseUrl":"__SELF_HOSTED_BASE_URL__","graphId":"","token":"fixture-token"}"#
        let configured = try call("configure", config)
        precondition(configured.ok)
        let first = try call("createSyncGraph", #"{"name":"Private","isEncrypted":true}"#)
        precondition(first.error?.code == "e2ee_password_required",
                     "First encrypted graph must request setup before creating anything: \(String(describing: first.error))")
        let blank = try call("createSyncGraph", #"{"name":"Private","isEncrypted":true,"password":"   "}"#)
        precondition(blank.error?.code == "e2ee_password_required", "Blank passwords must not initialize encryption")
        for token in ["fixture-denied", "fixture-malformed", "fixture-upload-failure"] {
            let failureConfig = config.replacingOccurrences(of: "fixture-token", with: token)
            let configured = try call("configure", failureConfig)
            precondition(configured.ok)
            let rejected = try call("createSyncGraph", #"{"name":"Private","isEncrypted":true,"password":"correct horse battery staple"}"#)
            precondition(rejected.error?.code == "e2ee_user_keys_failed",
                         "Account key errors must stop before graph creation: \(String(describing: rejected.error))")
        }
        let reconfigured = try call("configure", config)
        precondition(reconfigured.ok)
        let created = try call("createSyncGraph", #"{"name":"Private","isEncrypted":true,"password":"correct horse battery staple"}"#)
        precondition(created.ok && created.result?.isGraphUnlocked == true,
                     "First encrypted graph must initialize account keys and provision its key: \(String(describing: created.error))")
        try await checkEncryptedAssetDownloads(graphID: "graph-0")
        let second = try call("createSyncGraph", #"{"name":"Second","isEncrypted":true}"#)
        precondition(second.ok, "Existing account keys must be reused without a new password")
        let plain = try call("createSyncGraph", #"{"name":"Plain","isEncrypted":false}"#)
        precondition(plain.ok, "Plain graphs must keep working")
        print("PASS: encrypted creation initializes account keys once and reuses them")
    }

    @MainActor static func checkEncryptedAssetDownloads(graphID: String) async throws {
        let request = #"{"operation":"loadGraphKey","graphID":"\#(graphID)"}"#
        typealias CryptoJSON = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
        guard let library = dlopen(nil, RTLD_NOW) else { throw URLError(.cannotDecodeContentData) }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "logseq_crypto_json") else { throw URLError(.cannotDecodeContentData) }
        let crypto = unsafeBitCast(symbol, to: CryptoJSON.self)
        let pointer = request.withCString { crypto($0) }
        guard let pointer else { throw URLError(.cannotDecodeContentData) }
        let keyResponse = Data(String(cString: pointer).utf8)
        free(pointer)
        let fields = try JSONSerialization.jsonObject(with: keyResponse) as! [String: Any]
        guard let hex = fields["value"] as? String else {
            throw NSError(domain: "EncryptedAssetCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Created graph key is unavailable"])
        }
        let digits = Array(hex.utf8)
        var rawKey = Data()
        for index in stride(from: 0, to: digits.count, by: 2) {
            rawKey.append(UInt8(String(bytes: digits[index...index + 1], encoding: .utf8)!, radix: 16)!)
        }
        let key = SymmetricKey(data: rawKey)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousDirectory = FileManager.default.currentDirectoryPath
        precondition(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(previousDirectory)
            try? FileManager.default.removeItem(at: directory)
        }

        func cache(_ envelope: Data) async throws -> [String: Any] {
            let source = directory.appendingPathComponent(UUID().uuidString)
            try envelope.write(to: source)
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
                "uuid": UUID().uuidString.lowercased(), "assetType": "png",
                "graphId": graphID, "path": source.path
            ]), as: UTF8.self)
            let encoded = await LogseqCore.callAsync(LogseqRPCRequest(method: "dispatch",
                params: LogseqRPCParams(action: "cacheDownloadedAsset", payload: payload)))
            return try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as! [String: Any]
        }

        for size in [0, 1, 65_536, 4_194_304, 4_194_304, 4_194_304] {
            let plaintext = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            let sealed = try AES.GCM.seal(plaintext, using: key)
            let iv = Data(sealed.nonce)
            let ciphertext = sealed.ciphertext + sealed.tag
            let envelope = try JSONSerialization.data(withJSONObject: [
                "~b" + iv.base64EncodedString(), "~b" + ciphertext.base64EncodedString()
            ])
            let result = try await cache(envelope)
            guard result["ok"] as? Bool == true else {
                throw NSError(domain: "EncryptedAssetCheck", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Encrypted asset download failed: \(result)"])
            }
            let cached = (result["result"] as! [String: Any])["localPath"] as! String
            let cachedBytes = try Data(contentsOf: URL(fileURLWithPath: cached))
            precondition(cachedBytes == plaintext,
                         "Downloaded bytes must match after native decryption")
            print("PASS: native encrypted asset download \(size) bytes")
        }
        let rejected = try await cache(Data("not an encrypted asset".utf8))
        precondition(rejected["ok"] as? Bool == false, "Malformed assets must return an error")
        let sealed = try AES.GCM.seal(Data("authenticated asset".utf8), using: key)
        var corrupted = sealed.ciphertext + sealed.tag
        corrupted[corrupted.count - 1] ^= 1
        let tampered = try JSONSerialization.data(withJSONObject: [
            "~b" + Data(sealed.nonce).base64EncodedString(), "~b" + corrupted.base64EncodedString()
        ])
        let denied = try await cache(tampered)
        precondition(denied["ok"] as? Bool == false, "Tampered assets must return an authentication error")
        print("PASS: malformed and tampered encrypted assets fail without crashing")
    }
}
