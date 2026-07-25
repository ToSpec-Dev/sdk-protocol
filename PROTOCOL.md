# ToSpec ingest protocol (v1)

This is the wire contract a ToSpec production SDK speaks. It is small on purpose: two
HTTP endpoints, one signature scheme, one JSON envelope. If your SDK reproduces the golden
[`fixtures/`](fixtures/) it is wire-compatible with the ToSpec ingest edge.

The reference implementation is [`ToSpec-Dev/sdk-dotnet`](https://github.com/ToSpec-Dev/sdk-dotnet)
(`ToSpec.Sdk`). The redaction engine both it and the gateway share is
[`ToSpec-Dev/redact-dotnet`](https://github.com/ToSpec-Dev/redact-dotnet) (`ToSpec.Redact`), with a
Node port at `ToSpec-Dev/redact-node`.

## The one hard rule

**Redaction happens before transmission.** The SDK applies the compiled ruleset to every
request/response body *inside the provider's process*, and only the redacted bytes are ever
put on the wire. Bodies without a structured redactor (anything but JSON/XML), bodies that
fail to parse, and any traffic seen before a ruleset has been fetched are **dropped**, never
sent raw. A conformant SDK must uphold this; the redaction fixtures pin exactly what
"redacted" means for each rule.

---

## 1. Endpoints

Both are rooted at the ingest base URL (e.g. `https://ingest.tospec.net`).

| Method & path | Purpose | Auth |
|---|---|---|
| `POST /v1/ingest` | Submit a batch of redacted events | Ingest key **+ body signature** |
| `GET /v1/sdk/config` | Fetch ruleset + sampling + kill switch | Ingest key |

### Auth credential

Every request carries the per-tenant ingest key in a header:

```
X-ToSpec-Ingest-Key: tsp_ing_<opaque>
```

The server stores only `SHA-256(key)`, so the key is both a bearer credential (for the
config GET) and the HMAC secret (for the ingest POST). Keep it secret; it is not the
redaction key (see §5).

---

## 2. `POST /v1/ingest`

Body: the batch JSON (see §4), **gzipped**, with:

```
Content-Encoding: gzip
Content-Type: application/json
X-ToSpec-Ingest-Key: tsp_ing_<opaque>
X-ToSpec-Signature: sha256=<hex>
```

Gzip is recommended but optional; if you omit it, omit `Content-Encoding` and sign the raw
JSON bytes.

### Signature

```
wire      = gzip(utf8(batch_json))          # or utf8(batch_json) with identity encoding
mac       = HMAC_SHA256(key = utf8(ingest_key), message = wire)
signature = "sha256=" + lowercase_hex(mac)
```

**Sign the exact bytes you transmit** — the server verifies the signature *before* it
decompresses, so if you gzip, you sign the gzipped bytes. The signed-batch fixtures in
[`fixtures/batches/`](fixtures/batches/) use **identity** encoding so the signable bytes are
reproducible in any language (gzip output is implementation-specific); your SDK's HMAC of a
fixture's `canonical_json` must equal its `signature`.

### Idempotency

`batch_id` (a UUID field in the body) is the idempotency key. Re-POSTing a completed
`batch_id` returns `200` with `"replayed": true`, `"ingested": 0`, and a
`Idempotency-Replayed: true` response header. Safe to retry on network failure.

The server retains completed batch claims for **at least 48 hours**. SDKs generate a new
UUIDv7 for every new logical batch, retain the same ID and exact wire bytes across bounded
retries, and must not reuse a batch ID after that retry horizon. This makes the platform's
retention limit explicit instead of implying permanent global deduplication.

### Responses

| Status | Meaning | SDK action |
|---|---|---|
| `200` | Accepted (`{ "batch_id", "ingested", "replayed" }`) | done |
| `401` | `missing_ingest_key` / `invalid_ingest_key` / `invalid_signature` | fix config; do not retry blindly |
| `403` | `ingest_disabled` (kill switch) | stop emitting; the config poll will confirm |
| `429` | `rate_limited` | back off |
| `413` | `batch_too_large` | send smaller batches |
| `400` | `malformed_batch` or a specific field reason | drop batch (a bug) |
| `409` | `idempotent_request_in_flight` | retry later |
| `422` | `unknown_partner` | check partner resolution |
| `5xx` | server error | drop or retry with backoff (bounded) |

Errors share the shape `{ "error": "<code>" }`.

---

## 3. `GET /v1/sdk/config`

Auth is the ingest key alone (no signature — there is no body). Poll it every few seconds.

Send the last `ETag` you saw as `If-None-Match`; an unchanged config answers **`304 Not
Modified`** with an empty body (the steady-state, near-free path). A change — a new ruleset
version, a sampling edit, or the **kill switch** — answers `200` with a fresh `ETag`.

`200` body (snake_case):

```json
{
  "ruleset_version": 3,
  "compiled": { "schema": 1, "...": "..." },
  "sampling_rules": { "errors": 100, "success": 5 },
  "kill_switch": false
}
```

- `ruleset_version` — stamp this onto every event's `redaction_version`. `0` = no ruleset
  published (⇒ drop bodies, send metadata only).
- `compiled` — the compiled redaction ruleset (schema v1). Omitted entirely when none is
  published. Feed it verbatim to your redaction engine's deserializer. **Reject an unknown
  `schema`** and keep serving your last-good ruleset — never apply rules you cannot fully
  honor.
- `sampling_rules` — percentages, e.g. `{"errors":100,"success":5}` = keep 100% of error
  responses (status ≥ 400), 5% of successes. Missing field ⇒ 100%. The SDK enforces this;
  the server does not.
- `kill_switch` — `true` means stop emitting immediately. Because it is folded into the
  `ETag`, a flip reaches you within one poll.

---

## 4. Batch envelope

```jsonc
{
  "batch_id": "<uuid>",
  "events": [
    {
      "event_id":      "<uuid>",
      "partner_id":    "<uuid>",        // which counterparty called the provider's API
      "ts":            "2026-01-01T00:00:00+00:00",
      "direction":     "inbound",        // inbound | outbound
      "method":        "POST",
      "path":          "/v1/reservations",
      "status":        201,
      "latency_ms":    17,
      "req_headers":   { "Accept": "application/json" },
      "resp_headers":  { "Content-Type": "application/json" },
      "req_body":      "<base64 of already-redacted bytes>",   // omit when none/dropped
      "resp_body":     "<base64 of already-redacted bytes>",
      "req_size":      42,               // original (pre-redaction) size, when known
      "resp_size":     128,
      "content_format":"json",           // json | xml | text | binary
      "redaction_version": 3
    }
  ]
}
```

- **snake_case** property names; omit null fields.
- `tenant_id` / `api_id` are **never** sent — the server derives them from the ingest key.
- Bodies are base64 of the **redacted** bytes. `content_format` tells the server how to
  interpret them; it never re-redacts.
- Protocol v1 has one `content_format` for the exchange. If both retained bodies are
  structured but have different formats, a conformant v1 SDK keeps the request body and
  drops the response body (or drops one body by an equivalent deterministic policy); it
  must never label mixed JSON/XML bytes with one format. Per-side formats are reserved for
  protocol v2.
- Header maps are redacted too: auth-shaped headers (`Authorization`, `X-Api-Key`, `Cookie`,
  `Proxy-Authorization`, `Set-Cookie`, `WWW-Authenticate`, …) are stripped unconditionally;
  ruleset `headers.strip`/`headers.hash` add to that.

### Canonical JSON (for the golden batches)

The signed-batch fixtures fix an exact byte string in `canonical_json`: snake_case keys,
UTF-8, no insignificant whitespace, arrays in the given order, lowercase UUIDs, timestamps
as ISO-8601 with offset. To *pass* a batch fixture you only need to HMAC the provided
`canonical_json` and match `signature` — you do not need to reproduce the serializer. To
prove your own serializer is wire-correct, serialize the same logical events and compare to
`canonical_json`.

---

## 5. Redaction & tokens

The SDK never invents redaction — it applies the compiled ruleset from §3 with the
per-tenant **redaction HMAC key** (supplied to the SDK out of band, from the provider's
ToSpec portal; it is *not* the ingest key and is *not* served by the config endpoint). Using
the same key the gateway uses makes tokens join across the certification and production
paths.

Deterministic tokenization (the `hash` action):

```
token = "tsr_v" + key_version + "_" + base32_nopad_lower(HMAC_SHA256(redaction_key, value_utf8))
```

Full 32-byte digest → 52 lowercase base32 chars (RFC 4648 alphabet `a-z2-7`, no padding).
Same key version + value ⇒ same token. The [`fixtures/tokens.json`](fixtures/tokens.json)
vectors pin this exactly; the [`fixtures/redaction/`](fixtures/redaction/) vectors pin the
full engine (path rules, mask shapes, drop, free-text PAN/email detectors, XML, and the
malformed-input drop) as byte-exact input→output pairs.

### Key rotation runbook

Redaction keys never travel over the ingest/config channel. Rotation is an explicit
out-of-band deployment:

1. provision key version `N+1` in the portal/provider secret manager;
2. deploy or restart every SDK instance with the new key bytes and `key_version=N+1`;
3. verify emitted `tsr_v{N+1}_…` tokens and fleet convergence;
4. only then retire version `N` after the configured capture-retention window.

Ruleset changes are independent and may roll before or after the key deployment. During a
mixed-fleet rollout, tokens deliberately carry their version and are not compared across
versions. A platform must not remotely request a key version the SDK has not received out
of band.

See [`README.md`](README.md) for how to run the fixtures as a conformance suite in your
language.
