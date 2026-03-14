import Foundation
import Bonsplit

final class LayoutTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    let bonsplitController: BonsplitController

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        bonsplitController: BonsplitController
    ) {
        self.id = id
        self.title = title
        self.bonsplitController = bonsplitController
    }
}
