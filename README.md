# Altitude Plugin Marketplace

Claude Code plugins for the Altitude Wealth Management Platform.

## Installation

```bash
# Add the marketplace
/plugin marketplace add m62ai/altitude-plugin-marketplace

# Install individual plugins
/plugin install m62-altitude-onboarding@altitude-tools
/plugin install m62-code-primer@altitude-tools
/plugin install m62-integration-analysis@altitude-tools
/plugin install m62-plan@altitude-tools
```

## Plugins

### m62-altitude-onboarding
Extract entity data from household document folders (PDFs, Word docs, images, spreadsheets) and onboard to Altitude. Reads every file in a household folder, extracts individuals, legal entities, accounts, insurance policies, tangible assets, liabilities, contacts, and relationships — then pushes to the Altitude API.

**Invoke:** `/m62-altitude-onboarding`

### m62-code-primer
Generate focused codebase briefings for the Altitude platform. Primes agents or developers on architecture, domain context, patterns, key files, and gotchas for a specific domain area.

**Invoke:** `/m62-code-primer`

### m62-integration-analysis
Analyze an external API and map its entities/fields to the Altitude domain model. Fetches API documentation, auto-detects entity types, produces field-level mapping tables.

**Invoke:** `/m62-integration-analysis`

### m62-plan
Altitude-specific implementation planner. Analyzes domain impact, discovers codebase patterns, writes a reviewable plan, and waits for approval before implementation.

**Invoke:** `/m62-plan`

## Team Auto-Install

Add to your project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "altitude-tools": {
      "source": {
        "source": "github",
        "repo": "m62ai/altitude-plugin-marketplace"
      }
    }
  },
  "enabledPlugins": {
    "m62-altitude-onboarding@altitude-tools": true,
    "m62-code-primer@altitude-tools": true,
    "m62-plan@altitude-tools": true
  }
}
```
