# Home Assistant API coverage

Audited 2026-09-04. Read-only compatibility checked against Home Assistant **2026.8.3**. This document describes the implementation in this repository, not a promise of native parity with every Home Assistant frontend panel or integration.

Larenor has four distinct levels of support:

- **Native UI:** an app screen, control or form implements the workflow.
- **Client method:** Dart code exposes the operation with its expected request/response shape.
- **API console:** authenticated JSON/text REST requests and WebSocket commands/subscriptions can reach additional server APIs. The operator supplies the command and valid parameters.
- **Official frontend:** an embedded Home Assistant page covers remaining server-specific workflows through its own login. Larenor does not inject its long-lived API token into the page or browser storage. This is a web interface, not a native implementation of those workflows.

Availability and permission checks belong to the connected server. An absent integration can mean an endpoint does not exist. A generic command transport does not guarantee that every integration, server version, selector or frontend extension is supported.

## Documented REST surface

The client implements the routes listed in the [official REST API reference](https://developers.home-assistant.io/docs/api/rest/). The matrix separates those methods from their UI exposure. Paths are relative to the configured server and preserve any reverse proxy prefix.

| Method and route | Client method | Native UI exposure |
| --- | --- | --- |
| `GET /api/` | `checkConnection` | Connection validation |
| `GET /api/config` | `getConfig` | Server information tool |
| `GET /api/components` | `getComponents` | API console; component list is also present in server configuration |
| `GET /api/services` | `getServices` | Searchable live Actions catalog and generated parameter forms |
| `GET /api/events` | `getEvents` | Events tool |
| `GET /api/states` and `/api/states/{entity_id}` | `getStates`, `getState` | Home/entity screens; raw lookup through API console |
| `POST /api/states/{entity_id}` | `setState` | API console; no dedicated state override editor |
| `DELETE /api/states/{entity_id}` | `deleteState` | API console; no dedicated state removal editor |
| `POST /api/services/{domain}/{service}` | `callService`, `callServiceWithResponse` | Accessory controls and dynamic Actions forms, including service response display |
| `POST /api/events/{event_type}` | `fireEvent` | API console; Events tool itself lists/listens |
| `GET /api/history/period[/{timestamp}]` | `getHistory` | History tool plus numeric dashboard history cards with real gaps |
| `GET /api/logbook[/{timestamp}]` | `getLogbook` | Logbook tool with entity and time range inputs; JSON results |
| `GET /api/calendars` and `/api/calendars/{entity_id}` | `getCalendars`, `getCalendarEvents` | Calendar list/event query tool; no calendar event editor |
| `POST /api/template` | `renderTemplate` | Template tool; text result |
| `GET /api/error_log` | `getErrorLog` | Logs tool; text result |
| `POST /api/config/core/check_config` | `checkConfig` | Configuration check tool |
| `POST /api/intent/handle` | `handleIntent` | API console; no dedicated intent or voice conversation UI |
| `GET /api/camera_proxy/{entity_id}` | `getCameraImage` / `getBytes` | Camera image viewer; this method returns bytes |

`requestJson` and `requestText` support GET, POST, PUT, PATCH, DELETE, HEAD and OPTIONS, query parameters, JSON bodies and additional non-credential headers. The native console exposes GET/POST/PUT/PATCH/DELETE with JSON object input and JSON/text output. Multipart uploads, arbitrary binary request bodies, downloads and streaming HTTP responses are not implemented by this console.

### Response and request details verified against Core

The Actions catalog uses the current `services` **map** and preserves field selectors, targets and response metadata; it does not hard-code integration domains. REST calls flatten target keys into service data. WebSocket calls keep `target` separate. REST `return_response` is a presence flag: it is omitted when false. Calls that request responses return both changed states and service response data. An incompatible response request remains a server error. State writes modify the state machine representation; device control uses actions. These contracts follow [Core's API implementation](https://github.com/home-assistant/core/blob/dev/homeassistant/components/api/__init__.py), rather than older example payloads on the documentation page.

History requires at least one entity filter. The client preserves compact history rows instead of requiring every row to contain an entity ID. Presence flags are omitted when false; `significant_changes_only=0` explicitly requests all changes. See [Core history](https://github.com/home-assistant/core/blob/dev/homeassistant/components/history/__init__.py).

Logbook exposes entity, context and period filters; entity and context cannot be combined. With no start timestamp, the server chooses its default window, currently beginning at local midnight. The native tool sends explicit dates. See [Core logbook](https://github.com/home-assistant/core/blob/dev/homeassistant/components/logbook/rest_api.py).

Calendar requests preserve all-day `date` and timed `dateTime` event values, validate the requested range and use an exclusive end. The route depends on the calendar integration. See [Core calendar](https://github.com/home-assistant/core/blob/dev/homeassistant/components/calendar/__init__.py).

Configuration validation may return HTTP 200 with `result: invalid`; the native tool treats that result as an error. See [Core configuration check](https://github.com/home-assistant/core/blob/dev/homeassistant/components/config/core.py). Intent handling likewise preserves the returned application-level result, including intent errors, and optional language/device context. See [Core intents](https://github.com/home-assistant/core/blob/dev/homeassistant/components/intent/__init__.py).

## WebSocket support

The client authenticates with the configured token and owns command IDs, result matching, timeouts and disconnect cleanup. `sendCommand` is the generic one-shot operation. `subscribeCommand` returns a `HaSubscription` with `events` and `cancel()`. It waits for the subscription acknowledgment, buffers early events, and uses `unsubscribe_events` when cancelled. See the [official WebSocket protocol](https://developers.home-assistant.io/docs/api/websocket/).

| Commands or capability | Implementation | Native UI exposure |
| --- | --- | --- |
| Authentication, matching `result`/error responses | Built into client | Connection status and errors |
| `ping` / `pong` | `ping`, periodic heartbeat | Automatic broken-connection detection |
| `subscribe_events` / `unsubscribe_events` | `subscribeEvents`, subscription cancellation | Entity updates; Events tool keeps the latest 50 messages |
| `call_service` | `callService`, including target/response options | Available to callers; current native Actions use REST |
| `get_states`, `get_config`, `get_services`, `get_panels` | `sendCommand` | API console; native state/config/catalog screens use REST equivalents |
| `fire_event` | `sendCommand` | API console |
| `subscribe_trigger` | `subscribeTrigger` | API console subscription mode |
| `render_template` subscription | `subscribeTemplate` | API console subscription mode; native Template tool uses REST |
| `validate_config` | `sendCommand` | API console; separate from checking the server's stored configuration |
| `extract_from_target` | `sendCommand` | API console |
| `get_triggers_for_target`, `get_conditions_for_target`, `get_services_for_target` | `sendCommand` | API console |
| `config/entity_registry/list_for_display` | `sendCommand` | API console; native registry screens use the full registry APIs |
| `homeassistant/expose_entity/list`, `homeassistant/expose_entity` | `sendCommand` | API console; no dedicated exposure editor |
| Additional Core/integration subscriptions, e.g. `subscribe_entities` | `subscribeCommand` preserves event payloads | API console subscription mode; no automatic compact entity decoder |
| `energy/get_prefs`, `energy/info` | Read-only `HaEnergyApi` | Native configured energy meters; configuration remains in HA |
| `recorder/get_statistics_metadata`, `recorder/statistics_during_period` | Bounded daily/hourly reads | Native today / seven-day meter readings, unit and coverage validation |
| `supported_features` / message coalescing | Incoming message arrays can be decoded | Coalescing is **not negotiated** during the initial handshake; no native switch |

Generic commands use the current server's schema. For example, current Core `validate_config` uses `triggers`, `conditions` and `actions`, and panel results are keyed objects. [Core WebSocket commands](https://github.com/home-assistant/core/blob/dev/homeassistant/components/websocket_api/commands.py) and [frontend panel commands](https://github.com/home-assistant/core/blob/dev/homeassistant/components/frontend/__init__.py) are the implementation references; `dev` links may change after this audit.

The built-in state subscription is acknowledged before the connection becomes ready. Entity loading subscribes before fetching the REST snapshot, merges buffered changes by timestamp, handles deletions, and refreshes after reconnect. Arbitrary public subscriptions instead fail and close on disconnect: callers explicitly subscribe again because the event bus cannot replay missed events. A lost subscription acknowledgment causes reconnection to dispose any possibly registered server subscription. Mutating commands are never automatically retried after an uncertain timeout.

## Native administration and integration coverage

The entity detail sheet includes native controls for climate targets (including paired lower/upper targets), HVAC/fan/preset modes, cover movement/position, lock/unlock, fan speed/presets, number/input-number values, select/input-select options and media playback/volume/mute. Existing light and simple toggle controls remain alongside them. Extended controls require both the live service and the entity's relevant feature flag or option attributes; lock/unlock and HVAC selection do not invent feature flags where Core has none. Sliders send one command on release, show pending/error state, and block duplicate commands. Unlock requires confirmation and offers code input when the entity advertises it. See [climate](https://github.com/home-assistant/core/blob/dev/homeassistant/components/climate/const.py), [cover](https://github.com/home-assistant/core/blob/dev/homeassistant/components/cover/const.py), [fan](https://github.com/home-assistant/core/blob/dev/homeassistant/components/fan/__init__.py), [lock](https://github.com/home-assistant/core/blob/dev/homeassistant/components/lock/__init__.py) and [media player](https://github.com/home-assistant/core/blob/dev/homeassistant/components/media_player/const.py) capability definitions.

Administration uses APIs also used by Home Assistant's frontend. These extend beyond the short public REST reference and may vary between versions. See [Core config entry routes](https://github.com/home-assistant/core/blob/dev/homeassistant/components/config/config_entries.py), [frontend config flows](https://github.com/home-assistant/frontend/blob/dev/src/data/config_flow.ts) and [frontend options flows](https://github.com/home-assistant/frontend/blob/dev/src/data/options_flow.ts).

| Area | Native workflow | Remaining boundary |
| --- | --- | --- |
| Installed integrations | List, reload, remove, rename, enable/disable | Integration behavior and permissions remain server controlled |
| Integration setup | Discover handlers, start/cancel/submit flows, options and reconfiguration, resume pending discovery/reauth flows | Dynamic schema support has JSON fallbacks; integration-specific frontend extensions may require official frontend |
| Areas | List/create/rename/delete; optional local room binding, preview and apply | Room synchronization only changes Larenor layout; no automatic server edits |
| Devices | List; edit user name, area and enabled state | Other device-specific configuration uses integration flows/actions or official frontend |
| Entities | Registry list; name, icon, area, entity ID, enabled and hidden state | Not every registry metadata field has a dedicated control |
| Automations | List, toggle, run, duplicate; configuration create/edit/delete | JSON-based configuration editor; no equivalent of the full visual automation/trace editor |
| Cameras | List and image viewer | Snapshot transport is not complete WebRTC, HLS, recording or timeline support |
| Actions | Live action discovery, parameter forms, target selection and response display | Unknown selectors use JSON input; custom integration UI is not reproduced |

Full Energy configuration/flow dashboards, maps, Assist audio, complete media browsing, backups/restore, Supervisor/OS/add-on administration, user management, repairs, HACS, custom Lovelace cards and custom panels do not gain dedicated native workflows merely because a REST/WS transport exists. The official frontend entry is provided for these remaining workflows, subject to the server, login, platform and embedded browser support.

Native energy reads existing configuration and Recorder changes rather than
subtracting raw sensor states. Daily readings keep separate source and coverage
issues: missing hours, baseline gaps, unfinished days and non-hour-aligned time
zones are not presented as complete totals. Device and parent meters remain
separate. Recorded currency statistics require matching currency metadata; no
current-price extrapolation is performed. The new dashboard and energy work was
validated with synthetic API/widget tests, without another live HA audit.
The source contracts were reviewed against [Core 2026.8.3 energy](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/energy/websocket_api.py)
and [Recorder statistics](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/recorder/websocket_api.py).

## Verification and limits

On 2026-09-04, read-only requests succeeded against HA **2026.8.3** using the actual project `HaRestClient`, `HaWebSocketClient`, `HaAdminClient` and `HaAction.parseCatalog`, rather than only shell requests:

| Check | Aggregate result |
| --- | --- |
| Server configuration | Version parsed successfully |
| Action catalog | 71 domains, 294 actions, 384 fields, 29 actions declaring responses |
| States and single-state lookup | 360 models parsed; individual lookup succeeded |
| History / logbook | A 30-minute one-entity query returned one history group; empty logbook result accepted |
| Config entries / setup handlers | 46 entries; 903 handlers |
| Registries | 94 devices; 8 areas; 668 entity registry entries |
| Panels | 19 entries |
| Live subscription lifecycle | `state_changed` subscription acknowledged; explicit unsubscribe succeeded |

Separate raw read-only endpoint checks also confirmed 281 loaded components and 18 event types. `/api/calendars` returned 404 on this installation because the optional calendar integration was absent; successful calendar behavior is covered by mocks, not claimed as live verified.

No live action call, event firing, state write/delete, registry change, integration change, automation edit or configuration check was executed during this audit. All mutation tests use fake HTTP/WebSocket servers. Aggregate results above intentionally omit credentials, server addresses and private entity/device names. Successful subscription setup does not prove every possible integration event payload or command.

Focused client/provider tests cover response shapes, dynamic catalogs, history flags, text/binary handling, headers, reverse proxy paths, invalid URL/path rejection, error codes, redaction, timeout behavior, state snapshot races, reconnects, deletions, heartbeat, subscription acknowledgment/cancellation and coalesced frames. Run:

```sh
dart analyze lib/features/ha_client test/features/ha_client
flutter test test/features/ha_client
```

Bearer requests stay under the configured server's `/api/` namespace. Redirect following is disabled, credential/header overrides are rejected, and the client does not bypass platform TLS validation. This client accepts a configured long-lived token; it does not implement OAuth refresh-token management. The official frontend login is separate.
