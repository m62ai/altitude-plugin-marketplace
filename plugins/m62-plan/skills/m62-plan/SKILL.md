---
name: m62-plan
description: Altitude-specific implementation planner. Analyzes domain impact, discovers codebase patterns, writes a reviewable .md plan, and waits for approval before any implementation. Use this instead of (or before) generic planning tools.
argument-hint: "[feature description] — e.g., 'Add tax-loss harvesting workflow' or 'Integrate Schwab custodian feed'"
---

# M62 Plan — Altitude Implementation Planner

You are creating an **implementation plan** for the Altitude wealth management backend (Java 21+, Spring Boot 3, Maven, JPA/Hibernate, MapStruct, Liquibase). This plan will be reviewed by a human before any agents execute it.

**Announce at start:** "Creating Altitude implementation plan for: [feature]..."

<HARD-GATE>
The plan MUST be written to `docs/plans/YYYY-MM-DD-<feature-slug>.md` and presented for review BEFORE any implementation begins. Never skip the review gate. Never start coding.
</HARD-GATE>

## Phase 1: Domain Analysis Checklist

Work through this checklist to understand what this feature touches. Use AskUserQuestion for items where you genuinely need input — make your best guess and confirm for the rest.

### 1.1 Domain Impact — Which areas does this feature touch?

Identify all affected domain areas from the 16 in the system:

| # | Domain | Entities | Likely Affected? |
|---|--------|----------|-----------------|
| 1 | Ownership | Individual, Household, LegalEntity, ownership chains | |
| 2 | Account | AccountFinancial, account types, titling | |
| 3 | Holdings | AccountPortfolio, Position, pricing | |
| 4 | Valuation | Portfolio/Account/Owner/Household valuations | |
| 5 | Instrument | Securities, ETFs, mutual funds, pricing | |
| 6 | Fund | Fund entities, share classes, capital accounts | |
| 7 | Transaction | Buys, sells, dividends, capital calls | |
| 8 | Strategy | Model portfolios, allocation targets, rebalancing | |
| 9 | Tangible Assets | Physical assets (luxury, vehicles, real estate) | |
| 10 | Documents | Uploads, metadata, entity associations | |
| 11 | Workflow | Temporal workflows, task management, AI decisions | |
| 12 | Onboarding | Client onboarding steps and forms | |
| 13 | Billing | Fee schedules, billing runs | |
| 14 | Supplemental Attrs | Custom attributes, configurations, choice lists | |
| 15 | Integration & Sync | Addepar, Polygon, custodians, ExternalEntityIdSync | |
| 16 | Admin & Firm | Firm settings, user management | |

### 1.2 Technical Impact — What infrastructure does this need?

Answer each question:

- **Liquibase migrations?** New tables? New columns on existing tables? Column type changes?
- **Integration touchpoints?** Does this push/pull data from Addepar, Polygon, custodians, or new external systems?
- **MCP tools?** Does this need new MCP tools for AI agent access? Or changes to existing tools?
- **Valuation rollup impact?** Does this change how Position → Portfolio → Account → Owner → Household rolls up?
- **ExternalEntityIdSync?** Does this need external ID tracking for a new entity type or provider?
- **Tenant isolation?** New entities/services must enforce tenant-per-row via `BaseTenantAwareService`
- **Security/compliance?** PII handling, financial data, tax documents, regulatory requirements?
- **Scheduled jobs?** Does this need background processing, cron schedules, or batch operations?
- **Caching?** Does this benefit from Hibernate second-level cache or application-level caching?

### 1.3 Risk Assessment

Flag any of these high-risk patterns:
- Modifying existing entities that other features depend on
- Changing valuation rollup logic (cascading impact across the hierarchy)
- Adding/modifying Liquibase migrations on production tables with data
- Cross-tenant data access patterns
- Integration changes that affect sync bidirectionality
- Cascade type changes on JPA relationships

## Phase 2: Codebase Discovery

Now explore the codebase to find existing patterns to follow.

### 2.1 Run Code Primer

Invoke `/m62-code-primer` for each affected domain area to understand the current state:

```
For each affected domain from Phase 1:
  - What entities exist?
  - What services exist?
  - What patterns are used?
  - What base classes should be extended?
```

### 2.2 Find Similar Features

Search for the closest existing feature to model after:

```
- Search for similar entities/services/controllers
- Read 1-2 representative examples to understand the pattern
- Note any deviations from standard patterns
```

### 2.3 Read Relevant Documentation

From CLAUDE.md's documentation index, identify and read the docs relevant to this feature. Key docs to always check:

- `docs/CRITICAL_PATTERNS_PITFALLS.md` — Patterns every change must follow
- `docs/LIQUIBASE_H2_POSTGRESQL_COMPATIBILITY.md` — If migrations are needed
- `docs/DATA_MODEL.md` — For entity relationships
- Domain-specific docs from the index

## Phase 3: Architecture Decision

### 3.1 Propose Approach

Based on the analysis, propose the implementation approach:

- **What** are we building? (One-sentence summary)
- **How** does it fit into the existing architecture? (Which layers, which packages)
- **Why** this approach over alternatives? (Trade-offs considered)
- **What** existing patterns are we following? (Name specific entities/services as models)

### 3.2 Determine Agent Team Recommendation

If this feature will be built using `/m62-build-with-agent-team`, recommend:

- **Team size**: 2-5 agents based on scope
- **Role split**: Which agents own which packages
- **Parallel potential**: What can be built simultaneously
- **Contract interfaces**: Key DTO shapes, service signatures, endpoint URLs

