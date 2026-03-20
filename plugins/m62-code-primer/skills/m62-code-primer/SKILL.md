---
name: m62-code-primer
description: Generate a focused codebase briefing for the Altitude wealth management platform. Primes agents or developers on architecture, domain context, patterns, key files, and gotchas for a specific domain area.
argument-hint: "[domain] — e.g., holdings, ownership, integration, onboarding, workflow, documents, instruments, tangible-assets, valuation, strategy, transactions, billing, or omit for full overview"
---

# M62 Code Primer

You are generating a **codebase briefing** for the Altitude wealth management backend (Java 21+, Spring Boot 3, Maven, JPA/Hibernate, MapStruct, Liquibase). The briefing should give an agent or developer everything they need to start working in a specific domain area — without reading hundreds of files.

**Announce at start:** "Generating Altitude codebase primer for: [domain or 'full overview']..."

## Step 1: Determine Scope

Parse `$ARGUMENTS` to determine the domain focus:

| Argument | Domain | Key Docs to Read |
|----------|--------|-----------------|
| `holdings` | Positions, tax lots, pricing | `docs/VALUATION_ROLLUP_HIERARCHY.md`, `docs/PORTFOLIO_ALLOCATION_CHARTS.md` |
| `ownership` | Individuals, households, legal entities, ownership chains | `docs/DATA_MODEL.md` (Ownership Domain section) |
| `integration` | Addepar, Polygon, custodians, external ID sync | `docs/ADDEPAR_SYNC.md`, `docs/ADDEPAR_INTEGRATION_PATTERNS.md`, `docs/EXTERNAL_ID_PATTERN.md` |
| `onboarding` | Client onboarding workflow | `docs/ONBOARDING.md`, `docs/ONBOARDING_EXPORT.md` |
| `workflow` | Temporal workflows, task management, AI decisions | `docs/WORKFLOW_SYSTEM.md` |
| `documents` | Document uploads, metadata, associations | `docs/DOCUMENT_UPLOAD_SESSION_SERVICE.md`, `docs/DOCUMENT_ENTITY_ASSOCIATIONS.md`, `docs/DOCUMENT_MANAGEMENT_PATTERNS.md` |
| `instruments` | Securities master, pricing, enrichment | `docs/INSTRUMENT_LOADER.md`, `docs/INSTRUMENT_DOMAIN_CLASSES.md` |
| `tangible-assets` | Physical assets (luxury goods, vehicles, real estate) | `docs/TANGIBLE_ASSET_SYSTEM.md` |
| `valuation` | Portfolio/account/owner/household valuations | `docs/VALUATION_ROLLUP_HIERARCHY.md` |
| `strategy` | Model portfolios, allocation, rebalancing | `docs/PORTFOLIO_ALLOCATION_CHARTS.md` |
| `transactions` | Buys, sells, dividends, capital calls, distributions | `docs/DATA_MODEL.md` (Transaction Domain section) |
| `billing` | Fee schedules, billing runs | `docs/DATA_MODEL.md` (Billing Domain section) |
| `mcp` | MCP tool development | `docs/MCP_FEATURES_GUIDE.md`, `docs/mcp/MCP_TOOL_OPTIMIZATION_GUIDE.md` |
| `supplemental` | SupplementalAttributes, configurations, choice lists | `docs/SUPPLEMENTAL_ATTRIBUTES_ARCHITECTURE.md`, `docs/SUPPLEMENTAL_ATTRIBUTE_ENUM_REFERENCES.md` |
| *(empty)* | Full architecture overview | `CLAUDE.md`, `docs/DATA_MODEL.md` (Architecture section), `docs/CRITICAL_PATTERNS_PITFALLS.md` |

If the argument doesn't match the table, treat it as a free-text search topic — find the closest domain match and relevant entities.

## Step 2: Read Key Files

