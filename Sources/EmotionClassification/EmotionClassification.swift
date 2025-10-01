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
    public let analyzer: SNAudioStreamAnalyzer
    
    /// Variável que gerencia todo o fluxo de áudio, entrada, mixer e saída.
    public let audioEngine = AVAudioEngine()
    
    /// Interno: Continuation usado para enviar resultados
    public let streamContinuation: AsyncStream<SoundClassification>.Continuation
    
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
    /// - Parameter rmsHandler: callback opcional para RMS
    public func start(withRMSHandler rmsHandler: ((AVAudioPCMBuffer) -> Void)? = nil) {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        // Remove tap anterior caso exista
        inputNode.removeTap(onBus: 0)
        
        inputNode.installTap(onBus: 0,
                             bufferSize: 8192,
                             format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            
            // Envia para o analyzer
            self.analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
            
            // Callback para cálculo de RMS
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
            streamContinuation.yield(result)
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
@MainActor
public final class AudioViewModel: ObservableObject {
    
    @Published public var detectedSound: String = "Nenhum som detectado"
    @Published public private(set) var rmsLevel: Float = 0.0
    
    private let audioAnalyzer = AudioAnalyzer()
    private var analysisTask: Task<Void, Never>?
    
    private let BUFFER_SIZE = 6
    
    private var classificationBuffer: [SoundClassification] = []

    
    public init() {
        listenToAudioAnalysis()
    }
    
    /// Inicia a análise de áudio
    public func startAnalysis() {
        audioAnalyzer.start { [weak self] buffer in
            self?.process(buffer: buffer)
        }
    }
    
    /// Para a análise de áudio
    public func stopAnalysis() {
        audioAnalyzer.stop()
        analysisTask?.cancel()
        analysisTask = nil
        
        classificationBuffer.removeAll()
        rmsLevel = 0.0
        detectedSound = "Nenhum som detectado"
    }
    
    /// Escuta os resultados da análise do áudio
    private func listenToAudioAnalysis() {
        analysisTask = Task {
            for await result in audioAnalyzer.classificationStream {
                // Em vez de atualizar a UI diretamente, processa o resultado no buffer.
                self.updateStableSound(with: result)
            }
        }
    }
    
    // MARK: - Nova Função para Estabilizar o Resultado
    /// Processa uma nova classificação, atualizando o buffer e determinando o som mais frequente.
    private func updateStableSound(with newClassification: SoundClassification) {
        // Adiciona a nova classificação ao buffer
        classificationBuffer.append(newClassification)
        
        // Mantém o buffer com o tamanho definido (janela deslizante)
        if classificationBuffer.count > BUFFER_SIZE {
            classificationBuffer.removeFirst()
        }
        
        // 1. Contar a frequência de cada identificador de som no buffer
        let counts = classificationBuffer.reduce(into: [:]) { counts, classification in
            counts[classification.identifier, default: 0] += 1
        }
        
        // 2. Encontrar o identificador mais frequente
        guard let mostFrequentIdentifier = counts.max(by: { $0.value < $1.value })?.key else {
            return
        }
        
        // 3. Para obter a confiança mais recente, busca a última ocorrência da classificação mais frequente
        if let latestOccurrence = classificationBuffer.last(where: { $0.identifier == mostFrequentIdentifier }) {
            let stableSoundResult = "\(latestOccurrence.identifier) (\(String(format: "%.2f", latestOccurrence.confidence * 100))%)"
            
            // 4. Atualiza a UI somente se o som estável mudou, evitando atualizações desnecessárias
            if self.detectedSound != stableSoundResult {
                self.detectedSound = stableSoundResult
            }
        }
    }
    
    /// Calcula o RMS de um buffer de áudio
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
