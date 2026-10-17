import Foundation
import Security
import BoggartCore

/// Проверку требования выполняет сама XPC-подсистема. Не используем проверку
/// только по PID, путь к исполняемому файлу или предоставленный клиентом Team ID.
public enum ClientAuthentication {
    public static func requirement(for identifier: String) throws -> String {
        var ownCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &ownCode) == errSecSuccess, let ownCode else {
            throw BoggartError.message("Не удалось проверить подпись Боггарта.")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode else {
            throw BoggartError.message("Не удалось получить статическое представление подписи Боггарта.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
              [BoggartConstants.appID, BoggartConstants.serviceID].contains(identifier) else {
            throw BoggartError.message("Нужна подпись Apple Development или Developer ID. Ad-hoc-сборка не допускается к помощнику.")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
