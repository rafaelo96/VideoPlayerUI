import CoreML
import Foundation

final class RIFECoreMLInterpolator {
    enum State {
        case unavailable
        case loaded(MLModel)
    }

    private(set) var state: State = .unavailable

    init() {
        loadBundledModelIfAvailable()
    }

    private func loadBundledModelIfAvailable() {
        guard let modelURL = Bundle.main.url(forResource: "RIFE", withExtension: "mlmodelc") else {
            return
        }

        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            state = .loaded(try MLModel(contentsOf: modelURL, configuration: configuration))
        } catch {
            state = .unavailable
        }
    }
}
