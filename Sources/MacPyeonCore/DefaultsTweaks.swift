import Foundation

/// defaults 에 쓸 값.
public enum TweakValue: Equatable, Sendable {
    case bool(Bool)
    case string(String)
    case double(Double)

    public var propertyListValue: Any {
        switch self {
        case .bool(let v): return v
        case .string(let v): return v
        case .double(let v): return v
        }
    }
}

/// 값을 바꾼 뒤 다시 띄워야 하는 시스템 프로세스.
public enum RestartTarget: String, Sendable {
    case finder = "Finder"
    case dock = "Dock"
    case systemUIServer = "SystemUIServer"
}

/// defaults 키 하나를 바꾸는 단위.
public struct DefaultsTweak: Equatable, Sendable {
    /// 전역 설정(NSGlobalDomain)이면 `globalDomain`.
    public let domain: String
    public let key: String
    public let value: TweakValue
    public let restart: RestartTarget?

    public static let globalDomain = "NSGlobalDomain"

    public init(_ domain: String, _ key: String, _ value: TweakValue, restart: RestartTarget? = nil) {
        self.domain = domain
        self.key = key
        self.value = value
        self.restart = restart
    }

    /// 원래 값을 보관할 때 쓰는 키.
    public var backupKey: String { "backup.\(domain).\(key)" }
}

public enum DefaultsTweaks {
    private static let g = DefaultsTweak.globalDomain
    private static let finder = "com.apple.finder"

    public static func tweaks(for id: FeatureID) -> [DefaultsTweak] {
        switch id {
        case .disableAutoCorrect:
            return [
                DefaultsTweak(g, "NSAutomaticSpellingCorrectionEnabled", .bool(false)),
                DefaultsTweak(g, "NSAutomaticCapitalizationEnabled", .bool(false)),
                DefaultsTweak(g, "NSAutomaticPeriodSubstitutionEnabled", .bool(false)),
                DefaultsTweak(g, "NSAutomaticQuoteSubstitutionEnabled", .bool(false)),
                DefaultsTweak(g, "NSAutomaticDashSubstitutionEnabled", .bool(false)),
                DefaultsTweak(g, "WebAutomaticSpellingCorrectionEnabled", .bool(false)),
            ]
        case .showExtensions:
            return [DefaultsTweak(g, "AppleShowAllExtensions", .bool(true), restart: .finder)]
        case .showPathBar:
            return [DefaultsTweak(finder, "ShowPathbar", .bool(true), restart: .finder)]
        case .showStatusBar:
            return [DefaultsTweak(finder, "ShowStatusBar", .bool(true), restart: .finder)]
        case .foldersFirst:
            return [
                DefaultsTweak(finder, "_FXSortFoldersFirst", .bool(true), restart: .finder),
                DefaultsTweak(finder, "_FXSortFoldersFirstOnDesktop", .bool(true), restart: .finder),
            ]
        case .searchCurrentFolder:
            return [DefaultsTweak(finder, "FXDefaultSearchScope", .string("SCcf"), restart: .finder)]
        case .noExtensionWarning:
            return [DefaultsTweak(finder, "FXEnableExtensionChangeWarning", .bool(false), restart: .finder)]
        case .showHiddenFiles:
            return [DefaultsTweak(finder, "AppleShowAllFiles", .bool(true), restart: .finder)]
        case .noDSStoreExternal:
            return [
                DefaultsTweak("com.apple.desktopservices", "DSDontWriteNetworkStores", .bool(true), restart: .finder),
                DefaultsTweak("com.apple.desktopservices", "DSDontWriteUSBStores", .bool(true), restart: .finder),
            ]
        case .keyRepeat:
            return [DefaultsTweak(g, "ApplePressAndHoldEnabled", .bool(false))]
        case .screenshotNoShadow:
            return [DefaultsTweak("com.apple.screencapture", "disable-shadow", .bool(true), restart: .systemUIServer)]
        case .dockNoDelay:
            return [DefaultsTweak("com.apple.dock", "autohide-delay", .double(0), restart: .dock)]
        default:
            return []
        }
    }
}
