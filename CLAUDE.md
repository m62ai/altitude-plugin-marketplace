# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Claude Code plugin marketplace for the Altitude Wealth Management Platform. This repo contains no buildable source code — it is a collection of Claude Code plugin definitions (skills, references, and metadata) distributed via the Claude Code plugin marketplace system.

## Repository Structure

```
.claude-plugin/marketplace.json          # Marketplace manifest — lists all published plugins
plugins/
  m62-altitude-api/
    .claude-plugin/plugin.json           # Plugin metadata
    skills/m62-altitude-api/
      SKILL.md                           # Main skill prompt
      references/
        api_domain_guide.md              # Compact endpoint guide (auto-loaded into context)
      api-docs/
        api.json                         # Full OpenAPI spec (searched on-demand via Grep)
  m62-altitude-onboarding/
    .claude-plugin/plugin.json           # Plugin metadata
    skills/m62-altitude-onboarding/
      SKILL.md                           # Main skill prompt (multi-phase workflow)
      references/                        # Reference docs consumed by the skill at runtime
        altitude_api_endpoints.md        # API endpoint specs (search, PATCH, POST, relationships)
        altitude_api_schema.md           # Full entity schemas and field enums
        document_entity_association.md   # Rules for which entity a document belongs to
        document_type_patterns.md        # Filename/folder → document type classification
        match_merge_rules.md             # Entity matching hierarchy and field merge logic
      api-docs/
        api.json                         # Full OpenAPI spec (searched on-demand)
  m62-altitude-search/
    .claude-plugin/plugin.json           # Plugin metadata
    skills/m62-altitude-search/
      SKILL.md                           # Read-only search skill
      references/
        altitude_search_api.md           # Search-focused API reference
```

## Key Concepts

- **marketplace.json** is the plugin registry. Each entry points to a plugin directory and declares its version. Adding a new plugin means adding an entry here AND creating the plugin directory tree.
- **plugin.json** declares plugin identity (name, version, author). The `name` field must match the skill directory name.
- **SKILL.md** is the prompt that Claude Code executes when the skill is invoked. It defines a multi-phase workflow (query Altitude, scan docs, extract entities via parallel agents, match/merge, review, push updates, upload documents).
- **references/** files are loaded as context when the skill runs. They contain Altitude API specs, entity schemas, document classification rules, and match/merge logic.

## How to Add a New Plugin

1. Create `plugins/{plugin-name}/.claude-plugin/plugin.json` with name, description, version
2. Create `plugins/{plugin-name}/skills/{skill-name}/SKILL.md` with the skill prompt
3. Add any reference docs under `plugins/{plugin-name}/skills/{skill-name}/references/`
4. Register the plugin in `.claude-plugin/marketplace.json` under the `plugins` array

## The API Skill (m62-altitude-api)

Platform-agnostic plugin for querying and modifying Altitude data via the REST API. Key design:

- **Two-tier docs**: A compact domain guide (~25KB) loads into context as a reference. The full OpenAPI spec (5.8MB, 1200+ endpoints, 853 schemas) sits in `api-docs/api.json` and is searched on-demand via Grep when Claude needs exact endpoint details, request body schemas, or response formats.
- **Read + write**: Supports full CRUD — search, get, create (POST), partial update (PATCH), full update (PUT), delete. The search plugin is read-only; this one covers everything.
- **Spec-driven**: Instead of hardcoding every endpoint, the SKILL.md teaches Claude to discover endpoints by searching the embedded OpenAPI spec. This means the plugin stays current by updating a single file (api.json).
- **Confirm before writes**: All create/update/delete operations require explicit user approval.

## The Onboarding Skill (m62-altitude-onboarding)

Extracts entity data from household document folders (PDFs, images, spreadsheets) and pushes to the Altitude API. Key architectural decisions:

- **Query-first**: Always queries Altitude for existing data before creating anything
- **Parallel extraction**: Phase 3 spawns multiple sub-agents to read documents concurrently, writing results to `extraction_cache_batch_*.jsonl` files, then merges them
- **Zero-skip rule**: Every file in the household folder must be read — the skill enforces 100% file coverage via a `file_tracker.md` checklist
- **Match before create**: Extracted entities are matched against existing records using a hierarchy (SSN > Name+DOB > Fuzzy Name+DOB > Name+Address) before deciding to update or create
- **Review gate**: All changes are shown to the user for approval before any API writes

## Altitude API

- **Production**: `https://api.m62.live`
- **Development**: `http://localhost:8080`
- **Auth**: API Key header (`X-API-Key`) or JWT via `POST /api/v1/authenticate`
- **Entity types**: Individual, LegalEntity, AccountFinancial, Contact, TangibleAsset, Household
- **Relationships**: Managed via `EntityRelationshipDto` with types like MEMBER, OWNERSHIP, TRUSTEE, BENEFICIARY, ADVISOR
