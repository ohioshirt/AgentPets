//
//  PetState.swift
//  MyApp
//
//  Created by shigeo on 2026/08/15.
//

import Foundation
import SwiftUI

enum PetState: String, Codable {
    case idle
    case working
    case waiting
    case success
    case error
    
    var emoji: String {
        switch self {
        case .idle:    return "🟢 (・ω・)"
        case .working: return "⚡ (•̀ᴗ•́)و"
        case .waiting: return "❓ (･_･;)"
        case .success: return "🎉 (٩(ˊxDˋ*)و)"
        case .error:   return "💥 (´;ω;`)"
        }
    }
    
    var color: Color {
        switch self {
        case .idle:    return .green
        case .working: return .yellow
        case .waiting: return .orange
        case .success: return .blue
        case .error:   return .red
        }
    }
}
