# kotoshu-server

Self-hostable HTTP API wrapping the [Kotoshu](https://github.com/kotoshu/kotoshu) spell checker.

## Status

MVP. Six endpoints over JSON. Rack/Sinatra + Puma. Pre-warms
languages on boot. Designed as the deployment surface for non-Ruby
SDKs (`kotoshu-python`, `kotoshu-js`, `kotoshu-go`).

See `TODO.impl/64-http-api-and-sdks.md` for the full plan.

## Install

```bash
gem install kotoshu-server   # >= 0.1.1 (the 0.1.0 gem was empty — a gemspec file-list bug)
kotoshu-server
```

Or run from source:

```bash
cd kotoshu-server && bundle install && bundle exec exe/kotoshu-server
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

## Semantic models (opt-in)

By default the server is dictionary-only — exactly the 0.1.0
behavior. Semantic reranking is a boot-time opt-in; the server never
downloads a model implicitly:

```bash
KOTOSHU_SERVER_LANGUAGES="en de" \
KOTOSHU_SERVER_MODEL_LANGS="en" \
  kotoshu-server
```

- `KOTOSHU_SERVER_MODEL_LANGS` — languages the pre-warm thread sets
  up with spelling + semantic model (space separated). Unset means no
  models, no downloads, no behavior change.
- `KOTOSHU_SERVER_MODEL_TIER` — model tier to set up and resolve:
  `fluency` (default), `full`, or `mini`.

**Requires kotoshu >= 0.7.0.** Model tiers, the resource registry,
and the confidence cascade ship in the 0.7.0 cut. The gemspec keeps
its `kotoshu ~> 0.6` constraint (dependency floors are the owner's
decision), so the server checks the *installed* gem instead: setting
`KOTOSHU_SERVER_MODEL_LANGS` with an older kotoshu fails fast at
boot with a clear error, and explicit `"model": true` requests
return 503.

Once a language has a model set up, `POST /v1/check` accepts an
optional `"model": true|false` flag (default: whether the language
has a model set up server-side). With it on, each error's
suggestions are reranked by the semantic analyzer; the gem's
confidence cascade (`KOTOSHU_SEMANTIC_CASCADE_THRESHOLD`) decides per
word whether the ONNX rerank actually runs. `GET /v1/languages`
reports `"model": {"en": true}` per cached language.

Memory and latency: budget roughly 15 MB resident per language at
the default fluency tier (the full tier is far larger), plus
one-time model load on the first model-enabled request. Listing the
language in `KOTOSHU_SERVER_MODEL_LANGS` warms it at boot instead.

## Language detection

`POST /v1/detect` reports which engine answered in the `engine`
field:

- `"lid-176"` — the 176-language lid.176 model served through the
  kotoshu native extension (kotoshu >= 0.10.0). The model is set up
  lazily on the first detect — one download, never at boot, and
  never at all under `KOTOSHU_OFFLINE=1` without a cache (Docker
  defaults to offline).
- `"heuristic"` — the 7-language character-set heuristic (en, de,
  es, fr, pt, ru, ja), the fallback whenever lid-176 cannot serve:
  kotoshu < 0.10.0, a pure-Ruby install or `KOTOSHU_BACKEND=ruby`,
  or the model missing after a failed setup.

Set `KOTOSHU_DETECT=heuristic` to pin the heuristic regardless of
the installed gem — the 0.1.1 behavior, byte for byte.

## Endpoints

| Method | Path | Body | Returns |
|---|---|---|---|
| `GET` | `/` | — | service metadata |
| `GET` | `/v1/health` | — | `{ status, ready, timestamp }` |
| `GET` | `/v1/version` | — | `{ server, kotoshu, ruby }` |
| `GET` | `/v1/languages` | — | `{ cached, supported, model }` |
| `POST` | `/v1/check` | `{ text, language?, format?, model? }` | `{ file, word_count, errors: [...] }` |
| `POST` | `/v1/suggest` | `{ word, language?, max? }` | `{ word, suggestions: [...] }` |
| `POST` | `/v1/detect` | `{ text }` | `{ language, confidence, engine }` |

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
| `KOTOSHU_SERVER_MODEL_LANGS` | unset | Languages to set up with a semantic model (requires kotoshu >= 0.7) |
| `KOTOSHU_SERVER_MODEL_TIER` | `fluency` | Model tier for `KOTOSHU_SERVER_MODEL_LANGS` |
| `KOTOSHU_SERVER_LAZY` | `0` | Skip pre-warm; load on first request |
| `KOTOSHU_SERVER_DEFAULT_LANG` | `en` | When client omits `language` |
| `KOTOSHU_SERVER_LOG_LEVEL` | `info` | `debug`/`info`/`warn`/`error` |
| `KOTOSHU_DETECT` | `auto` | `heuristic` pins /v1/detect to the heuristic engine |
| `KOTOSHU_OFFLINE` | `1` (in Docker) | Never trigger downloads |

## OpenAPI

The full OpenAPI 3.1 spec is at [`openapi.yaml`](./openapi.yaml). Use
`openapi-generator` to spin up SDKs in Rust / .NET / Java.

## License

BSD-2-Clause, same as Kotoshu.