## Phase 4: Write the Plan

Write the complete plan to `docs/plans/YYYY-MM-DD-<feature-slug>.md`.

### Plan Document Structure

```markdown
# [Feature Name] Implementation Plan

> **For Claude:** Use `/m62-build-with-agent-team docs/plans/YYYY-MM-DD-<feature-slug>.md` to execute this plan.

**Goal:** [One sentence]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** Java 21, Spring Boot 3, JPA/Hibernate, MapStruct, Liquibase

**Affected Domains:** [List from Phase 1]

**Risk Level:** LOW / MEDIUM / HIGH — [one-line justification]

---

## Domain Impact Matrix

| Domain | Impact | Details |
|--------|--------|---------|
| [domain] | NEW / MODIFY / READ | [what changes] |

## Migration Spec

[If Liquibase migrations are needed]

### Table: [table_name]

| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | ${uuidType} | NOT NULL | | PK |
| tenant_id | ${uuidType} | NOT NULL | | FK → alt_tenant |
| firm_id | ${uuidType} | NOT NULL | | FK → alt_firm |
| [columns] | | | | |
| created_by | varchar(50) | NOT NULL | | Audit |
| created_date | timestamptz | NOT NULL | | Audit |
| last_modified_by | varchar(50) | | | Audit |
| last_modified_date | timestamptz | | | Audit |
| deleted | boolean | NOT NULL | false | Soft delete |
| deleted_date | timestamptz | | | Soft delete |
| deleted_by | varchar(50) | | | Soft delete |

### Indexes
- [indexes needed]

### Foreign Keys
- [FK relationships]

## Integration Map

[If external systems are involved]

| System | Direction | Entities | Sync Pattern |
|--------|-----------|----------|-------------|
| [system] | PUSH / PULL / BIDIRECTIONAL | [entities] | [pattern] |

## Pattern References

| Pattern | Example to Follow | Doc |
|---------|------------------|-----|
| Entity design | [ExistingEntity.java] | DATA_MODEL.md |
| Service layer | [ExistingService.java] | |
| REST controller | [ExistingResource.java] | |
| MapStruct mapper | [ExistingMapper.java] | |
| Liquibase migration | [existing_changelog.xml] | LIQUIBASE_H2_POSTGRESQL_COMPATIBILITY.md |

## Agent Team Recommendation

**Team Size:** [N] agents
**Suggested Roles:**

| Agent | Owns | Does NOT Touch |
|-------|------|----------------|
| domain | `domain/[pkg]`, `liquibase/changelog/` | `service/`, `web/rest/` |
| service | `service/[pkg]/` (logic, DTOs, mappers) | `domain/`, `web/rest/` |
| api | `web/rest/[pkg]/` | `domain/`, `service/` |

**Liquibase Timestamp Prefixes:**
- Agent A: `YYYYMMDDhh0000`
- Agent B: `YYYYMMDDhh1000`

## Implementation Tasks

### Task 1: [Component Name]

**Files:**
- Create: `exact/path/to/NewEntity.java`
- Create: `exact/path/to/changelog.xml`
- Modify: `src/main/resources/config/liquibase/master.xml`

**Steps:**
1. Create Liquibase changelog with table definition
2. Register in master.xml
3. Create JPA entity extending AbstractAuditingEntity
4. Add tenant_id and firm_id fields
5. Verify: `./mvnw compile`

### Task 2: [Component Name]
[... continue for each task ...]

## Validation

### Migration Validation
- App starts with `./mvnw spring-boot:run -Pdev` (Liquibase applies automatically)

### Compilation
- `./mvnw compile` succeeds

### Tests
- `./mvnw test -Dtest=[TestClass]` passes

### API Validation
```bash
TOKEN=$(curl -s -X POST "http://localhost:8080/api/v1/authenticate" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin","rememberMe":false}' | jq -r '.id_token')

curl -X GET "http://localhost:8080/api/v1/[endpoint]" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

### End-to-End
- Full CRUD cycle works
- Tenant isolation verified (different tenant tokens see different data)

## Acceptance Criteria

- [ ] [Criterion 1]
- [ ] [Criterion 2]
- [ ] [Criterion 3]

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| [risk] | LOW/MED/HIGH | [impact] | [mitigation] |
```

## Phase 5: Review Gate

After writing the plan file:

1. **Tell the user** the plan has been saved and where:
   > "Plan written to `docs/plans/YYYY-MM-DD-<feature-slug>.md`. Please review before proceeding."

2. **Summarize** the plan in chat — key decisions, migration count, team recommendation, risk level

3. **Wait for approval.** Do NOT proceed to implementation. Do NOT invoke `build-with-agent-team`. The user must explicitly approve.

4. **After approval**, offer execution options:
   - `/m62-build-with-agent-team docs/plans/YYYY-MM-DD-<feature-slug>.md` — Agent team execution
   - Manual implementation — Walk through tasks one at a time
   - `superpowers:subagent-driven-development` — Single-session subagent execution

## Key Principles

- **Write the plan before writing code** — always
- **Be specific** — exact file paths, exact column types, exact endpoint URLs
- **Model after existing code** — find a similar feature and follow its patterns
- **Flag risks early** — tenant isolation, cascade changes, rollup impact
- **Right-size the plan** — a simple field addition gets 1 page, a new domain gets 5+
- **The plan is the contract** — agents build to match it exactly
