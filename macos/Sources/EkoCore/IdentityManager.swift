import Foundation
import Security
import X509

public struct DeviceIdentity: @unchecked Sendable {
    public let securityIdentity: SecIdentity
    public let certificate: SecCertificate
    public let certificateDER: Data
    public let fingerprint: String

    public init(securityIdentity: SecIdentity, certificate: SecCertificate, certificateDER: Data) {
        self.securityIdentity = securityIdentity
        self.certificate = certificate
        self.certificateDER = certificateDER
        self.fingerprint = EkoCrypto.fingerprint(of: certificateDER)
    }
}

public protocol IdentityProviding: Sendable {
    func loadOrCreateIdentity() throws -> DeviceIdentity
}

public final class KeychainIdentityManager: IdentityProviding, @unchecked Sendable {
    private let keyTag = Data("com.eko.mac.identity.p256.v1".utf8)
    private let certificateLabel = "com.eko.mac.identity.certificate.v1"
    private let metadataService = "com.eko.mac.identity.metadata.v1"
    private let metadataAccount = "leaf-der"

    public init() {}

    public func loadOrCreateIdentity() throws -> DeviceIdentity {
        let privateKey = try existingPrivateKey() ?? createPrivateKey()
        let storedCertificate = try existingCertificate()
        let metadataDER = try existingCertificateMetadata()

        let certificate: SecCertificate
        if let storedCertificate {
            let storedDER = SecCertificateCopyData(storedCertificate) as Data
            if let metadataDER, !EkoCrypto.constantTimeEqual(storedDER, metadataDER) {
                throw EkoCoreError.identity("certificate metadata does not match the Keychain certificate")
            }
            try validate(certificate: storedCertificate, privateKey: privateKey)
            if metadataDER == nil { try saveCertificateMetadata(storedDER) }
            certificate = storedCertificate
        } else if let metadataDER {
            guard let restored = SecCertificateCreateWithData(nil, metadataDER as CFData) else {
                throw EkoCoreError.identity("stored certificate DER is invalid")
            }
            try validate(certificate: restored, privateKey: privateKey)
            try addCertificate(restored)
            certificate = restored
        } else {
            let generated = try makeSelfSignedCertificate(privateKey: privateKey)
            let der = SecCertificateCopyData(generated) as Data
            try saveCertificateMetadata(der)
            try addCertificate(generated)
            certificate = generated
        }

        let identity = try queryIdentity()
        let der = SecCertificateCopyData(certificate) as Data
        return DeviceIdentity(securityIdentity: identity, certificate: certificate, certificateDER: der)
    }

    private func existingPrivateKey() throws -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result else {
            throw keychainError(status, operation: "read identity key")
        }
        let key = result as! SecKey
        try validatePrivateKeyAttributes(key)
        return key
    }

    private func createPrivateKey() throws -> SecKey {
        let privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrIsExtractable: false,
            kSecAttrApplicationTag: keyTag,
            kSecAttrLabel: "Eko identity private key",
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false,
        ]
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: privateAttributes,
            kSecUseDataProtectionKeychain: true,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown Security.framework error"
            throw EkoCoreError.identity("could not create P-256 identity key: \(detail)")
        }
        try validatePrivateKeyAttributes(key)
        return key
    }

    private func existingCertificate() throws -> SecCertificate? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result else {
            throw keychainError(status, operation: "read identity certificate")
        }
        let certificate = result as! SecCertificate
        return certificate
    }

    private func addCertificate(_ certificate: SecCertificate) throws {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: certificateLabel,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw keychainError(status, operation: "store identity certificate")
        }
    }

    private func existingCertificateMetadata() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: metadataService,
            kSecAttrAccount: metadataAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status, operation: "read identity certificate metadata")
        }
        return data
    }

    private func saveCertificateMetadata(_ der: Data) throws {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: metadataService,
            kSecAttrAccount: metadataAccount,
            kSecValueData: der,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: metadataService,
                kSecAttrAccount: metadataAccount,
                kSecUseDataProtectionKeychain: true,
            ]
            let update: [CFString: Any] = [kSecValueData: der]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw keychainError(updateStatus, operation: "update identity certificate metadata")
            }
        } else if status != errSecSuccess {
            throw keychainError(status, operation: "store identity certificate metadata")
        }
    }

    private func queryIdentity() throws -> SecIdentity {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: certificateLabel,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            throw keychainError(status, operation: "assemble SecIdentity")
        }
        return result as! SecIdentity
    }

    private func makeSelfSignedCertificate(privateKey: SecKey) throws -> SecCertificate {
        let signingKey = try Certificate.PrivateKey(privateKey)
        let hostName = Host.current().localizedName ?? "Mac"
        let name = try DistinguishedName {
            CommonName("Eko on \(hostName)")
            OrganizationName("Eko")
        }
        let serial = try EkoCrypto.randomBytes(count: 20)
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true, keyAgreement: true))
            try ExtendedKeyUsage([.serverAuth, .clientAuth])
            SubjectKeyIdentifier(hash: signingKey.publicKey)
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(bytes: serial),
            publicKey: signingKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-300),
            notValidAfter: Date().addingTimeInterval(20 * 365.25 * 24 * 60 * 60),
            issuer: name,
            subject: name,
            extensions: extensions,
            issuerPrivateKey: signingKey
        )
        return try SecCertificate.makeWithCertificate(certificate)
    }

    private func validatePrivateKeyAttributes(_ privateKey: SecKey) throws {
        guard let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == (kSecAttrKeyTypeECSECPrimeRandom as String),
              attributes[kSecAttrKeySizeInBits] as? Int == 256,
              attributes[kSecAttrKeyClass] as? String == (kSecAttrKeyClassPrivate as String),
              attributes[kSecAttrIsPermanent] as? Bool == true,
              attributes[kSecAttrIsExtractable] as? Bool != true else {
            throw EkoCoreError.identity("identity key attributes are not the required permanent non-exportable P-256 profile")
        }
    }

    private func validate(certificate: SecCertificate, privateKey: SecKey) throws {
        guard let certificateKey = SecCertificateCopyKey(certificate),
              let expectedPublicKey = SecKeyCopyPublicKey(privateKey) else {
            throw EkoCoreError.identity("could not read identity public key")
        }
        var certificateError: Unmanaged<CFError>?
        var expectedError: Unmanaged<CFError>?
        guard let certificateBytes = SecKeyCopyExternalRepresentation(certificateKey, &certificateError) as Data?,
              let expectedBytes = SecKeyCopyExternalRepresentation(expectedPublicKey, &expectedError) as Data?,
              EkoCrypto.constantTimeEqual(certificateBytes, expectedBytes) else {
            _ = certificateError?.takeRetainedValue()
            _ = expectedError?.takeRetainedValue()
            throw EkoCoreError.identity("identity certificate does not match its private key")
        }
    }

    private func keychainError(_ status: OSStatus, operation: String) -> EkoCoreError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .identity("could not \(operation): \(message)")
    }
}
