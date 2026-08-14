# Snail observability

Snail's operational logs are structured JSON. They contain event names and
bounded operational fields only; they must never contain tokens, provider
keys, raw identities, conversation text, audio, or ciphertext.

## Signals

| Signal | Meaning | Alert/triage threshold |
| --- | --- | --- |
| `provider_request_failed` | Fish TTS request failed | Any sustained increase over the previous 15-minute baseline |
| `provider_unavailable` | OpenAI Realtime cannot be provisioned | Any occurrence in production |
| `client_provider_error` | An opted-in client observed a provider error code | Any occurrence clustered by provider and code |
| `auth_failure` | Worker or relay rejected authentication | Rate or route-specific spike |
| `rate_limit_hit` | A caller exceeded a route limit | Repeated hits from distinct sources |
| `quota_rejected` / `quota_exhausted` | A user or session reached its quota | Monitor by route and tier |
| `room_inactive_cleanup` / `room_cleanup` | Session lifecycle ended or timed out | Cleanup without a preceding expected end event |
| `room_lookup_failed` | A join could not resolve its room | Any sustained increase |

## Privacy boundary

The app's diagnostics switch is off by default. When enabled, the app sends
only provider, bounded context, and a sanitized error code to
`POST /api/telemetry`. The Worker rate-limits that endpoint and emits
`client_provider_error`; it discards free-form error text and unknown fields.

## Interpretation

An outage in a provider path is visible when `provider_request_failed`,
`provider_unavailable`, or a cluster of `client_provider_error` events rises
without requiring conversation content. Logs are evidence of operational
behavior; they do not replace a complete device-to-device session test.
