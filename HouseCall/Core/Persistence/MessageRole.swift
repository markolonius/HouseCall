//
//  MessageRole.swift
//  HouseCall
//

import Foundation

/// The role of a message sender in a conversation
enum MessageRole: String, Codable, Equatable {
    case system
    case user
    case assistant
}
