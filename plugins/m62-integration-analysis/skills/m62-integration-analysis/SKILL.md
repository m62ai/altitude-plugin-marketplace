---
name: m62-integration-analysis
description: Analyze an external API and map its entities/fields to the Altitude domain model. Fetches API documentation from a URL, auto-detects entity types, produces field-level mapping tables, and saves a structured analysis doc that m62-plan and build agents can consume.
argument-hint: "[api-docs-url] — e.g., 'https://docs.schwab.com/api' or 'https://developer.orion.com/api-reference'"
---

# M62 Integration Analysis

You are analyzing an **external API** and mapping it to the **Altitude wealth management backend** domain model (Java 21+, Spring Boot 3, JPA/Hibernate). The output is a structured analysis document that other agents (`/m62-plan`, `/m62-build-with-agent-team`, `backend-developer`) consume to build the integration.

**Announce at start:** "Analyzing external API for Altitude integration mapping: [URL]..."

<HARD-GATE>
This skill produces an ANALYSIS DOCUMENT only. Do NOT write any Java code, create any entities, or start implementation. The analysis feeds into `/m62-plan` which creates the implementation plan.
</HARD-GATE>

## Phase 1: Gather Inputs

### 1.1 Fetch External API Documentation

Use WebFetch to retrieve the API documentation from `$ARGUMENTS`:

```
WebFetch the URL provided in $ARGUMENTS.
Extract:
- API name and version
- Base URL(s)
- Authentication mechanism (API key, OAuth, Basic Auth, etc.)
- Available entity/resource endpoints (list them all)
- Pagination pattern (cursor, offset, page-based)
- Rate limits (if documented)
- Content type (JSON, JSON:API, XML, etc.)
- Date/time formats used
```

If the URL returns an OpenAPI/Swagger spec, parse the schema definitions and endpoint paths directly.

If the initial page is a docs index or landing page, follow links to the **entity/resource reference** sections. Prioritize pages that describe data models, schemas, or entity types.

If the URL is unreachable or returns insufficient information, tell the user and ask for alternative input (another URL, pasted docs, or a local file path).

### 1.2 Read Altitude Domain Model

Read these files to understand the internal domain:

1. **`docs/DATA_MODEL.md`** — All entity relationships and domain areas
2. **`docs/EXTERNAL_ID_PATTERN.md`** — How external IDs are tracked (ExternalEntityIdSync)
3. **`docs/ADDEPAR_INTEGRATION_PATTERNS.md`** — Reference integration patterns
4. **`docs/ADDEPAR_TYPE_MAPPING.md`** — How Addepar types map to Altitude (reference example)

Then scan the domain entities to understand available fields:

```
Glob: src/main/java/com/altitude/altcore/domain/**/*.java
```

Read key entities that are likely mapping targets:
- `domain/Individual.java` — People/clients
- `domain/Household.java` — Family groups
- `domain/LegalEntity.java` — Trusts, companies, funds
- `domain/AccountFinancial.java` — Financial accounts
- `domain/AccountPortfolio.java` — Portfolio sleeves
- `domain/Position.java` — Holdings/positions
- `domain/Instrument.java` — Securities master
- `domain/transaction/CashTransaction.java` — Transactions

Only read entities that are relevant based on what the external API provides. If the API only covers accounts and positions, skip ownership entities.

### 1.3 Read Addepar Reference Mappers

Read 1-2 Addepar mapper files to understand the mapping pattern used in the project:

```
src/main/java/com/altitude/altcore/service/integration/addepar/mapper/AddeparClientMapper.java
src/main/java/com/altitude/altcore/service/integration/addepar/mapper/AddeparAccountMapper.java
```

Note the patterns:
- How attributes are extracted from the external DTO
- How name parsing works
- How supplemental attributes handle unmapped fields
- How `@AfterMapping` hooks populate ExternalEntityIdSync
- How enum/type mapping works

## Phase 2: Auto-Detect Entity Types

Analyze the external API documentation and identify all entity/resource types it exposes. For each, determine:

| Question | How to Answer |
|---|---|
| What entity types does the API have? | Look at endpoint paths (`/persons`, `/accounts`, `/holdings`), schema definitions, or model types |
| What fields does each entity expose? | Parse response schemas, example responses, or field documentation |
| What are the ID formats? | String, integer, UUID — note the format for ExternalEntityIdSync |
| Are there relationships between entities? | Parent-child, ownership, containment — note the structure |
| Are there type discriminators? | Fields like `type`, `model_type`, `category` that sub-classify entities |

Build a catalog of every entity type the API exposes with its fields and relationships.

## Phase 3: Map to Altitude Domains

For each external entity type, determine which Altitude domain entity it maps to.

### 3.1 Entity-Level Mapping

Use this decision tree:

