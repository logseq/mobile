#if LOGSEQ_CORE && os(iOS)
import CommonCrypto
import CryptoKit
import Foundation
import Security

private enum E2EECryptoError: Error {
    case invalidRequest(String)
    case crypto(String)
}

private struct DERReader {
    let bytes: [UInt8]
    var offset = 0

    mutating func element(tag expectedTag: UInt8) throws -> Data {
        guard offset < bytes.count, bytes[offset] == expectedTag else {
            throw E2EECryptoError.crypto("invalid PKCS8 DER tag")
        }
        offset += 1
        let length = try readLength()
        guard length >= 0, offset + length <= bytes.count else {
            throw E2EECryptoError.crypto("invalid PKCS8 DER length")
        }
        let result = Data(bytes[offset..<(offset + length)])
        offset += length
        return result
    }

    private mutating func readLength() throws -> Int {
        guard offset < bytes.count else {
            throw E2EECryptoError.crypto("missing PKCS8 DER length")
        }
        let first = bytes[offset]
        offset += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7f)
        guard count > 0, count <= MemoryLayout<Int>.size, offset + count <= bytes.count else {
            throw E2EECryptoError.crypto("invalid PKCS8 DER long length")
        }
        var result = 0
        for _ in 0..<count {
            result = (result << 8) | Int(bytes[offset])
            offset += 1
        }
        return result
    }
}

private enum E2EECrypto {
    static let keychainService = "com.logseq.logseq.e2ee.graph-key"
    static let passwordKeychainService = "com.logseq.logseq.e2ee.password"
    static let passwordKeychainAccount = "current-account"

