import Foundation

struct ConversationMessage: Identifiable, Equatable {
    enum Role: String {
        case user = "User"
        case assistant = "TalkToMe"
    }

    let id = UUID()
    let role: Role
    let text: String
    let date = Date()
}
