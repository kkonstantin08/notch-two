//
//  PreferenceCompatibilityTests.swift
//  boringNotchTests
//

import Foundation
import XCTest
@testable import boringNotch

final class PreferenceCompatibilityTests: XCTestCase {
    private let renamedKeys: [(String, String, Bool)] = [
        ("hudReplacement", "osdReplacement", false),
        ("inlineHUD", "inlineOSD", false),
        ("showOpenNotchHUD", "showOpenNotchOSD", true),
        ("showOpenNotchHUDPercentage", "showOpenNotchOSDPercentage", true),
        ("showClosedNotchHUDPercentage", "showClosedNotchOSDPercentage", false)
    ]

    private func withSuite(_ body: (UserDefaults, String) throws -> Void) throws {
        // Also namespace migrated keys: Foundation shares registration across suites.
        let name = "PreferenceCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }

    private func checkEncodings<T: RawRepresentable & Equatable>(
        _ encodings: [(String, String, T)]
    ) throws where T.RawValue == String {
        try withSuite { defaults, _ in
            for (legacy, current, expected) in encodings {
                for encoded in [legacy, current] {
                    defaults.set(encoded, forKey: "enum")
                    let stored = try XCTUnwrap(defaults.string(forKey: "enum"))
                    let decoded = try XCTUnwrap(T(rawValue: stored))
                    XCTAssertEqual(decoded, expected)
                    XCTAssertEqual(decoded.rawValue, current)
                }
            }
            for invalid in ["", "unknown", "NOW PLAYING", " showOSD"] {
                XCTAssertNil(T(rawValue: invalid))
            }
        }
    }

    func testLanguagePickerMatchesPackagedLanguages() {
        let options = AppLanguage.allCases.map(\.rawValue)
        XCTAssertEqual(options, ["system", "en", "ru", "de", "es", "fr"])
        XCTAssertEqual(Set(Bundle.main.localizations).subtracting(["Base"]), Set(options.dropFirst()))
    }

    func testPreviousLanguageSelectionsResolveToSupportedOptions() {
        XCTAssertEqual(AppLanguage(rawValue: "en-GB").supportedChoice.rawValue, "en")
        XCTAssertEqual(AppLanguage(rawValue: "ja").supportedChoice, .system)
        XCTAssertEqual(AppLanguage(rawValue: "it").supportedChoice, .system)
        XCTAssertEqual(AppLanguage(rawValue: "ru").supportedChoice.rawValue, "ru")
    }

    func testBuiltAppHasBothLanguageResources() throws {
        for (language, languageLabel, customFeatures) in [
            ("en", "App language", "Custom Features"),
            ("ru", "Язык приложения", "Дополнительные функции")
        ] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let resources = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(resources.localizedString(forKey: "App language", value: nil, table: nil), languageLabel)
            XCTAssertEqual(resources.localizedString(forKey: "Custom Features", value: nil, table: nil), customFeatures)
            let permission = resources.localizedString(forKey: "NSLocationUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertTrue(permission.contains(language == "en" ? "Location access" : "геопозиции"))
        }
    }

    func testMediaControllerEncodings() throws {
        try checkEncodings([
            ("Now Playing", "nowPlaying", MediaControllerType.nowPlaying),
            ("Apple Music", "appleMusic", .appleMusic),
            ("Spotify", "spotify", .spotify),
            ("YouTube Music", "youtubeMusic", .youtubeMusic)
        ])
    }

    func testSneakPeekEncodings() throws {
        try checkEncodings([
            ("Default", "standard", SneakPeekStyle.standard),
            ("Inline", "inline", .inline)
        ])
    }

    func testOptionKeyEncodings() throws {
        try checkEncodings([
            ("Open System Settings", "openSettings", OptionKeyAction.openSettings),
            ("Show HUD", "showOSD", .showOSD),
            ("No Action", "none", .none)
        ])
    }

    func testSliderColorEncodings() throws {
        try checkEncodings([
            ("White", "white", SliderColorEnum.white),
            ("Match album art", "albumArt", .albumArt),
            ("Accent color", "accent", .accent)
        ])
    }

    func testLegacyBooleansMigrateOnceAndKeepUnrelatedValues() throws {
        for (legacy, current, _) in renamedKeys {
            for value in [false, true] {
                try withSuite { defaults, name in
                    let legacy = "\(name).\(legacy)"
                    let current = "\(name).\(current)"
                    defaults.set(value, forKey: legacy)
                    defaults.set("untouched", forKey: "unrelated")
                    XCTAssertEqual(PreferenceCompatibility.migratedKeyName(current, from: legacy, in: defaults), current)
                    XCTAssertEqual(defaults.object(forKey: current) as? Bool, value)
                    let migrated = defaults.persistentDomain(forName: name)
                    _ = PreferenceCompatibility.migratedKeyName(current, from: legacy, in: defaults)
                    XCTAssertEqual(defaults.persistentDomain(forName: name) as NSDictionary?, migrated as NSDictionary?)
                    XCTAssertEqual(defaults.object(forKey: legacy) as? Bool, value)
                    XCTAssertEqual(defaults.string(forKey: "unrelated"), "untouched")
                }
            }
        }
    }

    func testSavedCurrentBooleanWinsIncludingFalse() throws {
        for (legacy, current, _) in renamedKeys {
            for value in [false, true] {
                try withSuite { defaults, name in
                    let legacy = "\(name).\(legacy)"
                    let current = "\(name).\(current)"
                    defaults.set(!value, forKey: legacy)
                    defaults.set(value, forKey: current)
                    for _ in 0..<2 {
                        _ = PreferenceCompatibility.migratedKeyName(current, from: legacy, in: defaults)
                        XCTAssertEqual(defaults.object(forKey: current) as? Bool, value)
                    }
                }
            }
        }
    }

    func testAbsentKeysKeepFallbackWithoutPersistingIt() throws {
        for (legacy, current, fallback) in renamedKeys {
            try withSuite { defaults, name in
                let legacy = "\(name).\(legacy)"
                let current = "\(name).\(current)"
                _ = PreferenceCompatibility.migratedKeyName(current, from: legacy, in: defaults)
                XCTAssertNil(defaults.object(forKey: current))
                defaults.register(defaults: [current: fallback])
                XCTAssertEqual(defaults.bool(forKey: current), fallback)
                _ = PreferenceCompatibility.migratedKeyName(current, from: legacy, in: defaults)
                XCTAssertNil(defaults.persistentDomain(forName: name)?[current])
                XCTAssertNil(defaults.object(forKey: legacy))
            }
        }
    }
}
