import Foundation
import Security
import BoggartCore

public struct ValidatedBundle {
    public let url: URL
    public let version: String
    public let build: String
    public let testing: Bool
}

/// Проверка поставки до регистрации службы или замены файлов. Ни один путь
/// пользователя не передаётся привилегированному XPC-помощнику.
public enum BundleValidation {
    public static let installedURL = URL(fileURLWithPath: "/Applications/Boggart.app", isDirectory: true)
    public static func inspect(_ url: URL, requireNewer: Bool = false) throws -> ValidatedBundle {
        let url = url.standardizedFileURL
        guard url.pathExtension == "app", let bundle = Bundle(url: url),
              bundle.bundleIdentifier == BoggartConstants.appID,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let schema = bundle.object(forInfoDictionaryKey: "BoggartRecoverySchema") as? Int, schema == 3,
              let testing = bundle.object(forInfoDictionaryKey: "BoggartHardwareTesting") as? Bool else {
            throw BoggartError.message("Это не совместимая поставка Боггарта. Выберите подписанное приложение из дистрибутива.")
        }
        if requireNewer {
            let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            guard MaintenancePolicy.isNewerBuild(build, than: currentBuild) else {
                throw BoggartError.message("Выберите более новую сборку Боггарта. Установленная версия не заменена.")
            }
            guard testing == BoggartConstants.hardwareTesting else {
                throw BoggartError.message("Проверочную и обычную сборки нельзя заменять друг другом как обычное обновление.")
            }
        }
        try verify(url, identifier: BoggartConstants.appID)
        let helper = url.appendingPathComponent("Contents/MacOS/BoggartHelper")
        try verify(helper, identifier: BoggartConstants.serviceID)
        let plist = url.appendingPathComponent("Contents/Library/LaunchDaemons/\(BoggartConstants.daemonPlist)")
        let data = try Data(contentsOf: plist)
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              values["Label"] as? String == BoggartConstants.serviceID,
              values["BundleProgram"] as? String == "Contents/MacOS/BoggartHelper",
              values["UserName"] as? String == "root" else {
            throw BoggartError.message("В поставке неверно описан системный помощник.")
        }
        return .init(url: url, version: version, build: build, testing: testing)
    }
    public static func setupBlocker() -> String? {
        let capability = HardwareValidation.currentCapability()
        guard capability.available else { return capability.message }
        guard Bundle.main.bundleURL.standardizedFileURL == installedURL else {
            return "Переместите Боггарт в папку «Программы» и откройте его оттуда. Из образа диска помощник не устанавливается."
        }
        do { _ = try inspect(Bundle.main.bundleURL); return nil }
        catch { return error.localizedDescription }
    }
    private static func verify(_ url: URL, identifier: String) throws {
        let expression = try ClientAuthentication.requirement(for: identifier)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw BoggartError.message("Не удалось проверить издателя поставки.") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw BoggartError.message("В поставке отсутствует подписанный исполняемый файл.")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw BoggartError.message("Подпись приложения или помощника повреждена либо принадлежит другому издателю.")
        }
    }
}
