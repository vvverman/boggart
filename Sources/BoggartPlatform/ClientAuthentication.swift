import Foundation
import Security
import CryptoKit
import BoggartCore

/// Проверку требования выполняет сама XPC-подсистема, а не PID или путь.
/// Личная поставка доверяет только точному сертификату своей пары app/helper.
/// Это не Apple Developer ID и не добавляет сертификат в доверенные на Mac пользователя.
public enum ClientAuthentication {
    public static func requirement(for identifier: String) throws -> String {
        guard [BoggartConstants.appID, BoggartConstants.serviceID].contains(identifier) else {
            throw BoggartError.message("Неизвестный компонент Боггарта.")
        }
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else {
            throw BoggartError.message("Не удалось проверить подпись Боггарта.")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode else {
            throw BoggartError.message("Не удалось получить подпись Боггарта.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else {
            throw BoggartError.message("Не удалось прочитать подпись Боггарта.")
        }
        #if BOGGART_PERSONAL_BUILD
        guard let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else {
            throw BoggartError.message("Подпись личной сборки повреждена. Неподписанные и ad-hoc-компоненты не допускаются.")
        }
        // Формат certificate leaf в языке требований Apple использует SHA-1
        // отпечаток DER-сертификата, а не имя издателя или произвольный Team ID.
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(digest)\""
        #else
        guard let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw BoggartError.message("Нужна подпись Apple Development или Developer ID. Ad-hoc-сборка не допускается к помощнику.")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        #endif
    }
}
