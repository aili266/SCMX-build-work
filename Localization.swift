import Foundation
import SwiftUI
import AppKit

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier:rawValue) }
    var displayName: String { self == .english ? "English" : "简体中文" }
}

final class LocalizationSettings: ObservableObject {
    static let shared = LocalizationSettings()
    static let preferenceKey = "SCMXBuildWork.interfaceLanguage"
    static let didChange = Notification.Name("SCMXBuildWork.interfaceLanguageChanged")

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue,forKey:Self.preferenceKey)
            NotificationCenter.default.post(name:Self.didChange,object:self)
        }
    }

    private init() {
        let arguments = CommandLine.arguments
        let argumentLanguage = arguments.firstIndex(of:"--ui-language").flatMap { index in
            arguments.indices.contains(index + 1) ? AppLanguage(rawValue:arguments[index + 1]) : nil
        }
        let environmentLanguage = ProcessInfo.processInfo.environment["SCMX_UI_LANGUAGE"].flatMap(AppLanguage.init(rawValue:))
        language = argumentLanguage ?? environmentLanguage ?? UserDefaults.standard.string(forKey:Self.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

enum L10n {
    static func string(_ key: String) -> String {
        let code = LocalizationSettings.shared.language.rawValue
        guard let path = Bundle.main.path(forResource:code,ofType:"lproj"),
              let bundle = Bundle(path:path) else { return key }
        return bundle.localizedString(forKey:key,value:key,table:nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format:string(key),locale:LocalizationSettings.shared.language.locale,arguments:arguments)
    }
}
