# ToSpec SDK protocol & conformance fixtures

**The wire contract and golden test vectors for ToSpec production SDKs.** If you are porting
a ToSpec SDK to a new language — PHP, Python, Go, Ruby — this repo is your specification and
your test suite. Make the fixtures pass and your port is provably wire-compatible with the
ToSpec ingest edge and byte-identical to the reference SDK.

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

- **[`PROTOCOL.md`](PROTOCOL.md)** — the full wire contract: two endpoints, the HMAC
  signature recipe, the batch envelope, the config poll, and the redaction/token formats.
- **[`fixtures/`](fixtures/)** — language-neutral golden vectors. Every value is a fixed
  constant (no clocks, no randomness) so any implementation can reproduce them exactly.

The reference implementation is [`ToSpec-Dev/sdk-dotnet`](https://github.com/ToSpec-Dev/sdk-dotnet),
which generates these fixtures from its own code — so they are exactly what a real ToSpec
SDK produces, not a hand-written approximation.

## What a ToSpec SDK does

It runs as middleware inside a provider's API process. For each request it clones the
metadata and (optionally) the bodies, **redacts them locally before anything leaves the
process**, and ships gzip-signed batches to `POST /v1/ingest` on a background worker. It
polls `GET /v1/sdk/config` for the redaction ruleset, sampling rules, and a kill switch. The
hard guarantees — never block the request thread, bounded memory, swallow every fault — are
the SDK's job; this repo pins the parts that must be **identical across languages**: the
redaction output, the token format, and the signed-batch bytes.

## The fixtures

```
fixtures/
  manifest.json                  index + schema versions
  tokens.json                    HMAC token vectors: value + key → tsr_v{n}_… token
  malformed.json                 binary malformed UTF-8/empty/DTD vectors
  redaction/*.json               golden redaction: input → redacted output (the parity anchor)
  batches/*.json                 golden signed batches: canonical JSON + expected signature
```

### `tokens.json` — deterministic tokenization

Each entry: `key_hex`, `key_version`, `value`, `token`. Compute
`"tsr_v" + key_version + "_" + base32_nopad_lower(HMAC_SHA256(hex→bytes(key_hex), utf8(value)))`
and assert it equals `token`. (Base32 = RFC 4648 alphabet `a-z2-7`, no padding, full 32-byte
digest → 52 chars.)

### `redaction/*.json` — the engine, byte for byte

Each vector carries a `compiled_ruleset` (the schema-v1 jsonb the config endpoint serves),
an `hmac_key_hex` + `hmac_key_version`, and either:

- **`kind: "body"`** — `content_format`, `body_in`, `body_out`. Feed `body_in` and the
  compiled ruleset to your redaction engine; the output must equal `body_out`. When
  `malformed` is `true`, the engine must reject the input and your SDK must **drop** the body
  (`body_out` is `null`).
- **`kind: "headers"`** — `is_request`, `headers_in`, `headers_out`. Apply header strip/hash
  (auth defaults + ruleset lists); the result must equal `headers_out`.

These are the cross-language parity anchors: `redact-dotnet` and `redact-node` both reproduce
them, so any new port that matches them is provably running the same engine.

### `batches/*.json` — the signature

Each: `ingest_key`, `canonical_json`, `signature`. Two checks:

1. **Signature (required to be wire-compatible):**
   `"sha256=" + lowercase_hex(HMAC_SHA256(utf8(ingest_key), utf8(canonical_json)))`
   must equal `signature`. This proves your signer is correct without needing to reproduce
   gzip or the exact serializer.
2. **Serializer (proves your batch builder is wire-correct):** serialize the same logical
   events yourself and compare to `canonical_json` (snake_case keys, omit-null, no extra
   whitespace, lowercase UUIDs, ISO-8601 timestamps).

## Certifying your port — a worked checklist

Write a small test that, for your language's HMAC/base32/JSON:

1. **Tokens.** For every entry in `tokens.json`, assert your tokenizer reproduces `token`.
2. **Redaction.** For every `redaction/*.json`, load `compiled_ruleset` into your engine and
   assert `body_in → body_out` (or a dropped body when `malformed`), and `headers_in →
   headers_out` for header vectors.
   Decode every `malformed.json` `body_base64` value as raw bytes and require a malformed
   result; do not pass through a replacement-character UTF-8 decoder first.
3. **Signatures.** For every `batches/*.json`, assert your HMAC of `canonical_json` equals
   `signature`.
4. **Round-trip.** Build a batch from your own captured events, sign it, POST it to a test
   ingest endpoint (or a recorded stub) and expect `200`.

If all four pass, your SDK speaks the protocol. Wire it to the hard guarantees in
[`PROTOCOL.md`](PROTOCOL.md) §"The one hard rule" (redaction-before-transmission, bounded
memory, never block the request thread, kill switch within one poll) and you have a
production-grade ToSpec SDK.

## Existing SDKs & planned ports

Shipping today:

- **.NET** — [`ToSpec-Dev/sdk-dotnet`](https://github.com/ToSpec-Dev/sdk-dotnet) (reference implementation)
- **Node** — [`ToSpec-Dev/sdk-node`](https://github.com/ToSpec-Dev/sdk-node)

Planned, in rough priority order. Ordering follows forecast demand, not a schedule — **we
build the next port when partners ask for it**, so if you need one, 👍 its issue (or open
one for a language not listed):

| Language | Middleware target | Status |
|---|---|---|
| PHP | PSR-15 / Laravel | [express interest](https://github.com/ToSpec-Dev/sdk-protocol/issues) |
| Python | ASGI (FastAPI / Django) | [express interest](https://github.com/ToSpec-Dev/sdk-protocol/issues) |
| Java | Servlet filter / Spring | [express interest](https://github.com/ToSpec-Dev/sdk-protocol/issues) |
| Go | `net/http` middleware | [express interest](https://github.com/ToSpec-Dev/sdk-protocol/issues) |
| Ruby | Rack | [express interest](https://github.com/ToSpec-Dev/sdk-protocol/issues) |

Don't want to wait? This repo is the spec and the test suite — a community port that passes
the checklist above is provably wire-compatible, and we're glad to review and link
conformant ports here.

## Consumer gates

`scripts/verify-consumers.sh` rejects byte drift in every vendored fixture tree.
`scripts/verify-versions.sh` rejects stale bundled redactors, mismatched SDK versions,
and missing .NET local packages. Both run in this authority repository's consumer CI.

## Versioning

The `schema` block in `manifest.json` versions each fixture family. Formats are wire
contracts: changes are **additive and schema-versioned only**. A reader that meets a schema
it does not know must reject it rather than guess.

## License

[Apache-2.0](LICENSE). Fixtures and protocol docs are free to use in any SDK port,
commercial or otherwise. Learn more at [tospec.dev](https://tospec.dev).
