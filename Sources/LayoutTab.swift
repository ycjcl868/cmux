import Foundation
import Bonsplit

final class LayoutTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var isUserRenamed: Bool
    let bonsplitController: BonsplitController

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        isUserRenamed: Bool = false,
        bonsplitController: BonsplitController
    ) {
        self.id = id
        self.title = title
        self.isUserRenamed = isUserRenamed
        self.bonsplitController = bonsplitController
    }
}
