import Foundation
import Observation

@Observable
final class AppEnvironment {
    let ipaImportStore: IPAImportStore

    init(ipaImportStore: IPAImportStore = IPAImportStore()) { self.ipaImportStore = ipaImportStore }
}
