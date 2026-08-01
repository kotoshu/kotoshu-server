# kotoshu-server

Self-hostable HTTP API wrapping the [Kotoshu](https://github.com/kotoshu/kotoshu) spell checker.

## Status

MVP. Six endpoints over JSON. Rack/Sinatra + Puma. Pre-warms
languages on boot. Designed as the deployment surface for non-Ruby
SDKs (`kotoshu-python`, `kotoshu-js`, `kotoshu-go`).

See `TODO.impl/64-http-api-and-sdks.md` for the full plan.

## Install

```bash
gem install kotoshu-server
```

Or from source:

```bash
cd kotoshu-server && bundle install && bundle exec rake install
```

## Run

```bash
# Default: localhost:9292, English pre-warmed
kotoshu-server

# Custom port + multi-language pre-warm
KOTOSHU_SERVER_PORT=8080 \
KOTOSHU_SERVER_LANGUAGES="en de fr" \
  kotoshu-server
```

## Endpoints

| Method | Path | Body | Returns |
|---|---|---|---|
| `GET` | `/` | — | service metadata |
| `GET` | `/v1/health` | — | `{ status, ready, timestamp }` |
| `GET` | `/v1/version` | — | `{ server, kotoshu, ruby }` |
| `GET` | `/v1/languages` | — | `{ cached: [...] }` |
| `POST` | `/v1/check` | `{ text, language?, format? }` | `{ file, word_count, errors: [...] }` |
| `POST` | `/v1/suggest` | `{ word, language?, max? }` | `{ word, suggestions: [...] }` |
| `POST` | `/v1/detect` | `{ text }` | `{ language, confidence }` |

Each `error` and `suggestion` mirrors the lutaml-model serialization
(`word`, `distance`, `confidence`, `source`).

## curl examples

```bash
# Check a document
curl -X POST http://localhost:9292/v1/check \
  -H "Content-Type: application/json" \
  -d '{"text":"helo wrold","language":"en"}'

# Suggestions for one word
curl -X POST http://localhost:9292/v1/suggest \
  -H "Content-Type: application/json" \
  -d '{"word":"helo","language":"en","max":3}'

# Detect language
curl -X POST http://localhost:9292/v1/detect \
  -H "Content-Type: application/json" \
  -d '{"text":"bonjour le monde"}'
```

## Docker

```bash
docker build -t kotoshu-server .

docker run --rm -p 9292:9292 \
  -e KOTOSHU_SERVER_LANGUAGES="en de" \
  kotoshu-server
```

Healthcheck probes `/v1/health` every 30s.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `KOTOSHU_SERVER_PORT` | `9292` | Listen port |
| `KOTOSHU_SERVER_BIND` | `0.0.0.0` | Bind address |
| `KOTOSHU_SERVER_LANGUAGES` | `en` | Languages to pre-warm on boot |
| `KOTOSHU_SERVER_LAZY` | `0` | Skip pre-warm; load on first request |
| `KOTOSHU_SERVER_DEFAULT_LANG` | `en` | When client omits `language` |
| `KOTOSHU_SERVER_LOG_LEVEL` | `info` | `debug`/`info`/`warn`/`error` |
| `KOTOSHU_OFFLINE` | `1` (in Docker) | Never trigger downloads |

## OpenAPI

The full OpenAPI 3.1 spec is at [`openapi.yaml`](./openapi.yaml). Use
`openapi-generator` to spin up SDKs in Rust / .NET / Java.

## License

BSD-2-Clause, same as Kotoshu.
