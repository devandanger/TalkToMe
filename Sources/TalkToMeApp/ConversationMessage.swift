import Foundation

struct ConversationMessage: Identifiable, Equatable {
    enum Role: String {
        case user = "User"
        case assistant = "TalkToMe"
        case foundationRequest = "Foundation Request"
    }

    let id = UUID()
    let role: Role
    let text: String
    let date = Date()
}
