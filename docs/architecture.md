# Architecture

```text
Flutter UI
  → AppController
  → AgentConnector
  → DemoAgentConnector (current)
  → HermesAgentConnector (deferred)
```

Widgets call `AppController` actions only. They do not access connector implementations, Hermes endpoints, or JSON-RPC.

```text
Typed connector event → AppController → ApprovalRequest/ClarificationRequest
  → typed card → AppController action → AgentConnector
```

Connection settings use a separate local-only path:

```text
assets/config/connection_providers.json
  → ConnectionCatalog
  → ConnectionSettingsController
  → ConnectionSettingsSnapshot
  → generic provider/profile UI

application-support/connection_profiles.json
  → ConnectionProfileStore
```

The catalog is read-only and defines provider presentation/capabilities. User profiles are mutable, versioned metadata. Neither stores credentials or performs network requests.
