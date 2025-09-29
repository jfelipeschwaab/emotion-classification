import Foundation
@preconcurrency import SoundAnalysis
import AVFoundation

/// Um tipo de dado simples e seguro para transferir os resultados, evitando problemas de concorrência.
struct SoundClassification: Sendable {
    let identifier: String
    let confidence: Double
}



@available(macOS 10.15, *)
final class AudioAnalyzer: NSObject, Sendable {
    ///Variável que lida com o áudio, analisando-os nas funções abaixo
    private let streamContinuation: AsyncStream<SoundClassification>.Continuation
    
    ///Canal que recebe os dados já analisados.
    let classificationStream: AsyncStream<SoundClassification>

    
    ///Variável responsável por analisar as faixas de áudio e classificar via request de acordo com o modelo CreateML
    private let analyzer: SNAudioStreamAnalyzer
    
    ///Variável que gerencia todo o fluxo de áudio, entrada, mixer e saída.
    private let audioEngine = AVAudioEngine()

    override init() {
        var continuation: AsyncStream<SoundClassification>.Continuation!
        self.classificationStream = AsyncStream { continuation = $0 }
        self.streamContinuation = continuation
        
        ///Utilizamos a entrada principal de áudio do dispositivo
        let inputFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        
        ///Analiza as stream de audio por meio do formato inserido, e provê resultados para a classe
        self.analyzer = SNAudioStreamAnalyzer(format: inputFormat)
        
        super.init()
        setupModel()
    }
    ///Essa função é responsável por fornecer as regras da análise, por meio de um request, para utilizar o modelo ML treinado
    ///- WARNING: Modelo CreateML  precisa estar inicializado corretamente, associado ao target do projeto.
    private func setupModel() {
        do {
            let model = try ModeloTreinado(configuration: MLModelConfiguration())
            let request = try SNClassifySoundRequest(mlModel: model.model)
            try analyzer.add(request, withObserver: self)
        } catch {
            print("ERRO AO CARREGAR MODELO: \(error)")
        }
    }

    ///Função responsável por inicializar a captura de áudio em tempo real, definindo valores de buffer, e entradas de áudio.
    func start() {
        let inputFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) { [weak self] buffer, time in
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

@available(macOS 10.15, *)
extension AudioAnalyzer: SNResultsObserving {
    
    ///Função responsável por entregar as análises feitas para a variável streamContinuation, que, por sua vez, é responsável por fornecer os dados já analisados.
    ///- WARNING: Essa função não pode pertencer a um único thread exclusivamente, ela é non-isolated.
    func request(_ request: SNRequest, didProduce result: SNResult) {
        if let classificationResult = result as? SNClassificationResult,
           let classification = classificationResult.classifications.first {
            let result = SoundClassification(identifier: classification.identifier, confidence: classification.confidence)
            streamContinuation.yield(result)
        }
    }
}

import Foundation

@available(macOS 10.15, *)

@MainActor
final class AudioViewModel: ObservableObject {
    
    // MARK: Variável utilizada para exibir na UI a emoção detectada
    @Published var detectedSound: String = "Nenhum som detectado"
    @Published private(set) var rmsLevel: Float = 0.0

    
    // MARK: Inicializadores de classe
    private let audioAnalyzer = AudioAnalyzer()
    private var analysisTask: Task<Void, Never>?

    init() {
        listenToAudioAnalysis()
    }
    
    ///Função que inicializa a análise do áudio
    func startAnalysis() {
        audioAnalyzer.start()
    }
    
    ///Função que escuta os resultados da análise do áudio, via Stream
    private func listenToAudioAnalysis() {
        analysisTask = Task {
            // O loop consome o stream de dados Sendable.
            for await result in audioAnalyzer.classificationStream {
                self.detectedSound = "\(result.identifier) (\(String(format: "%.2f", result.confidence * 100))%)"
            }
        }
    }
    
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
