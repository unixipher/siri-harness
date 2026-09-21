# SiriHarness

SiriHarness bridges Apple's on-device Siri Foundation Model and Apple Intelligence (`FoundationModels` framework) to a standard OpenAI-compatible HTTP service.

This enables developers and researchers to evaluate, benchmark, and integrate Apple's on-device foundation models using standard LLM evaluation harnesses, agent frameworks, and clients:
- Evaluation Frameworks: Promptfoo, inspect_ai, lm-evaluation-harness
- Agent Frameworks: LangChain, LlamaIndex, AutoGen
- Client Libraries: Official OpenAI Python/TypeScript SDKs, cURL, LiteLLM

---

## Features

- **OpenAI Compatible**: Implements `/v1/chat/completions` and `/v1/models` endpoints.
- **Real-Time Streaming**: Emits Server-Sent Events (`text/event-stream`) token-by-token.
- **Multi-Turn Context**: Maps conversation history to native `Transcript` instances to preserve chat context.
- **Zero Third-Party Dependencies**: Built exclusively on native Apple frameworks (`FoundationModels`, `Network.framework`).
- **Command-Line Interface**: Supports interactive one-off generations (`siri-harness ask`) and daemon server operation.
- **Cross-Origin Resource Sharing**: Provides preflight `OPTIONS` and CORS headers for browser-based tools.

---

## Requirements

- macOS 15.0 or later with Apple Intelligence support
- Apple Silicon (M-series processor)
- Xcode 16.0 or Swift 6.0 toolchain

---

## Quick Start

### 1. Build

```bash
make build
```

### 2. Start the HTTP Bridge Server

```bash
# Start server on default port 8080 (http://127.0.0.1:8080)
./bin/siri-harness serve

# Custom host and port
./bin/siri-harness serve --host 0.0.0.0 --port 9000
```

### 3. One-Off Command-Line Query

```bash
./bin/siri-harness ask "Explain Swift actors in one sentence."
```

---

## Client Integration Examples

### OpenAI Python SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8080/v1",
    api_key="siri-local-key"
)

# Synchronous Completion
response = client.chat.completions.create(
    model="siri",
    messages=[
        {"role": "system", "content": "You are a concise assistant."},
        {"role": "user", "content": "What are three benefits of Swift?"}
    ]
)
print(response.choices[0].message.content)

# Streaming Completion
stream = client.chat.completions.create(
    model="siri",
    messages=[{"role": "user", "content": "Count from 1 to 5."}],
    stream=True
)
for chunk in stream:
    delta = chunk.choices[0].delta.content
    if delta:
        print(delta, end="", flush=True)
```

---

### Promptfoo Evaluation Harness

Configure `promptfooconfig.yaml`:

```yaml
description: "Apple Intelligence Model Evaluation"

prompts:
  - "Answer concisely: {{question}}"

providers:
  - id: "openai:chat:siri"
    config:
      apiBaseUrl: "http://127.0.0.1:8080/v1"
      apiKey: "siri"

tests:
  - vars:
      question: "What is the speed of light in vacuum?"
    assert:
      - type: contains
        value: "299,792"
```

Execute the evaluation:
```bash
npx promptfoo eval
```

---

### cURL

#### Health Check
```bash
curl http://127.0.0.1:8080/health
```

#### List Models
```bash
curl http://127.0.0.1:8080/v1/models
```

#### Chat Completion
```bash
curl -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "siri",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello"}
    ],
    "temperature": 0.7
  }'
```

#### Streaming Completion
```bash
curl -N -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "siri",
    "messages": [
      {"role": "user", "content": "Write a haiku about code."}
    ],
    "stream": true
  }'
```

---

## API Specification

| Method | Path | Description |
| :--- | :--- | :--- |
| `GET` | `/health` | Service health status and supported models |
| `GET` | `/v1/models` | OpenAI-compatible model listing |
| `POST` | `/v1/chat/completions` | Chat completions (synchronous or SSE streaming) |
| `OPTIONS` | `*` | CORS preflight handling |

---

## Testing

Run unit tests:

```bash
make test
```

---

## Architecture

```
siri-harness/
├── bin/
│   └── siri-harness            # CLI entry point wrapper
├── Sources/
│   ├── SiriHarness/            # CLI executable target
│   │   └── main.swift
│   └── SiriHarnessCore/        # Core framework target
│       ├── Model/
│       │   └── SiriModelService.swift   # FoundationModels integration
│       ├── OpenAI/
│       │   └── OpenAISchema.swift       # OpenAI-compatible data transfer objects
│       └── Server/
│           └── HTTPServer.swift         # Network.framework HTTP 1.1 / SSE engine
├── Tests/
│   └── SiriHarnessTests/       # Swift Testing suite
├── Makefile
└── Package.swift
```

---

## License

MIT License.
