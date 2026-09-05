import Foundation

/// UI 文案本地化入口。key 即英文文案（开发语言，CFBundleDevelopmentRegion = en），
/// 中文翻译见 Resources/zh-Hans.lproj/Localizable.strings。
/// 系统语言为中文时显示中文，其余语言一律回退到英文 key 本身。
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}
