//
//  Theme.swift
//  Faith
//
import SwiftUI
import UIKit

enum FinderTheme {
    // Brand colors
    static let forest = Color(
        red: 11.0 / 255.0,
        green: 61.0 / 255.0,
        blue: 46.0 / 255.0
    )

    static let mint = Color(
        red: 184.0 / 255.0,
        green: 242.0 / 255.0,
        blue: 208.0 / 255.0
    )

    static let lime = Color(
        red: 200.0 / 255.0,
        green: 255.0 / 255.0,
        blue: 61.0 / 255.0
    )

    // These automatically adapt to light and dark mode.
    static let background = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)

    // Layout values
    static let smallSpacing: CGFloat = 8
    static let regularSpacing: CGFloat = 16
    static let largeSpacing: CGFloat = 24

    static let cornerRadius: CGFloat = 20
    static let minimumTouchSize: CGFloat = 44
    static let foundButtonHeight: CGFloat = 88
}
