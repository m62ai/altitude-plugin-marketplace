# Altitude Plugin Marketplace

Claude Code plugin for the Altitude Wealth Management Platform.

## Installation

```bash
/plugin marketplace add m62ai/altitude-plugin-marketplace
/plugin install m62-altitude-onboarding@altitude-plugin-marketplace
```

## m62-altitude-onboarding

Extract entity data from household document folders (PDFs, Word docs, images, spreadsheets) and onboard to Altitude. Reads every file in a household folder, extracts individuals, legal entities, accounts, insurance policies, tangible assets, liabilities, contacts, and relationships — then pushes to the Altitude API.

**Invoke:** `/m62-altitude-onboarding`

## Team Auto-Install

Add to your project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "altitude-plugin-marketplace": {
      "source": {
        "source": "github",
        "repo": "m62ai/altitude-plugin-marketplace"
      }
    }
  },
  "enabledPlugins": {
    "m62-altitude-onboarding@altitude-plugin-marketplace": true
  }
}
```