```
External entity represents a person/individual?
  → Individual (domain/Individual.java)

External entity represents a family/group?
  → Household (domain/Household.java)

External entity represents a trust, company, fund, or legal structure?
  → LegalEntity (domain/LegalEntity.java)

External entity represents a financial account (brokerage, bank, retirement)?
  → AccountFinancial (domain/AccountFinancial.java)

External entity represents a portfolio sleeve or sub-account?
  → AccountPortfolio (domain/AccountPortfolio.java)

External entity represents a holding/position?
  → Position (domain/Position.java)

External entity represents a security/instrument?
  → Instrument (domain/Instrument.java)

External entity represents a transaction (buy, sell, dividend, etc.)?
  → CashTransaction (domain/transaction/CashTransaction.java)

External entity represents a document or file?
  → Document (domain/Document.java)

External entity represents a valuation or NAV?
  → Valuation entities (domain/valuation/)

External entity doesn't map to any existing domain?
  → Flag as NEW ENTITY CANDIDATE
```

Assign a confidence level to each mapping:

| Confidence | Meaning |
|---|---|
| **HIGH** | Clear 1:1 mapping, field overlap is strong |
| **MEDIUM** | Conceptual match but fields diverge, may need transformation |
| **LOW** | Weak match, may need a new entity or significant adapter logic |
| **NONE** | No Altitude equivalent — candidate for new domain entity or SupplementalAttribute |

### 3.2 Field-Level Mapping

For each entity pair (external → Altitude), produce a field mapping table.

**For each external field, determine:**

1. **Direct match** — Same concept, same or trivially convertible type
   - `first_name` (string) → `Individual.firstName` (String) — transform: `direct`
2. **Type conversion** — Same concept, different type
   - `balance` (number) → `AccountFinancial.marketValue` (BigDecimal) — transform: `type cast`
3. **Computed/derived** — Requires logic to derive
   - `full_name` → needs parsing into `firstName`, `middleName`, `lastName` — transform: `parse`
4. **Enum mapping** — External value maps to internal enum
   - `account_type: "ira"` → `AccountType.IRA` — transform: `enum map`
5. **Relationship resolution** — External ID reference that needs lookup
   - `owner_id: "12345"` → `Individual` via ExternalEntityIdSync lookup — transform: `FK resolve`
6. **Unmapped (provider side)** — External field with no Altitude equivalent
   - Candidate for SupplementalAttribute storage
7. **Unmapped (Altitude side)** — Altitude field with no external source
   - Will be null/default after sync, may need manual entry or another source

**Field mapping table format:**

```markdown
| Provider Field | Provider Type | Altitude Field | Altitude Type | Transform | Notes |
|---|---|---|---|---|---|
| id | string | → ExternalEntityIdSync.externalId | String | external ID | Tracked, not stored on entity |
| first_name | string | Individual.firstName | String | direct | |
| last_name | string | Individual.lastName | String | direct | |
| full_name | string | Individual.firstName + lastName | String | parse | Needs name parser |
| email | string | Individual.email | String | direct | |
| date_of_birth | string (ISO) | Individual.dateOfBirth | LocalDate | date parse | |
| tax_id | string | Individual.taxIdentifier | String | direct | PII - encrypt |
| custom_field_1 | string | → SupplementalAttribute | | key-value | Not in domain model |
```

### 3.3 Relationship Mapping

Map how the external API's entity relationships correspond to Altitude's relationship model:

```markdown
| Provider Relationship | Provider Pattern | Altitude Relationship | Pattern |
|---|---|---|---|
| Person owns Account | person.accounts[] | EntityRelationship (INDIVIDUAL → ACCOUNT) | Ownership chain |
| Account contains Holdings | account.holdings[] | Position.accountPortfolio | FK on Position |
| Household contains Persons | household.members[] | EntityRelationship (HOUSEHOLD → INDIVIDUAL) | Ownership chain |
```

## Phase 4: Gap Analysis

### 4.1 Provider Fields → SupplementalAttribute Candidates

List all external fields that don't map to any Altitude entity field. These are candidates for SupplementalAttribute storage:

```markdown
### Provider fields with no Altitude equivalent

| Provider Entity | Field | Type | Recommendation |
|---|---|---|---|
| Person | nickname | string | SupplementalAttribute |
| Account | risk_score | number | SupplementalAttribute or new field |
| Account | custodian_code | string | May warrant a new domain field |
```

### 4.2 Altitude Fields with No Provider Source

List Altitude fields that the external API cannot populate:

```markdown
### Altitude fields with no provider source

| Altitude Entity | Field | Impact | Recommendation |
|---|---|---|---|
| Individual.middleName | No API source | Low | Leave null, manual entry |
| AccountFinancial.inceptionDate | No API source | Medium | May need secondary data source |
```

### 4.3 New Entity Candidates

If the external API has entity types with no Altitude equivalent:

```markdown
### External entities with no Altitude mapping

| Provider Entity | Description | Recommendation |
|---|---|---|
| Beneficiary | Account beneficiary designations | New entity or extend existing |
| Fee Schedule | Fee configuration per account | Maps to billing domain (check existing) |
```

