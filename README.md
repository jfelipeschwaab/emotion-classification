# EmotionClassification

![Swift](https://img.shields.io/badge/Swift-6.1-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20macOS-blue.svg)
![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)

Um pacote Swift para análise e classificação de emoções em tempo real a partir do áudio do microfone, projetado para integração fácil com SwiftUI.

Este pacote fornece uma arquitetura robusta e segura, utilizando as mais recentes funcionalidades do Swift Concurrency (`AsyncStream` - *Um tipo em Swift que permite criar e consumir sequências de dados assíncronas, funcionando como uma ponte entre o modelo de programação tradicional baseado em retornos de chamada (callback) e a nova simultaneidade estruturada (com async/await) do Swift.*, `@MainActor` - *Um atributo introduzido no Swift 5.5 como um ator global que fornece um executor que realiza suas tarefas na thread principal.*) para garantir que a análise de áudio em background e as atualizações da UI ocorram de forma eficiente.

## Funcionalidades

- **Análise de Áudio em Tempo Real**: Captura o áudio do microfone e o analisa continuamente.
- **Modelo de Machine Learning Incluso**: Vem com um modelo pré-treinado (`ModeloTreinado.mlmodel`) para classificação de emoções.
- **Integração Simples com SwiftUI**: Usa a `AudioViewModel` como um `ObservableObject` para conectar facilmente sua UI aos resultados da análise.
- **Arquitetura Moderna e Segura**: Utiliza Swift Concurrency para uma comunicação segura entre a thread de análise de áudio e a thread principal da UI.

## Requisitos

- iOS 14.0+
- macOS 11.0+
- Xcode 13.2+
- Swift 6.1+

## Permissões necessárias 

Adicione no seu Info.plist:

<key>NSMicrophoneUsageDescription</key>
<string>Adicione aqui a descrição que explica porquê você precisa acessar o microfone</string>

exemplo: 
<string>Este app precisa do microfone para classificar emoções em tempo real.</string>

Sem essa permissão, o app não terá acesso ao microfone.

## Exemplo mínimo 

```swift
import SwiftUI
import EmotionClassification

struct ContentView: View {
    @StateObject var audioVM = AudioViewModel()

    var body: some View {
        VStack {
            Text(audioVM.detectedSound)
                .padding()
            Button("Iniciar Análise") {
                audioVM.startAnalysis()
            }
        }
    }
}

