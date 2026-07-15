# Architecture

```text
Flutter UI
  → AppController
  → AgentConnector
  → DemoAgentConnector (current)
  → HermesAgentConnector (deferred)
```

Widgets depend on the generic connector contract, not Hermes endpoints or JSON-RPC.

Connection settings use a separate local-only path:

```text
assets/config/connection_providers.json
  → ConnectionCatalog
  → ConnectionSettingsController
  → generic provider cards

application-support/connection_profiles.json
  → ConnectionProfileStore
```

The catalog is read-only and defines provider presentation/capabilities. User profiles are mutable, versioned metadata. Neither stores credentials or performs network requests.
