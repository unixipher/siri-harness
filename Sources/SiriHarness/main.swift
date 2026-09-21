import Foundation
import SiriHarnessCore

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "serve"

switch command {
case "serve", "server":
    await handleServe(Array(arguments.dropFirst()))
case "ask":
    await handleAsk(Array(arguments.dropFirst()))
case "models":
    handleModels()
case "--help", "-h", "help":
    printUsage()
default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
}

func handleServe(_ arguments: [String]) async {
    var host = "127.0.0.1"
    var port: UInt16 = 8080

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if (argument == "--port" || argument == "-p"), index + 1 < arguments.count {
            if let parsedPort = UInt16(arguments[index + 1]) {
                port = parsedPort
            }
            index += 2
        } else if (argument == "--host" || argument == "-h"), index + 1 < arguments.count {
            host = arguments[index + 1]
            index += 2
        } else {
            index += 1
        }
    }

    print("SiriHarness: Starting server on http://\(host):\(port)")
    print("Model Endpoint: http://\(host):\(port)/v1")
    print("Health Check:   http://\(host):\(port)/health")

    let server = HTTPServer(host: host, port: port)
    do {
        try server.start()
    } catch {
        fputs("Error: Failed to bind to \(host):\(port): \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        server.stop()
        exit(0)
    }
    sigintSource.resume()
    signal(SIGINT, SIG_IGN)

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        server.stop()
        exit(0)
    }
    sigtermSource.resume()
    signal(SIGTERM, SIG_IGN)

    while true {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

func handleAsk(_ arguments: [String]) async {
    guard !arguments.isEmpty else {
        fputs("Usage: siri-harness ask <prompt> [--system <instructions>] [--temp <temperature>]\n", stderr)
        exit(1)
    }

    var prompt = ""
    var systemInstructions: String? = nil
    var temperature: Double? = nil

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if (argument == "--system" || argument == "-s"), index + 1 < arguments.count {
            systemInstructions = arguments[index + 1]
            index += 2
        } else if (argument == "--temp" || argument == "-t"), index + 1 < arguments.count {
            temperature = Double(arguments[index + 1])
            index += 2
        } else {
            if prompt.isEmpty {
                prompt = argument
            } else {
                prompt += " " + argument
            }
            index += 1
        }
    }

    let service = SiriModelService.shared
    let request = ChatCompletionRequest(
        model: "siri",
        messages: [
            ChatMessage(role: "system", content: systemInstructions ?? "You are a helpful assistant."),
            ChatMessage(role: "user", content: prompt)
        ],
        temperature: temperature,
        stream: true
    )

    do {
        let stream = try service.generateStream(request: request)
        for try await chunk in stream {
            if let delta = chunk.choices.first?.delta.content {
                print(delta, terminator: "")
                fflush(stdout)
            }
        }
        print()
    } catch {
        fputs("Error: Generation failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func handleModels() {
    print("Supported Models:")
    for model in SiriModelService.supportedModels {
        print("  \(model)")
    }
}

func printUsage() {
    print("""
    OVERVIEW: SiriHarness - Apple Foundation Model HTTP Bridge Server

    USAGE: siri-harness <subcommand> [options]

    SUBCOMMANDS:
      serve                 Start the HTTP service (default)
                            Options:
                              --host, -h <host>   Host address to bind (default: 127.0.0.1)
                              --port, -p <port>   Port number to bind (default: 8080)

      ask <prompt>          Perform a one-off model generation
                            Options:
                              --system, -s <text> System instructions
                              --temp, -t <value>  Sampling temperature

      models                Display available model identifiers
      help                  Show usage information
    """)
}
