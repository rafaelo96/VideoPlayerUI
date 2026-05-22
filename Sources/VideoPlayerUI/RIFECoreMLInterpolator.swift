import CoreML
import CoreVideo
import Foundation

@MainActor
final class RIFECoreMLInterpolator {
    enum State {
        case unavailable
        case loaded(RIFEEngine, ModelDescription)
        case failed(String)
    }

    struct ModelDescription {
        let name: String
        let inputNames: [String]
        let outputNames: [String]
    }

    private(set) var state: State = .unavailable
    private var engine: RIFEEngine?

    var statusText: String {
        switch state {
        case .unavailable:
            return "RIFE sin modelo"
        case .loaded(_, let description):
            return "RIFE \(description.name)"
        case .failed(let reason):
            return "RIFE error: \(reason)"
        }
    }

    var isLoaded: Bool {
        if case .loaded = state {
            return true
        }

        return false
    }

    init() {
        state = .unavailable
    }

    init() async throws {
        try await loadEngine()
    }

    func loadEngine() async throws {
        guard let modelURL = Self.findBundledModelURL() else {
            state = .unavailable
            engine = nil
            return
        }

        do {
            let loadURL: URL
            if modelURL.pathExtension == "mlmodel" || modelURL.pathExtension == "mlpackage" {
                loadURL = try await Task.detached(priority: .userInitiated) {
                    try MLModel.compileModel(at: modelURL)
                }.value
            } else {
                loadURL = modelURL
            }

            let modelDescription = try Self.inspectModel(at: loadURL, originalURL: modelURL)
            let loadedEngine = try await RIFEEngine(modelURL: loadURL, computeUnits: .cpuAndGPU)
            engine = loadedEngine
            state = .loaded(loadedEngine, modelDescription)
        } catch let error as RIFEError {
            engine = nil
            state = .failed(error.localizedDescription)
            throw error
        } catch {
            engine = nil
            state = .failed(error.localizedDescription)
            throw RIFEError.modelLoad(error.localizedDescription)
        }
    }

    func interpolate(frame0: CVPixelBuffer, frame1: CVPixelBuffer, timestep: Float = 0.5) async throws -> CVPixelBuffer {
        guard let engine else {
            throw RIFEError.modelLoad("RIFE engine is not loaded")
        }

        return try await engine.interpolate(frame0: frame0, frame1: frame1, timestep: timestep)
    }

    private static func inspectModel(at loadURL: URL, originalURL: URL) throws -> ModelDescription {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: loadURL, configuration: configuration)
        return ModelDescription(
            name: originalURL.deletingPathExtension().lastPathComponent,
            inputNames: Array(model.modelDescription.inputDescriptionsByName.keys).sorted(),
            outputNames: Array(model.modelDescription.outputDescriptionsByName.keys).sorted()
        )
    }

    private static func findBundledModelURL() -> URL? {
        if let environmentURL = environmentModelURL() {
            return environmentURL
        }

        let bundles = Self.modelSearchBundles()
        let extensions = ["mlmodelc", "mlpackage", "mlmodel"]

        for bundle in bundles {
            for ext in extensions {
                if let url = bundle.url(forResource: "RIFE", withExtension: ext) {
                    return url
                }

                if let url = bundle.url(forResource: "RIFE", withExtension: ext, subdirectory: "Resources") {
                    return url
                }
            }
        }

        return nil
    }

    private static func environmentModelURL() -> URL? {
        guard let rawPath = ProcessInfo.processInfo.environment["RIFE_MODEL_URL"],
              !rawPath.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: rawPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func modelSearchBundles() -> [Bundle] {
        var bundles: [Bundle] = []
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        bundles.append(Bundle.main)
        return bundles
    }
}
