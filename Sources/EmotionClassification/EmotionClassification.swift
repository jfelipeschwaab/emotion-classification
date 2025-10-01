import Foundation
@preconcurrency import SoundAnalysis
import AVFoundation
import CoreML

// =====================================================
// NOVO: tipos auxiliares para sumarização
// =====================================================
public struct PredominantSentiment: Sendable {
    public let identifier: String
    public let score: Double          // soma das confianças
    public let averageConfidence: Double
    public let occurrences: Int
    public let lastUpdated: Date
}

private struct _Stat: Sendable {
    var totalConfidence: Double = 0
    var count: Int = 0
    var lastUpdated: Date = .distantPast
}

// Actor para garantir segurança de concorrência
public actor ClassificationAccumulator {
    private var stats: [String: _Stat] = [:]

    public init() {}

    public func reset() {
        stats.removeAll()
    }

    public func record(identifier: String, confidence: Double, date: Date = Date()) {
        var s = stats[identifier, default: _Stat()]
        s.totalConfidence += confidence
        s.count += 1
        s.lastUpdated = date
        stats[identifier] = s
    }

    public func predominant() -> PredominantSentiment? {
        guard let (id, s) = stats.max(by: { $0.value.totalConfidence < $1.value.totalConfidence }) else { return nil }
        let avg = s.count > 0 ? (s.totalConfidence / Double(s.count)) : 0
        return PredominantSentiment(identifier: id,
                                    score: s.totalConfidence,
                                    averageConfidence: avg,
                                    occurrences: s.count,
                                    lastUpdated: s.lastUpdated)
    }

    public func snapshot() -> [String: PredominantSentiment] {
        var out: [String: PredominantSentiment] = [:]
        for (id, s) in stats {
            let avg = s.count > 0 ? (s.totalConfidence / Double(s.count)) : 0
            out[id] = PredominantSentiment(identifier: id,
                                           score: s.totalConfidence,
                                           averageConfidence: avg,
                                           occurrences: s.count,
                                           lastUpdated: s.lastUpdated)
        }
        return out
    }
}

// =====================================================
// SEU CÓDIGO EXISTENTE
// =====================================================

public struct SoundClassification: Sendable {
    public let identifier: String
    public let confidence: Double
    
    public init(identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

@available(iOS 15.0, macOS 12.0, *)
public final class AudioAnalyzer: NSObject, Sendable {
    public let classificationStream: AsyncStream<SoundClassification>
    public let analyzer: SNAudioStreamAnalyzer
    public let audioEngine = AVAudioEngine()
    public let streamContinuation: AsyncStream<SoundClassification>.Continuation

    // NOVO: acumulador de estatísticas (actor)
    private let accumulator = ClassificationAccumulator()

    public override init() {
        var continuation: AsyncStream<SoundClassification>.Continuation!
        self.classificationStream = AsyncStream { continuation = $0 }
        self.streamContinuation = continuation
        
        let inputFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        self.analyzer = SNAudioStreamAnalyzer(format: inputFormat)
        
        super.init()
        setupModel()
    }
    
    private func setupModel() {
        do {
            let model = try ModeloTreinado(configuration: MLModelConfiguration())
            let request = try SNClassifySoundRequest(mlModel: model.model)
            try analyzer.add(request, withObserver: self)
        } catch {
            print("ERRO AO CARREGAR MODELO: \(error)")
        }
    }

    /// Inicia a análise de áudio
    public func start(withRMSHandler rmsHandler: ((AVAudioPCMBuffer) -> Void)? = nil) {
        // NOVO: resetar estatísticas a cada sessão
        Task { await accumulator.reset() }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        inputNode.removeTap(onBus: 0)
        
        inputNode.installTap(onBus: 0,
                             bufferSize: 8192,
                             format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            self.analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
            rmsHandler?(buffer)
        }
        
        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
        } catch {
            print("Erro ao iniciar áudio: \(error)")
        }
    }
    
    /// Para a análise de áudio
    public func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    // =====================================================
    // NOVO: API pública para obter o sentimento predominante
    // =====================================================

    /// Retorna o sentimento predominante até o momento (desde o último `start()`).
    /// Critério: maior soma de confianças (score). Útil quando o stream dispara
    /// várias amostras rápidas do mesmo rótulo.
    public func predominantSentiment() async -> PredominantSentiment? {
        await accumulator.predominant()
    }

    /// Opcional: snapshot completo para UI/depuração (placar de todos os rótulos).
    public func sentimentsSnapshot() async -> [String: PredominantSentiment] {
        await accumulator.snapshot()
    }
    
    deinit {
        stop()
        streamContinuation.finish()
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension AudioAnalyzer: SNResultsObserving {
    public func request(_ request: SNRequest, didProduce result: SNResult) {
        if let classificationResult = result as? SNClassificationResult,
           let classification = classificationResult.classifications.first {
            let result = SoundClassification(identifier: classification.identifier,
                                             confidence: classification.confidence)

            // NOVO: acumular estatística para predominância
            Task {
                await accumulator.record(identifier: result.identifier,
                                         confidence: result.confidence,
                                         date: Date())
            }

            streamContinuation.yield(result)
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
@MainActor
public final class AudioViewModel: ObservableObject {
    @Published public var detectedSound: String = "Nenhum som detectado"
    @Published public private(set) var rmsLevel: Float = 0.0
    // NOVO: expor o predominante na ViewModel se quiser
    @Published public private(set) var predominant: PredominantSentiment?

    private let audioAnalyzer = AudioAnalyzer()
    private var analysisTask: Task<Void, Never>?
    
    public init() { listenToAudioAnalysis() }
    
    public func startAnalysis() {
        audioAnalyzer.start { [weak self] buffer in
            self?.process(buffer: buffer)
        }
    }
    
    public func stopAnalysis() {
        audioAnalyzer.stop()
        analysisTask?.cancel()
        analysisTask = nil
        rmsLevel = 0.0
        detectedSound = "Nenhum som detectado"
        predominant = nil
    }
    
    private func listenToAudioAnalysis() {
        analysisTask = Task {
            for await result in audioAnalyzer.classificationStream {
                self.detectedSound = "\(result.identifier) (\(String(format: "%.2f", result.confidence * 100))%)"

                // Atualiza o predominante “on the fly” (opcional)
                if let pred = await audioAnalyzer.predominantSentiment() {
                    self.predominant = pred
                }
            }
        }
    }
    
    private func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channel = channelData[0]
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0.0

        for i in 0..<frameLength {
            let sample = channel[i]
            sum += sample * sample
        }
        let meanSquare = sum / Float(frameLength)
        let rms = sqrt(meanSquare)
        let normalized = min(max((rms * 10.0), 0.0), 1.0)

        Task { @MainActor in
            self.rmsLevel = normalized
        }
    }
    
    deinit {
        audioAnalyzer.stop()
        analysisTask?.cancel()
    }
}
