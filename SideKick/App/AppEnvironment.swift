import Foundation
import Observation

@Observable
final class AppEnvironment {
    let sideloadingService: any SideloadingService

    init(sideloadingService: any SideloadingService = DemoSideloadingService()) {
        self.sideloadingService = sideloadingService
    }
}
