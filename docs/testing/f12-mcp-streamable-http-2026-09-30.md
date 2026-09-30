# F12 MCP Streamable HTTP lifecycle boundary — 30 September 2026

## Production contract

The existing Larenor administrator-created grant remains the only credential
authority. A request must carry both its bearer token and the exact
`X-Larenor-MCP-Client` identity, and Core rechecks the sealed grant, account,
session family, expiry and Core/home context inside the current database
transaction. The required `notifications/initialized` lifecycle message now
uses that same live check before Core returns an empty HTTP 202 response.

The endpoint implements the bounded, non-streaming subset of Streamable HTTP:

- `initialize`, `ping`, `tools/list` and `tools/call` return one JSON object;
- `notifications/initialized` is accepted with HTTP 202 and no body;
- any browser `Origin` is rejected because Larenor has no configured browser
  origin allowlist for this private endpoint;
- the initialize request accepts a bounded ISO-date protocol offer and returns
  the server's fixed supported `2025-06-18` version; subsequent
  `MCP-Protocol-Version: 2025-06-18` headers are accepted and an explicit
  unsupported header returns HTTP 400;
- the standard top-level `_meta` member is accepted on initialize, initialized
  and tool-call parameters while every model remains extra-field-forbidden and
  bounded;
- invalid request objects, unknown methods and invalid parameters use the
  JSON-RPC `-32600`, `-32601` and `-32602` responses with the correct request
  identifier where it is known;
- malformed, duplicate-key, non-finite or over-deep JSON keeps the shared
  bounded parser and returns JSON-RPC `-32700`; the existing 8 KiB request cap
  still returns HTTP 413 before parsing;
- omitted protocol-version headers remain accepted for existing Larenor grant
  clients. New standards-oriented clients send the negotiated header.

GET is intentionally not used for server-initiated SSE and therefore retains
the framework's HTTP 405 behavior, which the Streamable HTTP specification
allows. Larenor does not issue an MCP session identifier and does not advertise
server-to-client requests or notifications.

## Authority boundary

This is a custom, manually provisioned bearer grant. It is not OAuth 2.1, does
not publish Protected Resource Metadata or an authorization-server discovery
document, and makes no claim that an arbitrary MCP client can acquire its own
credential. An MCP client must support preconfigured bearer credentials and
the Larenor client-identity header. Adding the standard MCP OAuth discovery and
issuance flow is a separate product/security decision rather than something
inferred from the existing token.

Primary contracts:

- [MCP 2025-06-18 Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
- [MCP 2025-06-18 lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle)
- [MCP 2025-06-18 authorization](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
- [JSON-RPC 2.0 error responses](https://www.jsonrpc.org/specification)

## Focused evidence

TDD red run:

```text
PYTHONPATH=server server/.venv/bin/python -m pytest -q \
  server/tests/test_f12_mcp_streamable_http.py --tb=short
3 failed
```

The failures reproduced notification validation before authority (`400`
instead of `401/202`), missing Origin rejection (`200`) and unknown-method
validation as a generic HTTP 400.

Green repository run:

```text
PYTHONPATH=server server/.venv/bin/python -m pytest -q \
  server/tests/test_f12_mcp_streamable_http.py \
  server/tests/test_f12_mcp_gateway_normal_core.py \
  server/tests/test_api_boundary.py --tb=short
20 passed
```

The focused gate covers initialize then initialized, missing/wrong/revoked
authority, empty 202 followed by `tools/list` for the manually provisioned
client, Origin rejection, protocol-version rejection, method and
parameter/parse errors, a newer valid protocol offer, standard `_meta`,
duplicate-key and size rejection, the existing fixed
tool catalog, restart, expiry, account authority changes, preview/confirm
replay, revoke and sealed-store tamper. The shared boundary regression suite
shows that non-MCP endpoints retain their existing static error envelopes. The
repository's locked Server environment does not include the official MCP
Python SDK, so production dependencies were left unchanged.

Official SDK acceptance used a disposable `/tmp` environment with an exact
`mcp==2.2.0` input, resolved by `uv` together with the production Server's
FastAPI, Uvicorn and crypto versions. The current stable SDK tag is
[`v2.2.0`](https://github.com/modelcontextprotocol/python-sdk/tree/v2.2.0)
(`9972c21aa42054fb1450c5fc614761ed11847ec6`). Its generated lock receipt was
SHA-256
`b389cae19340075b9e66cebeb27fd5ec66eedd699782fc178d85186617d821a0` and the
installed freeze receipt was
`338a3fabf8d25a673cc991806fe286aa713317d62cbf1716f13f9b9e65b6e8b2`.

```text
/tmp/larenor-f12-sdk-venv-220/bin/python \
  server/tests/support/f12_mcp_sdk_acceptance.py
{'sdk': 'mcp==2.2.0', 'protocol': '2025-06-18',
 'tools': ['home.resource_count.read'], 'revokedStatus': 401}
```

That runner starts normal `create_app` under a real loopback Uvicorn server,
logs in through HTTP, creates the grant through HTTP, then uses the SDK's
`streamable_http_client` and `ClientSession`. The SDK sends initialize and the
initialized notification, lists the fixed tool catalog, and observes HTTP 401
after the administrator revokes the grant. The SDK's newer `2025-11-25`
protocol offer and standard `_meta` member first reproduced `Invalid params`;
the bounded negotiation and metadata changes above are the direct regression
fixes. The SDK receives the custom bearer and client header via its supported
`httpx2.AsyncClient` injection point. This still does not claim OAuth discovery
or credential acquisition interoperability.
