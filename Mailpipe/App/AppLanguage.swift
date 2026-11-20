import SwiftUI

enum AppLanguage: String, CaseIterable {
    case english = "en", chinese = "zh-Hans", spanish = "es"
    static let key = "interfaceLanguage"

    var name: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
        case .spanish: "Español"
        }
    }
}

func L(_ key: String, _ arguments: String...) -> String {
    let language = UserDefaults.standard.string(forKey: AppLanguage.key)
        .flatMap(AppLanguage.init(rawValue:)) ?? .english
    let bundle = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
        .flatMap(Bundle.init(path:)) ?? Bundle.main
    let format = bundle.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.key) private var language = AppLanguage.english.rawValue

    var body: some View {
        Picker(L("Language"), selection: $language) {
            ForEach(AppLanguage.allCases, id: \.self) { option in
                Text(verbatim: option.name).tag(option.rawValue)
            }
        }
    }
}

enum AppAppearance: String, CaseIterable {
    case system = "Follow System", light = "Light", dark = "Dark"
    static let key = "interfaceAppearance"

    static var saved: Self {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct AppearancePicker: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system

    var body: some View {
        Picker(L("Appearance"), selection: $appearance) {
            ForEach(AppAppearance.allCases, id: \.self) { option in
                Text(verbatim: L(option.rawValue)).tag(option)
            }
        }
        .onChange(of: appearance) { $0.apply() }
    }
}
