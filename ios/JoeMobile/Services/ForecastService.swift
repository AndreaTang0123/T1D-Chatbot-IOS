import Foundation
import CoreML
import JoeCore

@MainActor final class ForecastService {
    struct Manifest: Codable {
        let schema: String
        let modelVersion: String
        let inputNames: [String]
        let residualP90: [Double]
        let input: String
        let output: String
    }
    private var model: MLModel?
    private var manifest: Manifest?
    func predict(row: FeatureRow, at now: Date) throws -> Forecast {
        if model == nil { try load() }
        guard let model, let manifest else { throw DataIssue.modelMissing }
        guard row.modelInput.count == manifest.inputNames.count else { throw DataIssue.schemaMismatch }
        let array = try MLMultiArray(shape: [NSNumber(value: row.modelInput.count)], dataType: .double)
        for (index, value) in row.modelInput.enumerated() { array[index] = NSNumber(value: value) }
        let provider = try MLDictionaryFeatureProvider(dictionary: [manifest.input: MLFeatureValue(multiArray: array)])
        let output = try model.prediction(from: provider)
        guard let result = output.featureValue(for: manifest.output)?.multiArrayValue, result.count == 2 else { throw DataIssue.invalidPrediction }
        return try Forecast(at: now, row: row, outputs: [result[0].doubleValue, result[1].doubleValue],
                            uncertainty: manifest.residualP90, modelVersion: manifest.modelVersion)
    }
    private func load() throws {
        guard let url = Bundle.main.url(forResource: "GlucoseForecaster", withExtension: "mlmodelc"),
              let metadata = Bundle.main.url(forResource: "forecast_manifest", withExtension: "json") else { throw DataIssue.modelMissing }
        let decoded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: metadata))
        let names = FeatureRow.names + FeatureRow.names.map { "missing_" + $0 }
        guard decoded.schema == FeatureRow.schema, decoded.inputNames == names,
              decoded.residualP90.count == 2, decoded.residualP90.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw DataIssue.schemaMismatch }
        let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: config); manifest = decoded
    }
}
