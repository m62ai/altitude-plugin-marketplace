# tools/

Scripts for maintaining the plugin marketplace.

## refresh-api-spec

Regenerates the embedded OpenAPI spec (`api.json`) in both the onboarding and API plugins
from a live `altitude-BE` backend. The backend's `/v3/api-docs` endpoint is only available
in the `dev` profile, so this script boots the server locally.

### Prerequisites

- `altitude-BE` cloned at `~/Development/altitude-BE` (or pass `--altitude-be-path`)
- Docker Desktop running (PostgreSQL, Kafka, Valkey come up via compose)
- Java 21 and the Gradle wrapper (bundled)
- Port 8080 free

### macOS / Linux

```bash
./tools/refresh-api-spec.sh
# or with custom path:
./tools/refresh-api-spec.sh --altitude-be-path /path/to/altitude-BE
```

### Windows (PowerShell 7+)

```powershell
powershell -ExecutionPolicy Bypass -File tools\refresh-api-spec.ps1
# or:
powershell -ExecutionPolicy Bypass -File tools\refresh-api-spec.ps1 -AltitudeBePath C:\dev\altitude-BE
```

### What it does

1. Starts `./gradlew :local-dev:bootRun` in the background.
2. Polls `http://localhost:8080/v3/api-docs` every 5s until it returns 200 (up to 5 min).
3. Downloads the spec and writes it to:
   - `plugins/m62-altitude-onboarding/skills/m62-altitude-onboarding/api-docs/api.json`
   - `plugins/m62-altitude-api/skills/m62-altitude-api/api-docs/api.json`
4. Kills the server and cleans up.

### After running

Update the `Updated:` date in:

- `plugins/m62-altitude-onboarding/skills/m62-altitude-onboarding/references/altitude_api_endpoints.md`
- `plugins/m62-altitude-onboarding/skills/m62-altitude-onboarding/references/altitude_api_schema.md`

Bump plugin versions in `plugin.json` and `marketplace.json` if the refresh introduced
field-level changes to onboarding-core DTOs (Individual, LegalEntity, Account, Contact,
TangibleAsset, InsurancePolicy, Liability, EntityRelationship, Household, Document).