    static func hexData(_ value: Any?, field: String) throws -> Data {
        guard let text = value as? String, text.count.isMultiple(of: 2) else {
            throw E2EECryptoError.invalidRequest("invalid \(field)")
        }
        var result = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<end], radix: 16) else {
                throw E2EECryptoError.invalidRequest("invalid \(field)")
            }
            result.append(byte)
            index = end
        }
        return result
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int) throws -> Data {
        guard iterations > 0 else { throw E2EECryptoError.invalidRequest("invalid iterations") }
        guard let rounds = UInt32(exactly: iterations) else {
            throw E2EECryptoError.invalidRequest("invalid iterations")
        }
        var result = Data(count: 32)
        let status = result.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        output.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw E2EECryptoError.crypto("PBKDF2 failed") }
        return result
    }

    static func der(_ tag: UInt8, _ contents: Data) -> Data {
        var length = contents.count
        if length < 128 { return Data([tag, UInt8(length)]) + contents }
        var bytes: [UInt8] = []
        while length > 0 {
            bytes.insert(UInt8(length & 0xff), at: 0)
            length >>= 8
        }
        return Data([tag, 0x80 | UInt8(bytes.count)] + bytes) + contents
    }

    static func generateRSAKeyPair() throws -> (Data, Data) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 4096]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let privateData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data?,
              let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            if let error { throw error.takeRetainedValue() }
            throw E2EECryptoError.crypto("RSA key generation failed")
        }
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        let spki = der(0x30, algorithm + der(0x03, Data([0]) + publicData))
        let pkcs8 = der(0x30, Data([0x02, 0x01, 0x00]) + algorithm + der(0x04, privateData))
        return (spki, pkcs8)
    }

    static func aesOpen(key: Data, iv: Data, ciphertextAndTag: Data) throws -> Data {
        guard key.count == 32, iv.count == 12, ciphertextAndTag.count >= 16 else {
            throw E2EECryptoError.crypto("invalid AES-GCM input")
        }
        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    static func aesSeal(key: Data, plaintext: Data) throws -> (Data, Data) {
        guard key.count == 32 else { throw E2EECryptoError.crypto("invalid AES-GCM key") }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        return (nonce, sealed.ciphertext + sealed.tag)
    }

    static func unwrapPKCS8(_ data: Data) throws -> Data {
        var outer = DERReader(bytes: [UInt8](data))
        let sequence = try outer.element(tag: 0x30)
        var contents = DERReader(bytes: [UInt8](sequence))
        _ = try contents.element(tag: 0x02)
        _ = try contents.element(tag: 0x30)
        return try contents.element(tag: 0x04)
    }

    static func unwrapSPKI(_ data: Data) throws -> Data {
        var outer = DERReader(bytes: [UInt8](data))
        let sequence = try outer.element(tag: 0x30)
        var contents = DERReader(bytes: [UInt8](sequence))
        _ = try contents.element(tag: 0x30)
        let bitString = try contents.element(tag: 0x03)
        guard bitString.first == 0 else {
            throw E2EECryptoError.crypto("invalid SPKI bit string")
        }
        return bitString.dropFirst()
    }

    static func rsaOAEPDecrypt(privateKeyData: Data, ciphertext: Data) throws -> Data {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        let externalKeyData = (try? unwrapPKCS8(privateKeyData)) ?? privateKeyData
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(
            externalKeyData as CFData,
            attributes as CFDictionary,
            &error
        )
        guard let key else {
            if let error { throw error.takeRetainedValue() }
            throw E2EECryptoError.crypto("invalid RSA private key")
        }
        let blockSize = SecKeyGetBlockSize(key)
        guard ciphertext.count == blockSize else {
            throw E2EECryptoError.crypto(
                "invalid RSA ciphertext size: expected \(blockSize), got \(ciphertext.count)"
            )
        }
        error = nil
        guard let plaintext = SecKeyCreateDecryptedData(
            key,
            .rsaEncryptionOAEPSHA256,
            ciphertext as CFData,
            &error
        ) else {
            if let error {
                print(
                    "Logseq E2EE RSA-OAEP decrypt failed "
                        + "privateKeyBytes=\(privateKeyData.count) "
                        + "externalKeyBytes=\(externalKeyData.count) "
                        + "ciphertextBytes=\(ciphertext.count) "
                        + "blockBytes=\(blockSize) error=\(error.takeRetainedValue())"
                )
            }
            throw E2EECryptoError.crypto("RSA-OAEP decrypt failed")
        }
        return plaintext as Data
    }

    static func rsaOAEPEncrypt(publicKeyData: Data, plaintext: Data) throws -> Data {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        let externalKeyData = (try? unwrapSPKI(publicKeyData)) ?? publicKeyData
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(
            externalKeyData as CFData,
            attributes as CFDictionary,
            &error
        )
        guard let key else {
            if let error { throw error.takeRetainedValue() }
            throw E2EECryptoError.crypto("invalid RSA public key")
        }
        error = nil
        guard let ciphertext = SecKeyCreateEncryptedData(
            key,
            .rsaEncryptionOAEPSHA256,
            plaintext as CFData,
            &error
        ) else {
            if let error { throw error.takeRetainedValue() }
            throw E2EECryptoError.crypto("RSA-OAEP encrypt failed")
        }
        return ciphertext as Data
    }

    static func randomBytes(count: Int) throws -> Data {
        guard count > 0 else { throw E2EECryptoError.invalidRequest("invalid byte count") }
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw E2EECryptoError.crypto("secure random generation failed")
        }
        return Data(bytes)
    }

    static func keychainQuery(graphID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: graphID,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    static func saveKey(graphID: String, key: Data) throws {
        var query = keychainQuery(graphID: graphID)
        let update = [kSecValueData: key] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            query[kSecValueData] = key
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw E2EECryptoError.crypto("Keychain save failed: \(addStatus)")
            }
        } else if status != errSecSuccess {
            throw E2EECryptoError.crypto("Keychain update failed: \(status)")
        }
    }

    static func loadKey(graphID: String) throws -> Data? {
        var query = keychainQuery(graphID: graphID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw E2EECryptoError.crypto("Keychain load failed: \(status)")
        }
        return data
    }

    static func passwordQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: passwordKeychainService,
            kSecAttrAccount: passwordKeychainAccount,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    static func savePassword(_ password: Data) throws {
        var query = passwordQuery()
        let update = [kSecValueData: password] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            query[kSecValueData] = password
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw E2EECryptoError.crypto("E2EE password save failed: \(addStatus)")
            }
        } else if status != errSecSuccess {
            throw E2EECryptoError.crypto("E2EE password update failed: \(status)")
        }
    }

    static func loadPassword() throws -> Data? {
        var query = passwordQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw E2EECryptoError.crypto("E2EE password load failed: \(status)")
        }
        return data
    }

    static func handle(_ request: [String: Any]) throws -> [String: Any] {
        guard let operation = request["operation"] as? String else {
            throw E2EECryptoError.invalidRequest("missing operation")
        }
        switch operation {
        case "generateRSAKeyPair":
            let (publicKey, privateKey) = try generateRSAKeyPair()
            return ["ok": true, "publicKey": hex(publicKey), "privateKey": hex(privateKey)]

        case "encryptPrivateKey":
            guard let password = request["password"] as? String else {
                throw E2EECryptoError.invalidRequest("missing password")
            }
            let salt = try randomBytes(count: 16)
            let derived = try pbkdf2SHA256(password: Data(password.utf8), salt: salt, iterations: 600000)
            let (iv, ciphertext) = try aesSeal(key: derived,
                plaintext: hexData(request["privateKey"], field: "privateKey"))
            return ["ok": true, "salt": hex(salt), "iv": hex(iv), "ciphertext": hex(ciphertext)]

        case "decryptPrivateKey":
            guard let password = request["password"] as? String,
                  let iterations = request["iterations"] as? Int
            else { throw E2EECryptoError.invalidRequest("invalid private key request") }
            let derived = try pbkdf2SHA256(
                password: Data(password.utf8),
                salt: try hexData(request["salt"], field: "salt"),
                iterations: iterations
            )
            let plaintext = try aesOpen(
                key: derived,
                iv: try hexData(request["iv"], field: "iv"),
                ciphertextAndTag: try hexData(request["ciphertext"], field: "ciphertext")
            )
            return ["ok": true, "value": hex(plaintext)]

        case "decryptGraphKey":
            let plaintext = try rsaOAEPDecrypt(
                privateKeyData: try hexData(request["privateKey"], field: "privateKey"),
                ciphertext: try hexData(request["ciphertext"], field: "ciphertext")
            )
            return ["ok": true, "value": hex(plaintext)]

        case "encryptGraphKey":
            let ciphertext = try rsaOAEPEncrypt(
                publicKeyData: try hexData(request["publicKey"], field: "publicKey"),
                plaintext: try hexData(request["plaintext"], field: "plaintext")
            )
            return ["ok": true, "value": hex(ciphertext)]

        case "randomBytes":
            guard let count = request["count"] as? Int else {
                throw E2EECryptoError.invalidRequest("missing byte count")
            }
            return ["ok": true, "value": hex(try randomBytes(count: count))]

        case "encryptAES":
            let (iv, ciphertext) = try aesSeal(
                key: try hexData(request["key"], field: "key"),
                plaintext: try hexData(request["plaintext"], field: "plaintext")
            )
            return ["ok": true, "iv": hex(iv), "ciphertext": hex(ciphertext)]

        case "decryptAES":
            let plaintext = try aesOpen(
                key: try hexData(request["key"], field: "key"),
                iv: try hexData(request["iv"], field: "iv"),
                ciphertextAndTag: try hexData(request["ciphertext"], field: "ciphertext")
            )
            return ["ok": true, "value": hex(plaintext)]

        case "saveGraphKey":
            guard let graphID = request["graphID"] as? String else {
                throw E2EECryptoError.invalidRequest("missing graphID")
            }
            try saveKey(graphID: graphID, key: try hexData(request["key"], field: "key"))
            return ["ok": true]

        case "loadGraphKey":
            guard let graphID = request["graphID"] as? String else {
                throw E2EECryptoError.invalidRequest("missing graphID")
            }
            if let key = try loadKey(graphID: graphID) {
                return ["ok": true, "value": hex(key)]
            }
            return ["ok": true, "value": NSNull()]

        case "saveE2EEPassword":
            try savePassword(try hexData(request["password"], field: "password"))
            return ["ok": true]

        case "loadE2EEPassword":
            if let password = try loadPassword() {
                return ["ok": true, "value": hex(password)]
            }
            return ["ok": true, "value": NSNull()]

        default:
            throw E2EECryptoError.invalidRequest("unsupported operation")
        }
    }
}

@_cdecl("logseq_crypto_json")
public func logseqCryptoJSON(_ requestPointer: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let response: [String: Any]
    do {
        guard let requestPointer,
              let data = String(cString: requestPointer).data(using: .utf8),
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw E2EECryptoError.invalidRequest("invalid JSON request") }
        response = try E2EECrypto.handle(request)
    } catch {
        response = ["ok": false, "error": String(describing: error)]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: response),
          let string = String(data: data, encoding: .utf8)
    else { return strdup("{\"ok\":false,\"error\":\"response encoding failed\"}") }
    return strdup(string)
}
#endif