## Phase 5: ExternalEntityIdSync Requirements

Define the ExternalEntityIdSync records needed for this integration:

```markdown
## ExternalEntityIdSync Requirements

**Provider constant**: `"[PROVIDER_NAME]"` (e.g., "SCHWAB", "ORION", "BLACK_DIAMOND")

| Altitude Entity | entityType Constant | Provider ID Field | ID Format | Notes |
|---|---|---|---|---|
| Individual | CLIENT | person.id | string (numeric) | |
| Household | HOUSEHOLD | household.id | string (numeric) | |
| AccountFinancial | ACCOUNT | account.id | string (alphanumeric) | |
| Position | POSITION | holding.id | string | |
| Instrument | INSTRUMENT | security.id | string | May use CUSIP/ISIN instead |
```

Reference: The Addepar integration uses these entityType constants — reuse the same constants where the same Altitude entity is targeted.

## Phase 6: Write the Analysis Document

Save the complete analysis to `docs/integrations/<provider-name>-analysis.md`.

**Derive the provider name** from the API documentation (e.g., "schwab", "orion", "black-diamond", "tamarac").

### Document Template

```markdown
# [Provider Name] Integration Analysis

> **For Claude:** This analysis feeds into `/m62-plan` for implementation planning.
> Reference implementation: Addepar integration in `service/integration/addepar/`

**Source**: [API documentation URL]
**Date**: [YYYY-MM-DD]
**Altitude Domains Affected**: [comma-separated list]
**Provider ID Constant**: `"[PROVIDER_NAME]"`

---

## Entity Mapping Summary

| Provider Entity | Altitude Entity | Confidence | Sync Direction | Notes |
|---|---|---|---|---|
| [entity] | [entity] | HIGH/MEDIUM/LOW | PULL/PUSH/BOTH | [notes] |

## Detailed Field Mappings

### [Provider Entity] → [Altitude Entity]

[Field mapping table from Phase 3.2]

[Repeat for each entity pair]

## Relationship Mapping

[Relationship table from Phase 3.3]

## Gap Analysis

### Provider fields → SupplementalAttribute candidates
[Table from Phase 4.1]

### Altitude fields with no provider source
[Table from Phase 4.2]

### New entity candidates
[Table from Phase 4.3, if any]

## ExternalEntityIdSync Requirements

[Table from Phase 5]

## Addepar Pattern Comparison

| Concern | Addepar Approach | Recommendation for [Provider] |
|---|---|---|
| Entity type identification | `model_type` attribute field | [equivalent in this API] |
| Name parsing | Parse `original_name` or use `first_name`/`last_name` | [approach based on API fields] |
| Unknown attributes | Store as SupplementalAttribute | [same or different approach] |
| ID format | String numeric IDs | [format from this API] |
| Relationship discovery | Nested entity IDs in attributes | [how this API exposes relationships] |

## Implementation Notes for Agents

### Recommended Package Structure
```
service/integration/[provider]/
  client/[Provider]Client.java
  client/[Provider]ClientFactory.java
  config/[Provider]ConfigurationProperties.java
  dto/[Provider]EntityDto.java
  dto/[Provider]ResponseDto.java
  mapper/[Provider]ClientMapper.java
  mapper/[Provider]AccountMapper.java
  [Provider]SyncHistoryService.java
  [Provider]EntityFetchService.java
```

### Key Decisions for Implementation Plan
- [Decision 1: e.g., "API uses OAuth2 — needs token refresh logic unlike Addepar's Basic Auth"]
- [Decision 2: e.g., "Positions are nested under accounts, not a separate endpoint"]
- [Decision 3: e.g., "No model_type field — entity type determined by endpoint path"]
```

## Phase 7: Present Summary

After saving the document, present a concise summary in chat:

```
Integration analysis saved to: docs/integrations/[provider]-analysis.md

Summary:
- [N] external entity types analyzed
- [N] mapped to existing Altitude domains
- [N] high-confidence mappings, [N] medium, [N] low
- [N] fields mapped, [N] → SupplementalAttribute candidates
- [N] Altitude fields without provider source
- [N] new entity candidates identified

Affected Altitude domains: [list]

Next steps:
- Review the analysis doc for accuracy
- Run `/m62-plan [provider] integration` to create the implementation plan
```

## Key Principles

- **Analysis, not implementation** — This skill produces a mapping document, never code
- **Addepar is the reference** — Always compare patterns to the existing Addepar integration
- **Agent-consumable output** — The doc must be specific enough that `backend-developer` agents can build mappers from the field tables
- **Exact field names** — Use actual Java field names from the Altitude entities, not descriptions
- **Flag uncertainty** — Use confidence levels honestly; MEDIUM/LOW mappings need human review
- **SupplementalAttribute as escape hatch** — Unmapped fields are not failures, they go to SupplementalAttributes
- **ExternalEntityIdSync always** — Every mapped entity needs an external ID tracking entry