Always read these (they're compact and essential):
1. **CLAUDE.md** — Skim the Quick Reference and Project Structure sections
2. **docs/CRITICAL_PATTERNS_PITFALLS.md** — Patterns every agent must know

Then read the domain-specific docs from the table above.

For domain-specific exploration, also:
3. **Find entities**: Use Glob for `src/main/java/com/altitude/altcore/domain/**/*.java` matching the domain
4. **Find services**: Use Glob for `src/main/java/com/altitude/altcore/service/**/*.java` matching the domain
5. **Find controllers**: Use Glob for `src/main/java/com/altitude/altcore/web/rest/**/*.java` matching the domain

Don't read every file — just list them to show the developer what exists, and read 1-2 key files to extract patterns.

## Step 3: Generate the Briefing

Output the briefing in this structure. Scale each section to its relevance — skip sections that don't apply, expand sections that are critical.

```markdown
# Altitude Codebase Primer: [Domain Name]

## Architecture Overview

### Tech Stack
- Java 21+, Spring Boot 3, Maven wrapper (`./mvnw`)
- JPA/Hibernate with PostgreSQL (prod) / H2 (test)
- MapStruct for entity <-> DTO mapping
- Liquibase for database migrations
- Multi-tenant: tenant-per-row (`tenantId` column on all entities)
- Firm isolation: firm-per-row (`firmId` within tenant)

### Base Class Hierarchy
- `AbstractAuditingEntity` → all entities (adds createdBy, createdDate, lastModifiedBy, lastModifiedDate, deleted, deletedDate)
- `AbstractAuditingEntityDto` → all DTOs (mirrors audit fields)
- `BaseTenantAwareService` → all services (enforces tenant isolation in queries)
- `BaseEntityMapper` → all MapStruct mappers (standard entity <-> DTO contract)
- `CollectionMergeUtils` → required for updating collections with orphanRemoval=true

### Package Structure
```
com.altitude.altcore.domain.[subdomain]         → JPA entities
com.altitude.altcore.service.[subdomain]        → Business logic
com.altitude.altcore.service.[subdomain].dto    → DTOs
com.altitude.altcore.service.[subdomain].mapper → MapStruct mappers
com.altitude.altcore.web.rest.[subdomain]       → REST controllers
com.altitude.altcore.mcp                        → MCP tools
```

## [Domain Name] Context

### Entities
[List key entities with their relationships and purpose]

### Services
[List key services with their responsibilities]

### REST Endpoints
[List key endpoints with URL patterns]

### Key Patterns in This Domain
[Domain-specific patterns — e.g., valuation rollup chain, sync workflow, ownership hierarchy]

## Patterns to Follow

### Must-Use Base Classes
- Entities: extend `AbstractAuditingEntity`
- Services: extend `BaseTenantAwareService`
- Mappers: extend `BaseEntityMapper<DTO, Entity>`
- DTOs: extend `AbstractAuditingEntityDto`

### Collection Updates (orphanRemoval)
NEVER do `entity.setCollection(newList)`. Always:
```java
CollectionMergeUtils.mergeCollection(existing, incoming, matchFn, updateFn);
```

### Liquibase Conventions
- File: `YYYYMMDDhhmmss_description.xml`
- Types: `${uuidType}`, `text`, `decimal(19,6)` for money, `timestamptz`, `boolean default false`
- Required columns: `id`, `tenant_id`, `firm_id`, 7 audit columns, `deleted default false`
- Register in `master.xml`

### REST Conventions
- All endpoints under `/api/v1/`
- Use `@PreAuthorize` for role-based access
- Pagination via `Pageable` parameter
- Error responses via `BadRequestAlertException`

## Key Files
[List the most important files for this domain — entities, services, controllers, docs]

## Gotchas
[Domain-specific pitfalls, common mistakes, things that break silently]
```

## Step 4: Present the Briefing

Output the briefing directly in chat. Do NOT write it to a file unless the user specifically asks for it.

If the user asks to save it, write to `docs/primers/[domain]-primer.md`.

## Important Notes

- Keep the briefing **concise** — aim for 150-300 lines, not 1000
- Prioritize **actionable information** over exhaustive documentation
- Include **specific file paths** so agents can navigate directly
- Focus on **what's different about Altitude** vs a generic Spring Boot app
- The briefing is a **starting point**, not a replacement for reading code
