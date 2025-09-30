import Foundation
@preconcurrency import SoundAnalysis
import AVFoundation

/// Um tipo de dado simples e seguro para transferir os resultados, evitando problemas de concorrência.
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
    /// Canal que recebe os dados já analisados.
    public let classificationStream: AsyncStream<SoundClassification>

    /// Variável responsável por analisar as faixas de áudio e classificar via request de acordo com o modelo CreateML
    private let analyzer: SNAudioStreamAnalyzer
    
    /// Variável que gerencia todo o fluxo de áudio, entrada, mixer e saída.
    private let audioEngine = AVAudioEngine()
    
    /// Interno: Continuation usado para enviar resultados
    private let streamContinuation: AsyncStream<SoundClassification>.Continuation

    public override init() {
        var continuation: AsyncStream<SoundClassification>.Continuation!
        self.classificationStream = AsyncStream { continuation = $0 }
        self.streamContinuation = continuation
        
        /// Utilizamos a entrada principal de áudio do dispositivo
        let inputFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        
        /// Analisa a stream de audio por meio do formato inserido
        self.analyzer = SNAudioStreamAnalyzer(format: inputFormat)
        
        super.init()
        setupModel()
    }
    
    /// Essa função é responsável por fornecer as regras da análise, por meio de um request, para utilizar o modelo ML treinado
    /// - WARNING: Modelo CreateML precisa estar inicializado corretamente, associado ao target do projeto.
    private func setupModel() {
        do {
            let model = try ModeloTreinado(configuration: MLModelConfiguration())
            let request = try SNClassifySoundRequest(mlModel: model.model)
            try analyzer.add(request, withObserver: self)
        } catch {
            print("ERRO AO CARREGAR MODELO: \(error)")
        }
    }

    /// Função responsável por inicializar a captura de áudio em tempo real
    public func start() {
        let inputFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        audioEngine.inputNode.installTap(onBus: 0,
                                         bufferSize: 8192,
                                         format: inputFormat) { [weak self] buffer, time in
            self?.analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
        }
        do {
            try audioEngine.start()
        } catch {
            print("Erro ao iniciar áudio: \(error)")
        }
    }
    
    deinit {
        streamContinuation.finish()
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension AudioAnalyzer: SNResultsObserving {
    /// Função responsável por entregar as análises feitas para a variável streamContinuation
    public func request(_ request: SNRequest, didProduce result: SNResult) {
        if let classificationResult = result as? SNClassificationResult,
           let classification = classificationResult.classifications.first {
            let result = SoundClassification(identifier: classification.identifier,
                                             confidence: classification.confidence)
            streamContinuation.yield(result)
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
@MainActor
public final class AudioViewModel: ObservableObject {
    
    // MARK: Variáveis para UI
    @Published public var detectedSound: String = "Nenhum som detectado"
    @Published public private(set) var rmsLevel: Float = 0.0

    // MARK: Inicializadores de classe
    private let audioAnalyzer = AudioAnalyzer()
    private var analysisTask: Task<Void, Never>?

    public init() {
        listenToAudioAnalysis()
    }
    
    /// Função que inicializa a análise do áudio
    public func startAnalysis() {
        audioAnalyzer.start()
        
        let inputNode = audioAnalyzer.audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
    }
    
    /// Função que escuta os resultados da análise do áudio, via Stream
    private func listenToAudioAnalysis() {
        analysisTask = Task {
            for await result in audioAnalyzer.classificationStream {
                self.detectedSound = "\(result.identifier) (\(String(format: "%.2f", result.confidence * 100))%)"
            }
        }
    }
    
    /// Calcula o RMS de um buffer de áudio
    public func process(buffer: AVAudioPCMBuffer) {
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
        analysisTask?.cancel()
    }
}
