import Foundation

@MainActor
@Observable
final class UnlockPasswordDraft {
    static let shared = UnlockPasswordDraft()

    var password: String {
        didSet { UnlockPasswordStore.save(password) }
    }
    var isVisible = false

    private init() {
        password = UnlockPasswordStore.load() ?? ""
    }
}
