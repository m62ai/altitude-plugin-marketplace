---
name: m62-altitude-onboarding
description: "Extract entity data from household document folders (PDFs, Word docs, images, spreadsheets) and update the Altitude (Altcore) platform via API. Queries Altitude first to find existing households and their universe of entities (Individuals, LegalEntities, AccountFinancials, Contacts, TangibleAssets, Households), extracts data from documents, matches and merges against existing records (filling empty fields, flagging conflicts), creates relationships, and uploads documents to the correct entity. Use this skill whenever the user mentions Altitude, Altcore, onboarding families, extracting entity data from documents, updating households, processing client folders, or uploading documents. Also trigger when the user has a folder of family documents (trusts, LLCs, tax returns, IDs, insurance, estate plans, bank statements) and wants to populate a wealth management platform."
---

# Altitude Document Extraction & Entity Update

> **⛔ CRITICAL RULE: You MUST read EVERY SINGLE FILE in the household folder. Not most files.
> Not the important-looking files. ALL files. Write a file tracker (`altitude_review/file_tracker.md`)
> listing every file. Mark each READ as you go. Do NOT proceed to Phase 4 until the tracker
> shows 100% READ. If you read 22 out of 60 files, you have failed. This is the #1 cause of
> extraction failure — see "Zero-Skip Rule" in Phase 3.**

This skill extracts entity data from household document folders and updates the Altitude
platform. It follows a query-first, match-and-merge approach — never blindly creating
entities. Every change is reviewed before pushing.

## Prerequisites

Before running, you need:

- **Altitude API base URL**:
  - **Production**: `https://api.m62.live`
  - **Development**: `http://localhost:8080`

- **Authentication** (choose one):
  - **API Key (recommended)**: Add header `X-API-Key: ak_live_xxxxxxxx` to all requests
  - **JWT Token**: POST to `/api/v1/authenticate` with credentials, get `id_token`, use `Authorization: Bearer {token}`

- **firmId** (UUID) for the target firm

Ask the user for these if not already configured. Store them as session variables.

---

## Workflow Overview

```
Phase 1:   Query Altitude       → Find existing household + its full entity universe
Phase 2:   Scan Documents       → Classify ALL files, create read-tracking checklist
Phase 3:   Extract Entities     → PARALLEL agents read files, write extraction caches
Phase 3M:  Merge Extractions    → Combine all agent caches into unified extraction
Phase 3.5: Cross-Doc Validation → Name enrichment, relationship inference, absence tracking
Phase 3.7: Self-Audit           → Adversarial review: any unread files? any unnamed people? any missing entities?
Phase 4:   Match & Merge        → Match extracted entities to existing ones, diff fields
Phase 5:   Review               → Show user what will change (fills + conflicts)
Phase 6:   Push Updates         → PATCH existing entities, POST new ones (with approval)
Phase 7:   Upload Documents     → Associate each document with its correct entity
```

### Parallel Extraction Strategy

**Phase 3 uses parallel sub-agents to avoid context exhaustion.** The orchestrator (you)
NEVER reads document contents directly. Instead, you spawn extraction agents that each
handle a subset of files and write their results to disk.

**Batching rules — split by subdirectory, then by count:**

1. **Group files by subdirectory** first. Each top-level folder in the household directory
   becomes a candidate batch (e.g., `Identification/`, `LLC/`, `Tax Documents/`,
   `Financial Statements/`, `Insurance/`, `Estate Planning/`).

2. **If a subdirectory has > 12 files**, split it into sub-batches of ~10 files each.
   For example, `Tax Documents/` with 25 files becomes 3 batches of ~8-9 files.

3. **If a subdirectory has < 4 files**, merge it with another small directory into one batch.

4. **Target: 2-4 parallel agents** for most households. 1 agent for < 10 files total.

**Example batching for a 40-file household:**
```
Batch 1 (Agent A): Identification/ (3 files) + Onboarding/ (1 file) = 4 files
Batch 2 (Agent B): LLC/ (8 files) + Estate Planning/ (4 files) = 12 files
Batch 3 (Agent C): Tax Documents/ files 1-10 = 10 files
Batch 4 (Agent D): Tax Documents/ files 11-14 + Financial Statements/ (5 files) + Insurance/ (3 files) = 12 files
```

**Each extraction agent receives:**
- Its file list (absolute paths)
- The household name and folder path
- The extraction field definitions (from this skill's Phase 3 entity fields section)
- The document type patterns (from `references/document_type_patterns.md`)
- Instructions to write output to `altitude_review/extraction_cache_batch_{N}.jsonl`

**Each extraction agent produces:**
- One JSONL file: `altitude_review/extraction_cache_batch_{N}.jsonl`
- One tracker section: `altitude_review/file_tracker_batch_{N}.md`

**After ALL agents complete**, the orchestrator:
1. Reads all `extraction_cache_batch_*.jsonl` files
2. Reads all `file_tracker_batch_*.md` files
3. Merges into unified `extraction_cache.jsonl` and `file_tracker.md`
4. Verifies 100% file coverage before proceeding to Phase 3.5

**Spawn agents using the Agent tool:**
```
Agent(
  prompt="[extraction agent prompt with file list and instructions]",
  description="Extract batch N ({directory_name})",
  mode="bypassPermissions"
)
```

Launch ALL extraction agents in a **single message** so they run in parallel.
Do NOT launch them sequentially — that defeats the purpose.

---

## Phase 1: Query Altitude — Get Existing Household Universe

Before touching any documents, query Altitude to understand what already exists.

### Step 1.1: Search for the household

```
GET /api/v1/household/search?searchParams=searchFor:{household_name}&size=50
X-API-Key: {api_key}
```

or with JWT:

```
GET /api/v1/household/search?searchParams=searchFor:{household_name}&size=50
Authorization: Bearer {token}
```

If a matching household is found, record its `id`. If multiple matches, ask the user
which one. If no match, note that this is a new household (will need POST later).

### Step 1.2: Get the household's full relationship graph

Query outgoing relationships (household → members) and incoming relationships:

```
GET /api/v1/household/{householdId}/relationships/from
X-API-Key: {api_key}
```

Or via the standalone entity relationship endpoint:

```
GET /api/v1/entity-relationship/from/HOUSEHOLD/{householdId}
X-API-Key: {api_key}
```

This returns all `EntityRelationshipDto` entries — every individual, legal entity, account,
contact, and their relationship types (MEMBER, OWNERSHIP, TRUSTEE, BENEFICIARY, ADVISOR, etc.).
Record:
- All individual IDs + basic info
- All legal entity IDs + entity types
- All account (AccountFinancial) IDs + account types
- All contact IDs + job titles
- Relationship metadata (type, role, percentage, effectiveFrom, effectiveTo)

### Step 1.3: Fetch full details for each entity

For each individual in the household:
```
GET /api/v1/individual/{id}
```

For each legal entity in the household:
```
GET /api/v1/legal-entity/{id}
```

For each account in the household:
```
GET /api/v1/account-financial/{id}
```

For each contact in the household:
```
GET /api/v1/contact/{id}
```

For tangible assets, query by owner:
```
GET /api/v1/tangible-asset/by-owner/INDIVIDUAL/{individualId}
GET /api/v1/tangible-asset/by-owner/LEGAL_ENTITY/{legalEntityId}
```

For liabilities (query by individual/household):
```
GET /api/v1/liability/by-individual/{individualId}
GET /api/v1/liability/by-household/{householdId}
```

For insurance policies (query by individual/household/legal entity):
```
GET /api/v1/insurance-policy/by-individual/{individualId}
GET /api/v1/insurance-policy/by-household/{householdId}
GET /api/v1/insurance-policy/by-legal-entity/{legalEntityId}
```

Store all of this as the **"Altitude Universe"** — the complete current state of the
household in Altitude. This is the baseline for comparison.

### Step 1.4: Search for accounts and contacts by name

Additionally, search for any accounts and contacts by name pattern:

```
GET /api/v1/account-financial/search?searchParams=searchFor:{account_name_pattern}&size=50
GET /api/v1/contact/search?searchParams=searchFor:{contact_name_pattern}&size=50
```

### Step 1.5: Build the Altitude Universe index

Create an in-memory index for matching:

```json
{
  "household": { "id": "...", "name": "...", "firmId": "..." },
  "individuals": [
    {
      "id": "...", "firstName": "...", "lastName": "...", "ssn": "...",
      "dateOfBirth": "...", "email": "...", "phone": "...", "addressLegal": "..."
    }
  ],
  "legal_entities": [
    {
      "id": "...", "legalName": "...", "entityType": "...", "taxId": "...",
      "jurisdiction": "...", "formationDate": "...", "incorporationState": "...", "incorporationCountry": "..."
    }
  ],
  "accounts": [
    {
      "id": "...", "name": "...", "accountNumber": "...", "accountCategory": "...",
      "subCategory": "...", "custodianId": "..."
    }
  ],
  "contacts": [
    {
      "id": "...", "firstName": "...", "lastName": "...", "email": "...",
      "phone": "...", "jobTitle": "..."
    }
  ],
  "tangible_assets": [
    {
      "id": "...", "name": "...", "category": "...", "assetType": "...",
      "serialOrIdentifier": "...", "currentValue": "..."
    }
  ],
  "liabilities": [
    {
      "id": "...", "name": "...", "liabilityType": "...", "liabilityStatus": "...",
      "lenderName": "...", "accountNumber": "...", "currentBalance": "...",
      "interestRate": "...", "monthlyPayment": "..."
    }
  ],
  "insurance_policies": [
    {
      "id": "...", "name": "...", "policyCategory": "...", "policyNumber": "...",
      "carrierName": "...", "policyStatus": "...", "coverageAmount": "...",
      "annualPremium": "..."
    }
  ],
  "relationships": [ ... ]
}
```

Save as `{household_folder}/altitude_review/altitude_universe.json` for reference.

---

## Phase 2: Scan & Classify Documents

List all files recursively in the household folder. Classify each document using the
patterns in `references/document_type_patterns.md`. Key classification rules:

**Extraction priority:**
- **Tier 1** (extract first): Onboarding sheets, IDs (DLs, passports), trust agreements,
  LLC operating agreements, articles of organization/incorporation, EIN letters,
  account applications
- **Tier 1.5** (NEVER SKIP — compact, data-dense IRS forms): Form 1098 (mortgage → creates
  liability + tangible asset), Schedule K-1 (ownership percentages — authoritative), Form
  1099-DIV/INT/B/R (account + custodian validation), Form W-2 (employer + income), Form 5498
  (IRA details). A single 1098 produces 1 liability, 1 tangible asset, and 2+ relationships.
  A single K-1 produces an entity + ownership relationship with exact percentage.
- **Tier 2**: Personal tax returns (1040), entity tax returns (1065/1120/1120S/1041),
  account statements, insurance policy declarations, property tax bills, beneficiary designations
- **Tier 3**: Financial statements, meeting notes, presentations, valuations, estate planning flowcharts
- **Tier 4** (skip): Duplicates ("Copy of", "zDupes"), receipts, .msg files, spreadsheets
  with personal notes

**Document-to-entity association** — each document maps to an entity type for upload:
Read `references/document_entity_association.md` for the complete mapping of which
document types associate with which Altitude entity type and what `documentSubType`
to use.

---

## Phase 3: Extract Entities from Documents

### Large PDF Strategy (20+ pages)

Tax returns and combined statements are often 50-200+ pages. Reading only the first few pages
will miss K-1 summaries, W-2s, 1099s, Schedule H, and passthrough entity details buried deep
in the document. Use this two-pass strategy:

**Pass 1 — Page Index Scan** (fast, text-only):
```python
python3 -c "
from pypdf import PdfReader
reader = PdfReader('file.pdf')
print(f'Total pages: {len(reader.pages)}')
for i, page in enumerate(reader.pages):
    text = (page.extract_text() or '')[:150].replace('\n', ' | ')
    print(f'  Page {i+1}: {text}')
"
```

This produces a one-line summary per page. Scan the output for keywords that signal data-rich
pages:

| Keyword | What It Signals | Action |
|---------|----------------|--------|
| `K-1`, `Schedule K-1` | Partnership/LLC ownership + income | Read full page — TAX_K1 checklist |
| `W-2`, `Wage and Tax` | Employer name, wages, SSN | Read full page — TAX_W2 checklist |
| `1099`, `1099-DIV`, `1099-INT`, `1099-B`, `1099-R` | Account/custodian validation, income | Read full page — TAX_1099 checklist |
| `1098`, `Mortgage Interest` | Mortgage lender, balance, property | Read full page — TAX_1098 checklist |
| `Schedule E`, `Passthrough` | Entity names, EINs, income types | Read full page |
| `Schedule H`, `Household Employ` | Domestic staff, household employer EIN | Read full page |
| `Schedule A`, `Itemized` | Mortgage interest, charitable, taxes | Skim for amounts |
| `Schedule C`, `Profit or Loss` | Sole proprietorship business | Read full page |
| `Sign Here`, `Occupation`, `Preparer` | Occupations, CPA name/phone | Read full page (usually page 2 of 1040) |
| `8879`, `e-file` | SSNs, AGI confirmation, preparer | Read full page |
| Entity names (trust names, LLC names) | Entity K-1 details | Read full page |
| `LESSER`, `TRUST`, or any family surname | Related trust/entity income | Read full page |

**Pass 2 — Targeted Deep Read**:
Read ONLY the flagged pages using Claude's Read tool with specific page ranges. For a typical
200-page return, you'll usually need to read 15-25 key pages, not all 200.

**Minimum pages to ALWAYS read from a personal 1040 return:**
1. Cover letter (page 1) — preparer firm, client address
2. Form 8879 — SSNs, AGI, preparer name
3. Form 1040 pages 1-2 — income summary, dependents, occupations, preparer, filing status
4. Schedule E page 2 — ALL passthrough entity names + EINs
5. Passthrough income detail pages — entity-by-entity breakdown
6. Schedule H (if present) — household employment
7. Any pages with K-1, W-2, 1098, or 1099 keywords

**Password-protected PDFs:**
Tax returns are often password-protected. The password is frequently in the filename
(e.g., "pass 701431"). Decrypt before reading:
```bash
qpdf --password=PASSWORD --decrypt input.pdf /tmp/decrypted.pdf
```
If `qpdf` is not installed: `brew install qpdf` (macOS).

### ⛔ CRITICAL: Zero-Skip Rule — THE #1 CAUSE OF EXTRACTION FAILURE

**EVERY file in the household folder MUST be opened and read. NO EXCEPTIONS.**

This is the single most important rule in this skill. In testing, 100% of extraction failures
trace back to files that were not read. Not "low quality" files. Not "redundant" files. Files
that were simply never opened. An Operating Agreement that contains ownership percentages. A
1099 that reveals an account number. A DocuSign certificate that identifies the employer. An
email signature with an attorney's contact info.

**You WILL be tempted to skip files.** You will think "I already have the EIN from the onboarding
sheet, I don't need to read the EIN letter." You will think "The amendments just change the
address, I already know the address." You will think "The Sunbiz is just a state filing." Every
one of these thoughts leads to missed data. Every document contains something — a name, an
address, a date, a registered agent, a formation date — that cannot be found anywhere else.

**Do not classify files as low priority and skip them.** Do not read 22 out of 60 files and call
it done. Read ALL 60. If the context window gets full, save your extraction progress to disk
and continue in a follow-up pass.

For each file, at minimum:
- **PDFs**: Read at least page 1. If it's a multi-page form (tax return, statement), use the
  Large PDF Strategy above to find all data-rich pages.
- **Images (.jpg, .png)**: Read with Claude's vision. Even a property photo confirms a real
  asset exists.
- **Word docs (.docx)**: Convert with `textutil -convert txt` and read. If conversion fails,
  try `pandoc`. If both fail, flag for user — don't silently skip.
- **Emails (.eml)**: Parse headers + body. Extract attachments and process them too.

**Enforce with a tracking file**: After Phase 2 classification, write a file checklist to
`altitude_review/file_tracker.md` with every file path. As you read each file, update the
tracker with status (READ/SKIPPED) and a one-line summary of what was extracted. Before
Phase 4, parse the tracker and verify ZERO files have status other than READ. If any files
remain unread, you MUST read them before proceeding. This is not optional.

Example tracker format:
```
| # | File | Status | Extracted |
|---|------|--------|-----------|
| 1 | Identification/DL.png | READ | Brett Adam, Michaela Dylan, DOBs, addresses |
| 2 | LLC/Operating Agreement.pdf | READ | Members: Brett 60%, Michaela 40% |
| 3 | Tax/1099-INT.pdf | PENDING | |
```

**For folders with 10+ files**, use the Parallel Extraction Strategy (see Workflow Overview).
Spawn one Agent per batch. Each agent handles its assigned files independently and writes
results to its own `extraction_cache_batch_{N}.jsonl` file. The orchestrator merges after all
agents complete. For folders with < 10 files, a single agent handles all files.

### Extraction Cache (REQUIRED — each agent writes its own)

**After reading EACH file**, each extraction agent appends what it learned to its own cache file:
`altitude_review/extraction_cache_batch_{N}.jsonl` (one JSON object per line, append-only).
The orchestrator later merges all batch files into `altitude_review/extraction_cache.jsonl`.

Each line captures everything extracted from a single file:

```jsonl
{"file": "Identification/DL.png", "readAt": "2026-03-19T22:00:00Z", "fileNumber": 1, "entities": {"individuals": [{"name": "Brett Adam Podolsky", "dob": "1988-02-19", "gender": "M", "dlNumber": "P342-061-88-059-0", "dlState": "FL", "dlExpiry": "2031-02-19", "address": "3985 NW 53rd St, Boca Raton, FL 33496"}]}, "relationships": [], "contacts": [], "accounts": [], "notes": "Both Brett and Michaela DLs on same image"}
{"file": "LLC/Hercules/Operating Agreement.pdf", "readAt": "2026-03-19T22:01:00Z", "fileNumber": 2, "entities": {"legalEntities": [{"name": "Hercules Lender LLC", "type": "LLC", "managementType": "MEMBER_MANAGED", "opAgreementDate": "2022-09-29"}]}, "relationships": [{"source": "Brett Podolsky", "target": "Hercules Lender LLC", "type": "OWNERSHIP", "percentage": 50, "role": "Managing Member"}], "contacts": [{"name": "Jason Evans", "role": "Registered Agent", "address": "2300 NW Corporate Blvd Suite 215, Boca Raton FL 33431"}], "accounts": [], "notes": "Principal: 20352 Hacienda Ct"}
```

**Why this matters:**
- **Resumability**: If context resets at file 150 of 292, the next session reads the cache
  and picks up at file 151 — no re-reading of the first 150 files
- **Cross-document validation**: Later files can check against earlier extractions ("is this
  the same trust?") without re-reading the source documents
- **Subagent handoff**: One agent extracts (writes cache), another matches/merges (reads cache)
- **Audit trail**: Every extracted field traces to a specific file

**Cache rules:**
- Append after EACH file, not at the end of a batch — partial progress is saved
- Include ALL extracted data, not just summaries — names, dates, numbers, addresses, percentages
- Use `fileNumber` to track progress — on resume, skip files with fileNumber ≤ max in cache
- For files with no extractable data, still append a line with empty entities and a note explaining why
- The cache is the source of truth for Phase 4 matching — read it instead of relying on context memory

**On resume**, check for existing cache:
```python
import json
existing = []
try:
    with open('altitude_review/extraction_cache.jsonl') as f:
        existing = [json.loads(line) for line in f if line.strip()]
    last_file = max(e['fileNumber'] for e in existing)
    print(f"Resuming from file {last_file + 1} ({len(existing)} files already cached)")
except FileNotFoundError:
    print("No cache found, starting fresh")
```

### Standard Document Extraction

For each Tier 1 and Tier 2 document, extract structured data. Use Claude's native tools:

- **PDFs**: Use Claude Read tool natively (supports text and scanned PDFs with vision)
- **Word docs (.docx)**: Extract with `textutil -convert txt file.docx` (macOS) or
  `pandoc file.docx -t plain`; then read the output
- **Images (.jpg, .png)**: Use Claude Read tool — Claude can see images natively (multimodal)
- **Spreadsheets (.xlsx)**: Use inline Python:
  ```
  python3 -c "import openpyxl; wb=openpyxl.load_workbook('file.xlsx'); print([sheet.title for sheet in wb.sheetnames])"
  ```
- **Emails (.eml)**: Parse with Python's `email` module:
  ```
  python3 -c "
  import email, sys
  with open('file.eml', 'rb') as f:
      msg = email.message_from_binary_file(f)
  print('From:', msg['From'])
  print('To:', msg['To'])
  print('Date:', msg['Date'])
  print('Subject:', msg['Subject'])
  for part in msg.walk():
      if part.get_content_type() == 'text/plain':
          print(part.get_payload(decode=True).decode(errors='replace'))
  "
  ```
  Extract entity data from the email body (e.g., account confirmations, policy updates,
  advisor correspondence). Save any attachments to a temp directory and process them
  separately as their native file type (PDF, DOCX, etc.):
  ```
  python3 -c "
  import email, os
  with open('file.eml', 'rb') as f:
      msg = email.message_from_binary_file(f)
  for part in msg.walk():
      fn = part.get_filename()
      if fn:
          with open(os.path.join('/tmp/eml_attachments', fn), 'wb') as out:
              out.write(part.get_payload(decode=True))
          print(f'Saved attachment: {fn}')
  "
  ```

For each document, extract:

**Individuals:**
- Core: firstName, lastName, preferredName (known-by/English name — e.g., "Tina" for legal "Dong"), dateOfBirth, ssn, gender, maritalStatus, citizenship
- Contact: email, phoneNumberPrimary, phoneNumberSecondary, faxNumber
- Address: addressLine1, addressLine2, city, state, postalCode, country, addressType, addressEmployer
- Financial: netWorth, netWorthLiquid, annualIncome, sourceOfFunds, riskTolerance, timeHorizon
- Tax: taxStatus, taxIdType (SSN/ITIN/EIN/FOREIGN_TIN/FOREIGN_ENTITY_TIN/VAT/GST/BUSINESS_NUMBER), taxIdIssuingCountry
- Regulatory: accreditedInvestorStatus, isPoliticallyExposedPerson
- Beneficiary: transferOnDeath beneficiaries
- Lifecycle: dateOfDeath, lifecycleStatus
- Profession: occupation, employer

**Legal Entities:**
- Core: legalName, entityType, formationDate, jurisdiction, incorporationState, incorporationCountry
- Tax: taxId (EIN), taxClassification, fiscalYearEnd
- Governance: llcManagementType, primarySigners, nominee, eligibility
- Registered Agent: agent name and address
- Authorized Shares: corpAuthorizedShares, corpIssuedShares
- Compliance: KYC/AML tracking, regulatoryStatus, affiliations
- **Trust-specific** (if entityType=TRUST):
  - Trustees: trustee names and roles
  - Grantor: grantor name and revocable status (revocable/irrevocable)
  - Beneficiaries: primary and contingent beneficiary names
  - Settlor and Trustee names, roles
  - Situs (jurisdiction), governing law
  - Investment Advisor, Distribution Advisor, Crummey Power Holders
  - Powers of Appointment, Spendthrift Provision, GST exemption status
  - Insurance Provisions, Amendment tracking (number, date), Restatement status
  - Pour-over trust name, trust aliases

**Account Financials:**
- Core: name, accountNumber, accountCategory (INDIVIDUAL/ENTITY), subCategory
- Type: wrapper (IRA/401k if applicable), taxStatus
- Custodian: custodianId, custodian name
- Ownership: ownershipType (PERCENT_BASED default)
- Connection: providerDetails (sourceSystemName, sourceSystemAccountId)

**Contacts:**
- Core: firstName, lastName, email, phone, jobTitle
- Note: Contact DTO has NO companyName/organization field. Company info goes in biography or via ADVISOR entity relationship.
- Address: addressLine1, addressLine2, city, state, postalCode, country

**Tangible Assets:**
- Core: name, category (LUXURY/VEHICLE/REAL_PROPERTY/COLLECTIBLE/OTHER)
- Asset Type: assetType (CAR, MOTORCYCLE, BOAT, YACHT, AIRCRAFT, HELICOPTER, RV, PRIMARY_RESIDENCE, VACATION_HOME, RENTAL_PROPERTY, COMMERCIAL_PROPERTY, LAND, FARM_RANCH, TIMESHARE, WATCH, JEWELRY, HANDBAG, FASHION, LUXURY_OTHER, ART, WINE, ANTIQUE, MEMORABILIA, COINS, STAMPS, BOOKS, MUSICAL_INSTRUMENT, COLLECTIBLE_OTHER, EQUIPMENT, LIVESTOCK, FURNITURE, OTHER_TYPE)
- Identification: serialOrIdentifier, VIN, parcel number
- Valuation: currentValue, valuationDate, valuationSource, taxBasis, taxBasisDate, acquisitionType (PURCHASE/AUCTION/GIFT/INHERITANCE/COMMISSION/EXCHANGE/PRIZE), purchaseDate, purchasePrice
- Status: status (ACTIVE/SOLD/TRANSFERRED/DONATED/DISPOSED/STOLEN/LOST)
- Location: location, storageFacility, custodianName, custodianContact
- Insurance: isInsured (Boolean), primaryInsurancePolicyNumber, insuredValue, insuranceExpirationDate (Note: full insurance details are on the InsurancePolicy entity, not TangibleAsset)
- Estate: includedInEstate, estateDisposition, designatedBeneficiaryId, estateNotes
- Type-specific: vehicleDetails (make/model/year), realPropertyDetails (address/square footage),
  luxuryDetails (brand/model), collectibleDetails (artist/medium)
- Maintenance: maintenanceRecords, provenance chain, condition

**Insurance Policies:**
- Core: name, policyCategory (LIFE/UMBRELLA/LONG_TERM_CARE/DISABILITY/HEALTH/AUTO/HOMEOWNERS/FLOOD/CYBER/COLLECTIONS/WINDSTORM/OTHER), policyNumber, carrierName, policyStatus (ACTIVE/LAPSED/CANCELLED/PAID_UP/SURRENDERED/MATURED/PENDING)
- Financial: coverageAmount, annualPremium, paymentFrequency (MONTHLY/BI_WEEKLY/QUARTERLY/ANNUAL/INTEREST_ONLY), deductible
- Dates: effectiveDate, expirationDate, applicationDate, issueDate, firstPaymentDate
- Description: description (max 4000)
- Life-specific (policyCategory=LIFE): lifePolicyType (TERM/WHOLE_LIFE/UNIVERSAL/VARIABLE_UNIVERSAL/INDEXED_UNIVERSAL/SURVIVORSHIP/GROUP_TERM), deathBenefit, cashValue, cashValueAsOfDate, loanBalance, termLengthYears, termExpirationDate, isConvertible, conversionDeadline, isIlitOwned, ilitLegalEntityId, isSecondToDie, secondInsuredIndividualId, guaranteedDeathBenefit, riders, surrenderChargeSchedule, dividendOption (CASH/PREMIUM_REDUCTION/ACCUMULATE_AT_INTEREST/PAID_UP_ADDITIONS/ONE_YEAR_TERM)
- Umbrella-specific (policyCategory=UMBRELLA): excessLiabilityCoverage, underlyingAutoRequired, underlyingHomeRequired, underlyingPoliciesDescription, coversRentalProperties, coversWatercraft, uninsuredMotorist
- LTC-specific (policyCategory=LONG_TERM_CARE): dailyBenefitAmount, benefitPeriodDescription, benefitPeriodMonths, eliminationPeriodDays, inflationProtectionType (NONE/SIMPLE/COMPOUND_3_PERCENT/COMPOUND_5_PERCENT/CPI_LINKED/FUTURE_PURCHASE_OPTION), coversHomeCare, coversAssistedLiving, coversNursingFacility, coversAdultDayCare, sharedBenefitRider, isPartnershipQualified, remainingBenefitPool
- Disability-specific (policyCategory=DISABILITY): monthlyBenefitAmount, benefitPeriodDescription, eliminationPeriodDays, isOwnOccupation, ownOccupationPeriodDescription, costOfLivingAdjustment, futureIncreaseOption, residualDisabilityRider, isGroupPolicy, isTaxableBenefit

**Liabilities:**
- Core: name, liabilityType (MORTGAGE/HOME_EQUITY_LOC/STUDENT_LOAN/MARGIN_LOAN/PLEDGED_ASSET_LINE/CREDIT_LINE/CREDIT_CARD/AUTO_LOAN/PERSONAL_LOAN/BUSINESS_LOAN/OTHER), liabilityStatus (CURRENT/DELINQUENT/IN_DEFERMENT/IN_FORBEARANCE/PAID_OFF/DEFAULTED/CHARGED_OFF)
- Lender: lenderName, accountNumber
- Balance: originalBalance, currentBalance, balanceAsOfDate, creditLimit, availableCredit
- Rate: interestRate, interestRateType (FIXED/VARIABLE/HYBRID), indexRateDescription, rateCap, rateFloor
- Payment: monthlyPayment, minimumPayment, paymentFrequency (MONTHLY/BI_WEEKLY/QUARTERLY/ANNUAL/INTEREST_ONLY), nextPaymentDate
- Term: originationDate, maturityDate
- Collateral: isSecured, collateralDescription, linkedTangibleAssetId, linkedAccountFinancialId
- Tax: isInterestDeductible, interestDeductionType (MORTGAGE_INTEREST/INVESTMENT_INTEREST/STUDENT_LOAN_INTEREST/BUSINESS_INTEREST/NONE), interestPaidYtd, interestPaidPriorYear
- Description: description (max 4000)

**Estate Planning (nested on Individual via PATCH):**
- Will: hasWill, willDate, executorName, contingentExecutorName, attorneyName, jurisdiction
- Healthcare: hasHealthcareDirective, directiveDate, agentName, alternateAgentName, hasLivingWill
- Financial POA: hasFinancialPoa, type (DURABLE/SPRINGING/LIMITED/GENERAL), agentName, poaDate
- Guardianship: hasGuardianDesignation, guardianName, alternateGuardianName
- Marital: hasPrenuptialAgreement, prenuptialDate, hasPostnuptialAgreement
- Estate Review: lastReviewDate, estimatedEstateValue, estimatedEstateTaxLiability, lifetimeGiftExclusionUsed

**Charitable Profile (nested on Individual/LegalEntity via PATCH):**
- Extract philanthropic interests, giving history, donor-advised fund info from charitable documents
- Individual: nested under `philanthropicProfile` field in Individual PATCH
- LegalEntity: nested under `charitableDetails` field in LegalEntity PATCH

Tag every extracted field with its `_source` document path.

**IMPORTANT**: For each document, use the document-type-specific extraction checklist in
`references/document_type_patterns.md`. These checklists ensure you don't miss middle names,
occupations, relationship inferences, entity hierarchies, or absence-as-data signals.

### Step 3.5: Cross-Document Validation Pass

After extracting from ALL documents, run these mandatory checks before proceeding to Phase 4:

1. **Name enrichment** — For each individual, find the MOST COMPLETE version of their name
   across all documents. Tax returns and account statements often reveal middle names that
   onboarding sheets omit.

2. **Relationship inference** — Check for implicit relationships:
   - Joint 1040 filing → SPOUSE relationship
   - No dependents on 1040 → note absence (no PARENT/CHILD needed)
   - K-1 partner info → MEMBER/PARTNER relationships with percentages
   - "Managing member of X" → entity-to-entity MEMBER relationship
   - Joint account title (JT TEN) → both owners get OWNERSHIP at 50%

3. **Multi-hop ownership chains** — When entity A owns entity B which manages entity C,
   create ALL intermediate relationships (A→B OWNERSHIP, B→C MEMBER), not just A→C.

4. **Absence tracking** — Explicitly note when expected data is missing:
   - No estate planning docs → record `estatePlanning.will.hasWill: false`
   - No insurance policies found → flag for review
   - No trusts despite high net worth → flag as potential planning gap

5. **Contact extraction from embedded references** — Every named professional in any document
   becomes a Contact entity: tax preparer on 1040, financial advisor on account statement,
   attorney on trust agreement, CFO mentioned in onboarding sheet.

6. **Insurance ↔ Tangible Asset cross-linking** — For every insurance policy that covers a
   tangible asset, record the linkage so that during Phase 6:
   - The TangibleAsset gets `isInsured: true`, `primaryInsurancePolicyNumber`, `insuredValue`,
     and `insuranceExpirationDate` set
   - Examples: homeowners policy → primary residence, auto policy → each vehicle,
     collections/valuable articles policy → each scheduled item (watches, jewelry, art)
   - Auto insurance schedules list specific vehicles — create a TangibleAsset (VEHICLE)
     for EACH vehicle listed on the policy, not just vehicles found in separate docs

7. **Liability ↔ Tangible Asset cross-linking** — For every liability secured by a tangible
   asset, record the linkage so that during Phase 6:
   - The Liability gets `linkedTangibleAssetId` set to the tangible asset's UUID after creation
   - The Liability gets `isSecured: true` and `collateralDescription` set
   - Examples: mortgage → property, auto loan → vehicle, boat loan → boat,
     art-secured loan → art collection
   - If the loan references a vehicle/property that hasn't been created as a TangibleAsset yet,
     create the TangibleAsset FIRST, then set `linkedTangibleAssetId` on the Liability

### Step 3.7: Self-Audit Pass (Adversarial Review)

Before proceeding to Phase 4, act as your own auditor. Pretend someone else did the extraction
and you are checking their work. Go through these checks:

**Document coverage audit:**
- [ ] List every file in the folder. Is every single one marked as READ? If any file was skipped,
  read it now. Common misses: .docx files that failed to convert, 1099 cover pages dismissed as
  "just a cover letter," photos, emails.

**Entity completeness audit — for each entity type, ask:**
- [ ] **Individuals**: Are there any NAMED PEOPLE in any document who are not yet in my entity list?
  Check: estate planning docs name guardians, trustees, beneficiaries, executors. Insurance docs
  name agents. Tax docs name preparers. Emails name senders. LLC docs name attorneys and managers.
  Every named person is either an Individual or a Contact.
- [ ] **Legal Entities**: Did every entity get created? Common miss: when two spouses each have their
  OWN trust (not one shared trust), that's TWO legal entities. Check LLC operating agreements for
  managing members that are THEMSELVES entities (entity-to-entity chains).
- [ ] **Accounts**: Did every 1099 reveal an account number + custodian? Did every bank/institution
  mentioned in the onboarding sheet get an account created? Did every account statement get its
  account number extracted?
- [ ] **Insurance Policies**: Were all policies from the insurance summary captured? Are there
  additional policy documents in the folder not covered by the summary?
- [ ] **Tangible Assets from Insurance**: Did the auto policy list specific vehicles? Create a
  TangibleAsset (VEHICLE) for each. Did the homeowners policy cover a property? Ensure the
  property TangibleAsset has `isInsured`, `insuredValue`, `primaryInsurancePolicyNumber` set.
  Did a collections/valuable articles policy schedule individual items? Each is a TangibleAsset.
- [ ] **Liability ↔ Asset Links**: For every mortgage, auto loan, boat loan, or secured loan —
  is there a corresponding TangibleAsset? If yes, record `linkedTangibleAssetId`. If the asset
  doesn't exist yet, create it first.
- [ ] **Contacts**: Did EVERY professional mentioned in ANY document get a Contact entity? Check:
  attorneys (estate, corporate, LLC formation — these are often different people), CPAs, insurance
  agents, financial advisors (from 1099s and statements), CFOs, and loan counterparties.

**Relationship completeness audit:**
- [ ] Does every Individual have at least one relationship (OWNERSHIP from household, or PARENT/CHILD)?
- [ ] Does every LegalEntity have at least one relationship (OWNERSHIP, TRUSTEE, GRANTOR)?
- [ ] Does every Account have an OWNERSHIP relationship to its owner?
- [ ] Is there a SPOUSE relationship if the documents show married individuals?
- [ ] Are PARENT→CHILD relationships created for BOTH parents, not just one?
- [ ] Does every Contact have at least one professional relationship (ADVISOR/ATTORNEY/ACCOUNTANT)?

**Data quality audit:**
- [ ] Do any two entities have conflicting addresses? (Flag for user)
- [ ] Are SSNs 9 digits with no dashes?
- [ ] Are phone numbers in E.164-compatible format (digits only)?
- [ ] Are dates in ISO format (YYYY-MM-DD)?
- [ ] Is any sensitive data (passwords, credit cards) accidentally included in entity fields?

---

## Phase 4: Match & Merge — The Core Logic

This is the critical phase. Read `references/match_merge_rules.md` for detailed rules.

### Step 4.1: Deduplicate extracted entities (cross-document merge)

The same person or entity may appear in multiple documents. Merge extracted records
using these identity signals:

**Individuals** — match if ANY of:
- SSN matches exactly (definitive)
- Full name similarity ≥ 0.85 AND (DOB matches OR address matches)
- Full name similarity ≥ 0.65 AND DOB matches AND address matches

**Legal Entities** — match if ANY of:
- EIN/Tax ID matches exactly (definitive)
- Legal name similarity ≥ 0.7 AND entity type matches

**Accounts** — match if ANY of:
- Account number matches exactly (definitive)
- Account name similarity ≥ 0.8 AND custodian matches

**Contacts** — match if ANY of:
- Email matches exactly (definitive)
- Phone matches exactly (definitive)
- Full name similarity ≥ 0.85 AND job title matches

**Tangible Assets** — match if ANY of:
- Address/parcel number matches (for real property)
- VIN/serial number matches
- Name similarity ≥ 0.8 AND category matches AND owner matches

**Insurance Policies** — match if ANY of:
- Policy number matches exactly (definitive)
- Name similarity ≥ 0.8 AND carrier name matches (case-insensitive)
- Carrier + coverage amount + policy category all match (probable)

**Liabilities** — match if ANY of:
- Account number + lender name matches exactly (definitive)
- Name similarity ≥ 0.8 AND lender name matches (case-insensitive)
- Lender + liability type + current balance within 5% tolerance (probable)

When merging across documents, prefer the most specific/complete value for each field.
Track all source documents.

### Step 4.2: Match extracted entities to Altitude Universe

For each merged extracted entity, attempt to match it to an existing Altitude entity:

**Individual matching against Altitude:**
1. SSN exact match (if both have SSN) → definitive match
2. firstName + lastName exact match (case-insensitive) → strong match
3. firstName + lastName fuzzy match (≥ 0.85 similarity) + DOB match → strong match
4. lastName match + DOB match → probable match (flag for confirmation)
5. No match → candidate for new entity creation

**Legal Entity matching against Altitude:**
1. EIN/taxId exact match → definitive match
2. legalName exact match (case-insensitive) → strong match
3. legalName fuzzy match (≥ 0.8 similarity) + entityType match → strong match
4. No match → candidate for new entity creation

**Account matching against Altitude:**
1. accountNumber exact match → definitive match
2. Account name fuzzy match (≥ 0.85 similarity) + custodian match → strong match
3. No match → candidate for new entity creation

**Contact matching against Altitude:**
1. email exact match → definitive match
2. phone exact match → definitive match
3. firstName + lastName exact match (case-insensitive) + jobTitle match → strong match
4. No match → candidate for new entity creation

**Tangible Asset matching against Altitude:**
1. serialOrIdentifier exact match → definitive match
2. Name + category + owner match → strong match
3. Address match (for real property) → strong match
4. No match → candidate for new entity creation

**Insurance Policy matching against Altitude:**
1. policyNumber exact match → definitive match
2. name + carrierName match (case-insensitive) → strong match
3. carrierName + coverageAmount + policyCategory match → probable match
4. No match → candidate for new entity creation

**Liability matching against Altitude:**
1. accountNumber + lenderName exact match → definitive match
2. name + lenderName match (case-insensitive) → strong match
3. lenderName + liabilityType + currentBalance within 5% → probable match
4. No match → candidate for new entity creation

### Step 4.3: Field-level diff against Altitude

For each matched entity, compare every field:

```
For each field in the extracted entity:
  altitude_value = existing_altitude_entity[field]
  extracted_value = extracted_entity[field]

  IF altitude_value is null/empty AND extracted_value is not null/empty:
    → FILL: Queue this field for automatic update (safe to copy)

  ELIF altitude_value is not null/empty AND extracted_value is not null/empty:
    IF altitude_value == extracted_value:
      → MATCH: Values agree, no action needed
    ELSE:
      → CONFLICT: Values differ, flag for user review

  ELIF altitude_value is not null/empty AND extracted_value is null/empty:
    → KEEP: Altitude has data we don't, leave it alone
```

Generate three lists for each entity:
1. **Auto-fill fields** — empty in Altitude, has value from documents
2. **Matching fields** — same value in both (no action)
3. **Conflicting fields** — different values, need user decision

### Step 4.4: Extract and validate relationships

From documents, extract all relationships between entities. Use the relationship matrix below
to validate that source→target combinations are allowed:

**Critical Onboarding Relationships:**

| Type | Where Extracted | Source→Target | Needs % | Direction |
|------|----------------|--------------|---------|-----------|
| OWNERSHIP | Operating agreements, account apps, policy declarations, loan docs | IND→LE, IND→ACCT, IND→TA, IND→INS_POL, IND→LIAB, LE→ACCT, LE→INS_POL, LE→LIAB | Yes | Unidirectional |
| INSURED | Insurance policy declarations | IND→INS_POL | No | Unidirectional |
| BENEFICIAL_OWNERSHIP | Trust docs, entity docs | IND→LE | Yes | Unidirectional |
| OWNERSHIP | Household membership | HH→IND | Yes | Unidirectional (Household owns Individuals, NOT the reverse) |
| MEMBER | LLC membership agreements | IND→LE | Yes | Unidirectional |
| PARTNER | Partnership agreements | IND→LE | Yes | Unidirectional |
| TRUSTEE | Trust agreements | IND→LE | No | Unidirectional |
| SUCCESSOR_TRUSTEE | Trust agreements | IND→LE | No | Unidirectional |
| GRANTOR | Trust agreements | IND→LE | No | Unidirectional |
| BENEFICIARY | Trust agreements, TOD forms, will | IND→LE, IND→ACCT | Optional | Unidirectional |
| SPOUSE | Marriage certificates, onboarding sheets | IND→IND | No | Symmetric |
| PARENT | Onboarding sheets | IND→IND | No | Unidirectional |
| CHILD | Onboarding sheets | IND→IND | No | Unidirectional |
| POWER_OF_ATTORNEY | POA documents | IND→IND, IND→LE, IND→ACCT | No | Unidirectional |
| GUARDIAN | Court orders | IND→IND | No | Unidirectional |
| AUTHORIZED_SIGNER | Account apps, corporate resolutions | IND→ACCT, IND→LE | No | Unidirectional |
| OFFICER | Corporate bylaws, filings | IND→LE | No | Unidirectional |
| DIRECTOR | Corporate bylaws, filings | IND→LE | No | Unidirectional |
| ADVISOR | Engagement letters, onboarding sheets | HH→CONTACT, IND→CONTACT, LE→CONTACT | No | Unidirectional (entity points TO the advisor) |
| ACCOUNTANT | Tax returns (preparer name), onboarding sheets | HH→CONTACT, IND→CONTACT, LE→CONTACT | No | Unidirectional (entity points TO the CPA) |
| ATTORNEY | Trust docs (drafting attorney), will, onboarding | HH→CONTACT, IND→CONTACT, LE→CONTACT | No | Unidirectional (entity points TO the attorney) |

**Validation rules:**
- SPOUSE: symmetric (both directions, max 1 per person)
- PARENT: max 2 on target individual
- GUARDIAN: max 1 on target individual
- Percentage REQUIRED for: OWNERSHIP (HH→IND, IND→LE, IND→ACCT), BENEFICIAL_OWNERSHIP, MEMBER (IND→LE for LLC), PARTNER
- All other types: percentage optional

For each relationship, extract:
- sourceEntityId and sourceEntityType
- targetEntityId and targetEntityType
- relationshipType (from matrix above)
- role (optional, e.g., "Managing Member", "Trustee")
- percentage (if type requires it)
- effectiveFrom (when the relationship started, if known)
- effectiveTo (when the relationship ended, if known — null means current/ongoing)
- isPrimary (if relationship has a primary designation)

### Step 4.6: Determine Relationship Currency (Current vs Historical)

**Every relationship must be classified as CURRENT or HISTORICAL before creation.**

Documents often reference people and entities in past tense or with context that indicates
the relationship has ended. Look for these signals:

**Historical relationship indicators:**
- "Former attorney", "prior advisor", "previously represented by"
- Deceased individuals referenced as past trustees, executors, or agents
- Superseded documents (e.g., an amendment that replaces the original operating agreement's
  managing member designation)
- Terminated professional engagements (e.g., "engagement ended 2024")
- Resigned officers/directors ("resigned as trustee effective 3/15/2024")
- Replaced insurance agents, CPAs, or advisors
- Expired powers of attorney or guardianship designations
- Trust amendments that change trustees or beneficiaries (old ones are historical)

**Current relationship indicators:**
- Named in the most recent version of a document (latest amendment, restated agreement)
- Active professional engagement (current CPA on latest tax return, current attorney on
  recent correspondence)
- Named on currently effective insurance policies
- Current LLC members on latest Sunbiz filing
- Active trustees, grantors, beneficiaries on current trust agreement

**How to set effectiveFrom — extract the start date from documents:**

| Relationship Type | Where to Find Start Date |
|---|---|
| OWNERSHIP (LLC) | Operating agreement execution date, or articles of organization filing date |
| OWNERSHIP (Trust) | Trust execution date (original, not restatement) |
| MEMBER/PARTNER | Operating/partnership agreement date, or amendment date that added the member |
| TRUSTEE | Trust agreement date, or amendment date that appointed the trustee |
| GRANTOR | Trust agreement date (original execution) |
| BENEFICIARY | Trust agreement date, or beneficiary designation form date |
| SPOUSE | Marriage date if in documents, otherwise null |
| PARENT/CHILD | Child's date of birth if known |
| ATTORNEY | Engagement letter date, or date of first document they authored |
| ACCOUNTANT | Earliest tax return they prepared, or engagement start date |
| ADVISOR | Advisory agreement date, or earliest account statement showing them |
| INSURED/OWNERSHIP (Insurance) | Policy effective date |
| OWNERSHIP (Tangible Asset) | Purchase date, deed date, or gift date |

**Always prefer explicit dates** from the document (execution dates, filing dates, effective
dates printed on the document). If no explicit date, use the document's creation/signing date
as a proxy. If truly unknown, leave `effectiveFrom` null rather than guessing.

**How to set effectiveTo:**
- Set ONLY for historical/ended relationships
- Use the date the relationship ended if known (resignation date, amendment date, death date)
- **Leave null for all current/active relationships**

**In the review (Phase 5), clearly mark each relationship:**
```markdown
| Source | Target | Type | Status | effectiveFrom | effectiveTo | Notes |
|--------|--------|------|--------|--------------|-------------|-------|
| Brett | Hercules LLC | OWNERSHIP | CURRENT | 2022-09-15 | | 50%, Managing Member |
| Brett | Andrew Comiter | ATTORNEY | CURRENT | 2023-05-22 | | Estate planning |
| Brett | Old CPA Firm | ACCOUNTANT | HISTORICAL | 2020-01-01 | 2023-12-31 | Replaced by Steirman |
```

**When creating relationships via API:**
```json
{
  "sourceEntityType": "INDIVIDUAL",
  "sourceEntityId": "...",
  "targetEntityType": "CONTACT",
  "targetEntityId": "...",
  "relationshipType": "ATTORNEY",
  "effectiveFrom": "2023-05-22",
  "effectiveTo": null
}
```

For historical relationships, set `effectiveTo` and they will be hidden from current
queries but visible in historical views (`/as-of?asOfDate=...`).

### Step 4.5: Handle unmatched entities

Entities extracted from documents with no Altitude match are candidates for creation.
Group them as:
- **New individuals** to be created via `POST /api/v1/individual`
- **New legal entities** to be created via `POST /api/v1/legal-entity`
- **New accounts** to be created via `POST /api/v1/account-financial`
- **New contacts** to be created via `POST /api/v1/contact`
- **New tangible assets** to be created via `POST /api/v1/tangible-asset`
- **New insurance policies** to be created via `POST /api/v1/insurance-policy`
- **New liabilities** to be created via `POST /api/v1/liability`
- **New relationships** to be created via `POST /api/v1/entity-relationship`

---

## Phase 5: Generate Review Package

Create a clear review for the user. This is mandatory before any API calls. Save intermediate
state to allow resuming if needed.

### Summary Report Structure

```markdown
# Altitude Update Review: {Household Name}

## Household
- Status: [EXISTS / NEW]
- Altitude ID: {id or "will create"}

## Matched Entities (will update)

### Individual: {Name} (Altitude ID: {id})
**Auto-fill fields** (empty in Altitude → will populate):
| Field | Extracted Value | Source Document |
|-------|----------------|-----------------|
| dateOfBirth | 1988-02-19 | The Whole Shebang.docx |
| ssn | 126-74-6445 | Driver's License |

**Conflicting fields** (different values → YOUR DECISION):
| Field | Altitude Value | Extracted Value | Source | Action? |
|-------|---------------|-----------------|--------|---------|
| email | old@email.com | new@email.com | Onboarding Sheet | [keep/update] |

### Legal Entity: {Name} (Altitude ID: {id})
[same structure]

### Account: {Name} (Altitude ID: {id})
[same structure]

### Contact: {Name} (Altitude ID: {id})
[same structure]

### Insurance Policy: {Name} (Altitude ID: {id})
[same structure - auto-fill, conflicting, matching fields]

### Liability: {Name} (Altitude ID: {id})
[same structure - auto-fill, conflicting, matching fields]

## New Entities (will create)

### New Individual: {Name}
[key fields that will be populated]

### New Legal Entity: {Name}
[key fields]

### New Account: {Name}
[key fields]

### New Contact: {Name}
[key fields]

### New Insurance Policy: {Name}
[key fields]

### New Liability: {Name}
[key fields]

## Relationships to Create
| Source | Target | Type | Role | Percentage |
|--------|--------|------|------|-----------|
| Podolsky Family (Household) | Brett Podolsky (Individual) | OWNERSHIP | Primary | 50% |
| Podolsky Family (Household) | Michaela Podolsky (Individual) | OWNERSHIP | | 50% |
| Brett Podolsky (Individual) | Hercules Lender LLC (LegalEntity) | OWNERSHIP | Managing Member | 50% |
| Hercules Lender LLC (LegalEntity) | Andrew Comiter (Contact) | ATTORNEY | Estate Planning | - |
| Hercules Lender LLC (LegalEntity) | Jason Evans (Contact) | ATTORNEY | Corporate | - |

## Document Uploads
| Document | Will Associate With | Entity Type | Entity Name | documentSubType |
|----------|-------------------|-------------|------------|-----------------|
| Drivers License.png | Individual | Individual | Brett Podolsky | DRIVERS_LICENSE |
| Operating Agreement.pdf | Legal Entity | LegalEntity | Hercules Lender LLC | OPERATING_AGREEMENT |
| Bank Statement.pdf | Account | AccountFinancial | Chase Brokerage | ACCOUNT_STATEMENT |
| Life Insurance Policy.pdf | Insurance Policy | InsurancePolicy | NWM Whole Life | POLICY_DECLARATION |
| Mortgage Statement.pdf | Liability | Liability | Chase Mortgage | ACCOUNT_STATEMENT |
```

### Document Upload Plan

The review MUST include a complete document upload plan — every file in the folder mapped to
the entity it will be uploaded to and the `documentSubType` to use:

```markdown
## Document Upload Plan

| # | File | Upload To (Entity Type) | Entity Name | documentSubType | Notes |
|---|------|------------------------|-------------|-----------------|-------|
| 1 | DL - Brett.png | Individual | Brett Podolsky | DRIVERS_LICENSE | |
| 2 | Operating Agreement.pdf | LegalEntity | Hercules LLC | OPERATING_AGREEMENT | |
| 3 | Trust Agreement.pdf | LegalEntity | Brett's Trust | TRUST_AGREEMENT | |
| 4 | Will.pdf | Individual | Brett Podolsky | OTHER | Estate planning - Will |
| 5 | Living Will.pdf | Individual | Brett Podolsky | OTHER | Estate planning - Living Will |
| 6 | Healthcare Surrogate.pdf | Individual | Brett Podolsky | OTHER | Healthcare directive |
| 7 | Durable POA.pdf | Individual | Brett Podolsky | POWER_OF_ATTORNEY | |
| 8 | W-2.pdf | Individual | Brett Podolsky | FORM_W2 | |
| 9 | 1099-INT.pdf | Individual | Brett Podolsky | FORM_1099_INT | |
| 10 | Warranty Deed.pdf | TangibleAsset | 3985 NW 53rd St | DEED | |
| 11 | Insurance Summary.pdf | InsurancePolicy | Chubb Homeowners | POLICY_DECLARATION | |
| 12 | Payoff Statement.pdf | Liability | RCF Loan | PAYOFF_STATEMENT | |
| ... | | | | | |
```

Every file in the folder should appear in this table. If a file doesn't map to any entity
(e.g., a duplicate, a blank page, or an internal note), mark it as SKIP with a reason.

### Open Questions & TODOs

The review MUST include a section listing every piece of information that could not be
resolved from the documents alone and requires human input:

```markdown
## Open Questions — Needs Client/Advisor Input

| # | Question | Why It Matters | Blocking? |
|---|----------|---------------|-----------|
| 1 | Which trust owns the MassMutual life policies? ("Podolsky Family Trust" is ambiguous) | Determines OWNERSHIP relationship for insurance policies | Yes — can't create relationship |
| 2 | Is 401 NE Mizner Blvd PH810 owned or rented? | Determines if we create a TangibleAsset | Yes — missing asset |
| 3 | What is Michaela's business? (Michaela Podolsky Inc) | Sets occupation field | No — can leave blank |
| 4 | CFO name for mlund@quinceandcosf.com? | Contact entity is incomplete | No — has email |
| 5 | Correct address: 3895 or 3985 NW 53rd St? (warranty deed conflict) | Property address | Yes — data integrity |
```

Mark each question as **Blocking** (can't create the entity/relationship without an answer)
or **Non-blocking** (can proceed with partial data and fill later).

### Run State File (for incremental reruns)

Write a persistent state file after every Phase 6/7 action to enable incremental reruns:

**File**: `{household_folder}/altitude_review/run_state.json`

```json
{
  "householdId": "7ee864d1-...",
  "runDate": "2026-03-16T15:30:00",
  "apiUrl": "http://localhost:8080",
  "entities": {
    "household": { "id": "7ee864d1-...", "status": "CREATED" },
    "individuals": [
      { "name": "Brett Adam Podolsky", "id": "77097747-...", "status": "CREATED" },
      { "name": "Michaela Dylan Podolsky", "id": "197ce1e3-...", "status": "CREATED" }
    ],
    "legalEntities": [...],
    "contacts": [...],
    "insurancePolicies": [...],
    "liabilities": [...],
    "tangibleAssets": [...],
    "relationships": [
      { "source": "Podolsky Family", "target": "Brett Podolsky", "type": "OWNERSHIP", "id": "8309344b-...", "status": "CREATED" }
    ]
  },
  "documents": {
    "uploaded": [
      { "file": "Identification/Drivers Licenses.png", "entityId": "77097747-...", "documentId": "abc123-...", "status": "UPLOADED" },
      { "file": "LLC/Hercules/Operating Agreement.pdf", "entityId": "da72184b-...", "documentId": "def456-...", "status": "UPLOADED" }
    ],
    "failed": [
      { "file": "LLC/RCF/4th Amended Note.pdf", "error": "HTTP 500", "status": "FAILED" }
    ],
    "sessionId": "882fea65-..."
  },
  "estatePlanningPatched": ["77097747-...", "197ce1e3-..."],
  "openQuestions": [...]
}
```

**On rerun behavior:**
- Before Phase 1: Check if `run_state.json` exists. If yes, load it and ask the user:
  "Previous run found (dated {runDate}). Options: (A) Resume — skip already-created entities,
  only create missing ones + retry failed uploads. (B) Force rerun — re-extract all documents
  and recreate everything. (C) Upload only — skip entity creation, just upload remaining documents."
- **Resume mode**: For each entity in the state file with status CREATED, skip creation.
  For documents with status UPLOADED, skip upload. For FAILED documents, retry.
- **Force mode**: Delete the state file and start fresh.
- **Upload only**: Skip Phases 1-6, only run Phase 7 using entity IDs from the state file.

Update the state file after EVERY successful API call (not just at the end). This way, if the
run is interrupted mid-way, the next run can resume from where it stopped.

### Save Artifacts

Write these files to `{household_folder}/altitude_review/`:
- `review.md` — complete human-readable review (ALL sections above)
- `file_tracker.md` — every file with READ status and extraction summary
- `altitude_universe.json` — initial state from Phase 1
- `create_payloads.json` — POST requests for new entities
- `patch_payloads.json` — PATCH requests for existing entities (if matching)
- `relationships_to_create.json` — relationship creation plan
- `document_uploads.json` — document upload plan (file → entity → subType)
- `open_questions.json` — **REQUIRED, ALWAYS WRITE THIS FILE** even if empty. Structured JSON
  for programmatic tracking across families. Format:
  ```json
  [
    {"id": 1, "question": "Does client have a Will?", "category": "estate_planning", "blocking": false, "entity": "Phineas Barnes", "resolved": false, "resolution": null},
    {"id": 2, "question": "Joanne DOB: 10/02 vs 10/21?", "category": "data_conflict", "blocking": false, "entity": "Joanne Shih", "resolved": false, "resolution": null}
  ]
  ```
  This file must ALSO be written — embedding questions only in review.md is insufficient.
  Categories: `estate_planning`, `data_conflict`, `missing_data`, `ownership`, `insurance`, `address`, `account`, `other`
- `run_state.json` — persistent state for incremental reruns (entity IDs, document upload status, failures)

Present the review to the user and wait for approval + conflict resolution.

---

## Phase 6: Push Updates to Altitude (Only After Approval)

After the user approves and resolves all conflicts:

### Step 6.1: Update existing entities (PATCH)

Use PATCH for partial updates — only send the fields that need filling or updating:

```
PATCH /api/v1/individual/{id}
Content-Type: application/merge-patch+json
X-API-Key: {api_key}

{
  "dateOfBirth": "1988-02-19",
  "ssn": "126746445",
  "email": "brett@example.com",
  "addressLegal": {
    "addressLine1": "3985 NW 53rd Street",
    "addressLine2": "Suite 200",
    "city": "Boca Raton",
    "state": "FL",
    "postalCode": "33496",
    "country": "US",
    "addressType": "PRIMARY"
  }
}
```

**IMPORTANT**: Only send fields being updated. Never include READ_ONLY computed fields like
`totalMarketValue`, `fullName`, `createdAt`, `updatedAt`, `id`. PATCH ignores null values.

Address structure fields:
- `addressLine1` (required)
- `addressLine2` (optional)
- `city` (required)
- `state` (required, 2-char US state code or province)
- `postalCode` (required, 1-10 chars)
- `country` (required, CountryCode enum like "US", "CA", "GB")
- `addressType` (optional, AddressType enum: "PRIMARY" or "ADDITIONAL")

Process in order: Household → Individuals → Legal Entities → Accounts → Contacts → Tangible Assets (via subtype endpoints) → Insurance Policies → Liabilities. Then create all relationships, then PATCH estate planning.

If an API call fails, log it, save state, and ask user to retry or continue with others.

### Step 6.2: Create new entities (POST)

For entities that don't exist in Altitude yet:

```
POST /api/v1/individual
X-API-Key: {api_key}
Content-Type: application/json

{
  "firstName": "Brett",
  "lastName": "Podolsky",
  "dateOfBirth": "1988-02-19",
  "ssn": "126746445",
  "email": "brett@example.com",
  "addressLegal": { ... }
}
```

For new legal entities (trusts, LLCs, corporations):

```
POST /api/v1/legal-entity
X-API-Key: {api_key}
Content-Type: application/json

{
  "legalName": "Hercules Lender LLC",
  "entityType": "LLC",
  "formationDate": "2015-03-20",
  "jurisdiction": "FL",
  "incorporationState": "FL",
  "incorporationCountry": "UNITED_STATES",
  "taxId": "65-1234567",
  "llcManagementType": "MEMBER_MANAGED"
}
```

For new accounts:

```
POST /api/v1/account-financial
X-API-Key: {api_key}
Content-Type: application/json

{
  "name": "Chase Brokerage Account",
  "accountNumber": "123456789",
  "accountCategory": "INDIVIDUAL",
  "subCategory": "INDIVIDUAL",
  "custodianId": "{custodian_id_from_altitude_universe}"
}
```

For new contacts:

```
POST /api/v1/contact
X-API-Key: {api_key}
Content-Type: application/json

{
  "firstName": "Jane",
  "lastName": "Smith",
  "jobTitle": "Financial Advisor",
  "biography": "Smith & Associates",
  "email": "jane.smith@example.com",
  "phoneNumberPrimary": "555-1234"
}
```

For new insurance policies:

```
POST /api/v1/insurance-policy
X-API-Key: {api_key}
Content-Type: application/json

{
  "name": "Northwestern Mutual Whole Life",
  "policyCategory": "LIFE",
  "policyStatus": "ACTIVE",
  "policyNumber": "POL-2024-789456",
  "carrierName": "Northwestern Mutual",
  "coverageAmount": 2000000.00,
  "annualPremium": 12500.00,
  "effectiveDate": "2020-01-01",
  "firstPaymentDate": "2020-02-01",
  "deathBenefit": 2000000.00,
  "cashValue": 125000.00,
  "lifePolicyType": "WHOLE_LIFE"
}
```

For new liabilities:

```
POST /api/v1/liability
X-API-Key: {api_key}
Content-Type: application/json

{
  "name": "Chase Home Mortgage",
  "liabilityType": "MORTGAGE",
  "liabilityStatus": "CURRENT",
  "lenderName": "JPMorgan Chase",
  "originalBalance": 500000.00,
  "currentBalance": 425000.00,
  "balanceAsOfDate": "2026-03-01",
  "interestRate": 6.5,
  "interestRateType": "FIXED",
  "monthlyPayment": 2750.00,
  "paymentFrequency": "MONTHLY",
  "originationDate": "2022-06-15",
  "maturityDate": "2052-06-15",
  "isSecured": true,
  "isInterestDeductible": true,
  "interestDeductionType": "MORTGAGE_INTEREST"
}
```

For new tangible assets (use SUBTYPE-SPECIFIC endpoints — NOT the base `/tangible-asset`):

```
POST /api/v1/tangible-asset/real-property
X-API-Key: {api_key}
Content-Type: application/json

{
  "name": "3985 NW 53rd St, Boca Raton, FL 33496",
  "category": "REAL_PROPERTY",
  "assetType": "PRIMARY_RESIDENCE",
  "description": "6833 sq ft, concrete block, built 1996",
  "serialOrIdentifier": "06-42-47-04-02-000-0390",
  "location": "Palm Beach County, FL",
  "currentValue": 5674000,
  "isInsured": true,
  "insuredValue": 5674000
}
```

```
POST /api/v1/tangible-asset/vehicle
{
  "name": "2024 Porsche 911",
  "category": "VEHICLE",
  "assetType": "CAR",
  "serialOrIdentifier": "WP0CD2A94RS257187",
  "currentValue": 317480,
  "isInsured": true
}
```

```
POST /api/v1/tangible-asset/luxury
{
  "name": "AP Royal Oak Offshore",
  "category": "LUXURY",
  "assetType": "WATCH",
  "serialOrIdentifier": "LH0496U",
  "currentValue": 31928,
  "isInsured": true,
  "insuredValue": 31928
}
```

Available subtype endpoints: `/real-property`, `/vehicle`, `/luxury`, `/collectible`, `/other`.
After creation, add OWNERSHIP relationships (IND→TA with percentage).

**Scheduled items from insurance policies**: If an insurance summary or collections policy
schedules individual items (watches, jewelry, art, wine) with values, create EACH item as a
separate TangibleAsset via the `/luxury` or `/collectible` endpoint. Include:
- `name` — item description (e.g., "AP Royal Oak Offshore")
- `serialOrIdentifier` — serial number if listed
- `currentValue` — scheduled/appraised value
- `isInsured: true`, `insuredValue` — same as scheduled value
These are real assets with real values and should NOT be deferred or marked as optional.

### Step 6.2.1: Cross-Entity Linking (AFTER all tangible assets, insurance policies, and liabilities are created)

After creating tangible assets, insurance policies, and liabilities, apply cross-entity links:

**Insurance → Tangible Asset:** For each insurance policy that covers a tangible asset, PATCH the
tangible asset with insurance details:
```
PATCH /api/v1/tangible-asset/{assetId}
{
  "name": "<existing name — include to avoid validation error with custom 'is required' messages>",
  "isInsured": true,
  "primaryInsurancePolicyNumber": "<policy number>",
  "insuredValue": <coverage amount>,
  "insuranceExpirationDate": "<expiration date>"
}
```
Common mappings:
- Homeowners policy → primary residence
- Auto policy → each vehicle listed on the policy
- Flood policy → primary residence
- Collections/valuable articles → each scheduled item
- Boat/yacht policy → boat tangible asset

**TangibleAssetInsurance child entries:** In addition to the summary PATCH above, create
detailed insurance child records for each asset-policy linkage. This populates the
"Insurance Policies" tab on the asset detail view:
```
POST /api/v1/tangible-asset/{assetId}/insurance
{
  "policyNumber": "<policy number>",
  "carrier": "<carrier name>",
  "insuranceType": "<HOMEOWNERS|FLOOD|AUTO|JEWELRY|COLLECTIBLES|FINE_ART|MARINE|AVIATION|UMBRELLA|VALUABLE_ARTICLES>",
  "coverageAmount": <coverage amount — REQUIRED, NOT NULL>,
  "annualPremium": <annual premium if known>,
  "effectiveDate": "<YYYY-MM-DD — REQUIRED, NOT NULL>",
  "expirationDate": "<YYYY-MM-DD — REQUIRED, NOT NULL>",
  "isActive": true,
  "isAgreedValue": <true for agreed-value policies (vehicles, jewelry)>,
  "coverageNotes": "<description of coverage>"
}
```
**CRITICAL**: `effectiveDate`, `expirationDate`, and `coverageAmount` are NOT NULL in the
database — omitting them returns HTTP 409 (data integrity error), not 400. Always include
all three fields. Use policy dates from the insurance summary/declaration documents.

Create ONE entry per asset-policy combination:
- Primary residence gets 3 entries: HOMEOWNERS + FLOOD + wind (HOMEOWNERS type with notes)
- Each vehicle gets 1 entry: AUTO with agreed value as coverageAmount
- Each jewelry/watch gets 1 entry: JEWELRY with scheduled value as coverageAmount
- Golf cart gets 1 entry: AUTO

**Liability → Tangible Asset:** For each secured liability, PATCH the liability with the
tangible asset link:
```
PATCH /api/v1/liability/{liabilityId}
{
  "linkedTangibleAssetId": "<tangible asset UUID>",
  "isSecured": true,
  "collateralDescription": "<asset name or address>"
}
```
Common mappings:
- Mortgage → property tangible asset
- Auto loan → vehicle tangible asset
- Boat loan → boat tangible asset
- Art-secured loan → art/collectible tangible asset

**Order matters:** Create tangible assets BEFORE liabilities and insurance policies, so you
have the UUIDs available for linking.

**Auto policy vehicles:** When an auto insurance policy lists specific vehicles (make/model/year),
create a TangibleAsset (VEHICLE) for EACH vehicle via `/api/v1/tangible-asset/vehicle`. Then
PATCH each vehicle with `isInsured: true` and the auto policy number. Then create OWNERSHIP
relationships from the vehicle owner to each vehicle.

For estate planning (nested on Individual PATCH — NOT a standalone entity):

```
PATCH /api/v1/individual/{id}
X-API-Key: {api_key}
Content-Type: application/merge-patch+json

{
  "estatePlanning": {
    "will": {
      "hasWill": true,
      "willDate": "2024-01-15",
      "executorName": "Jane Smith",
      "jurisdiction": "New York"
    },
    "healthcare": {
      "hasHealthcareDirective": true,
      "agentName": "Jane Smith"
    },
    "financialPoa": {
      "hasFinancialPoa": true,
      "type": "DURABLE",
      "agentName": "Jane Smith"
    }
  }
}
```

Record the returned IDs for relationship creation.

**Insurance policy relationships** (create after policy is created):
- OWNERSHIP: Individual/LegalEntity → InsurancePolicy (who owns/pays for the policy)
- INSURED: Individual → InsurancePolicy (who is covered by the policy)
- BENEFICIARY: Individual → InsurancePolicy (who receives the payout)

### Step 6.3: Create relationships

```
POST /api/v1/entity-relationship
X-API-Key: {api_key}
Content-Type: application/json

{
  "relationshipType": "OWNERSHIP",
  "sourceEntityId": "{household_id}",
  "sourceEntityType": "HOUSEHOLD",
  "targetEntityId": "{individual_id}",
  "targetEntityType": "INDIVIDUAL",
  "isPrimary": true,
  "percentage": 50
}
```

**CRITICAL**: Household-to-Individual relationships use **OWNERSHIP from HOUSEHOLD → INDIVIDUAL**
(the household "owns" its members). Do NOT use MEMBER (IND→HH) — that is for LLC membership only.
Direction matters: the household is the SOURCE, the individual is the TARGET.

**Use generational roles, not "adult/child" assumptions.** Family members should be categorized
by generation (G1 = oldest generation, G2 = their children, G3 = grandchildren), not by age.
An adult child (age 25) is still G2. A minor grandchild is G3.

- **ALL members get percentage = 100**.** The household "owns" 100% of each member. This is
  what drives the valuation rollup — each member's account values roll up fully to the
  household. Do NOT use 50/50 for couples or 0 for children.
- **isPrimary**: Set to true for the first G1 member only.
- Use generational roles (G1/G2/G3) in the `role` field for display purposes only.

Examples:
```
# Couple with 3 minor children
HOUSEHOLD → Spouse1 (OWNERSHIP, isPrimary: true, percentage: 100, role: "G1")
HOUSEHOLD → Spouse2 (OWNERSHIP, percentage: 100, role: "G1")
HOUSEHOLD → Child1 (OWNERSHIP, percentage: 100, role: "G2")
HOUSEHOLD → Child2 (OWNERSHIP, percentage: 100, role: "G2")
HOUSEHOLD → Child3 (OWNERSHIP, percentage: 100, role: "G2")

# Single parent with adult children
HOUSEHOLD → Parent (OWNERSHIP, isPrimary: true, percentage: 100, role: "G1")
HOUSEHOLD → AdultChild1 (OWNERSHIP, percentage: 100, role: "G2")
HOUSEHOLD → AdultChild2 (OWNERSHIP, percentage: 100, role: "G2")

# Multi-generational
HOUSEHOLD → Grandparent1 (OWNERSHIP, isPrimary: true, percentage: 100, role: "G1")
HOUSEHOLD → Grandparent2 (OWNERSHIP, percentage: 100, role: "G1")
HOUSEHOLD → AdultChild (OWNERSHIP, percentage: 100, role: "G2")
HOUSEHOLD → Grandchild1 (OWNERSHIP, percentage: 100, role: "G3")
HOUSEHOLD → Grandchild2 (OWNERSHIP, percentage: 100, role: "G3")
```

Validate each relationship against the matrix in Phase 4.5 before posting. If validation fails,
flag for user review.

---

## Phase 7: Upload Documents

After entities are created/updated, upload source documents and associate them with
the correct entity.

### Document Association Rules

Read `references/document_entity_association.md` for the complete mapping. Key rules:

**Associate with Individual:**
- Driver's licenses, passports → `documentSubType: DRIVERS_LICENSE / PASSPORT`
- Personal ID docs → `PERSONAL_ID`
- W-2s → `FORM_W2`
- Personal tax returns → `FORM_1040`
- Power of Attorney → `POWER_OF_ATTORNEY`
- Will / Testament → `WILL`
- Healthcare directives → `HEALTHCARE_DIRECTIVE`

**Associate with Legal Entity:**
- Articles of Organization → `ARTICLES_OF_ORGANIZATION`
- Operating Agreement → `OPERATING_AGREEMENT`
- Articles of Incorporation → `ARTICLES_OF_INCORPORATION`
- Trust Agreement → `TRUST_AGREEMENT`
- EIN Letter → `EIN_CONFIRMATION`
- State filings (Sunbiz) → `BUSINESS_REGISTRATION`
- K-1s → `FORM_K1_1065` or `FORM_K1_1120S`
- Entity tax returns → `FORM_1065 / FORM_1120 / FORM_1120S / FORM_1041`

**Associate with Account (AccountFinancial):**
- Bank statements → `ACCOUNT_STATEMENT`
- Brokerage statements → `ACCOUNT_STATEMENT`
- Account confirmations → `ACCOUNT_CONFIRMATION`
- IRA/401k statements → `RETIREMENT_ACCOUNT_STATEMENT`

**Associate with Tangible Asset:**
- Property deeds → `DEED`
- Property titles → `TITLE`
- Insurance policies → `INSURANCE_POLICY`
- Appraisals → `APPRAISAL`
- Property tax bills → `PROPERTY_TAX`

### Upload format (multipart/form-data)

```
POST /api/v1/individual/{individualId}/document?sessionId={uuid}&skipDuplicates=true
X-API-Key: {api_key}
Content-Type: multipart/form-data

Parts:
- createRequest (application/json, required):
  {
    "title": "Brett Podolsky - Driver's License",
    "description": "Florida driver's license, expires 2029",
    "documentSubType": "DRIVERS_LICENSE",
    "contentType": "PNG"
  }

- file (binary, required):
  [actual file bytes]
```

Entity-specific upload endpoints:
- `POST /api/v1/individual/{individualId}/document`
- `POST /api/v1/legal-entity/{legalEntityId}/document`
- `POST /api/v1/account-financial/{accountId}/document`
- `POST /api/v1/tangible-asset/{assetId}/document`
- `POST /api/v1/insurance-policy/{policyId}/document`
- `POST /api/v1/liability/{liabilityId}/document`

**Note**: Household does NOT support document upload. Associate household-level documents with
the primary individual or legal entity instead.

Use the same `sessionId` (UUID) for all uploads in a batch so they are grouped together.
Set `skipDuplicates=true` to prevent re-uploading the same file.

For large households with 50+ documents, process in batches of 10-15 uploads at a time
to avoid timeouts.

### Create Entity Associations (REQUIRED after each upload)

The upload endpoint sets the type-specific FK (`individualId`, `legalEntityId`, etc.) but does
**NOT** auto-create entity associations. The UI uses the `entityAssociations` array to display
document-entity links. Without this step, documents will appear unlinked in the UI.

After each successful document upload, immediately call:

```
POST /api/v1/document/{documentId}/associations?entityType={TYPE}&entityId={ID}&associationType=OWNER&entityDisplayName={NAME}
X-API-Key: {api_key}
```

**Parameters:**
- `documentId` — the `id` returned from the upload response
- `entityType` — matches the entity: `INDIVIDUAL`, `LEGAL_ENTITY`, `ACCOUNT`, `INSURANCE_POLICY`, `TANGIBLE_ASSET`, `LIABILITY`
- `entityId` — UUID of the parent entity
- `associationType` — `OWNER` (the entity that owns this document)
- `entityDisplayName` — human-readable name (e.g., "Brett Podolsky", "Hercules Lender LLC")

**Example:**
```bash
# Upload returns {"id": "abc123", ...}
# Then create the association:
curl -X POST "${BASE}/document/abc123/associations?entityType=INDIVIDUAL&entityId=${BRETT_ID}&associationType=OWNER&entityDisplayName=Brett%20Podolsky" \
  -H "X-API-Key: ${API_KEY}" -H "X-Firm-Id: ${FIRM_ID}"
```

This is idempotent — calling it twice for the same document+entity+type returns the existing
association. Do this for EVERY uploaded document, not just cross-entity ones.

For documents that relate to multiple entities (e.g., a trust agreement that names trustees
and beneficiaries), create additional associations with `associationType=SUBJECT`:
```
POST /api/v1/document/{trustAgreementDocId}/associations?entityType=INDIVIDUAL&entityId={trusteeId}&associationType=SUBJECT&entityDisplayName={trusteeName}
```

---

## Important Rules

1. **NEVER create entities without checking Altitude first.** Always query the household
   universe before extraction.

2. **NEVER push without user approval.** Always generate the review package first.

3. **Auto-fill is safe.** If a field is empty/null in Altitude and you have a value from
   documents, queue it for automatic update.

4. **Conflicts require human decision.** If a field has different values in Altitude vs
   documents, present both values and ask.

5. **PATCH, don't PUT.** Use PATCH for updates so you only touch the fields being changed.

6. **Validate relationship source/target types before creating.** Not all entity type
   combinations are allowed. Consult the matrix in Phase 4.5. The API will reject
   invalid combinations with a 400 error.

7. **Never include READ_ONLY fields in PATCH payloads.** Computed fields like
   `totalMarketValue`, `fullName`, `createdAt`, `updatedAt`, `id` will cause validation
   errors. Only send fields that are actually writable.

8. **Track provenance.** Every field should trace back to a source document.

9. **Handle sensitive data carefully.** SSNs, EINs, tax IDs should only appear in
   structured payloads, not logs or markdown.

10. **Use API key authentication when possible.** It's simpler than JWT and doesn't
    require token refresh.

11. **Save checkpoints after each phase.** Write intermediate results to disk
    (`altitude_review/` folder) after Phase 1 (universe), Phase 4 (matches), and
    Phase 5 (review). This allows resuming if context resets.

12. **Process one household at a time** unless batch processing is explicitly requested.
    If processing multiple households in the same session, be extremely careful not to
    cross-contaminate data between families. Every field must trace to a source document
    in THAT household's folder. Never apply data from one family's documents to another.

13. **Handle large households gracefully.** For households with 50+ documents or 20+ entities,
    use parallel processing for document extraction (Phase 3), then merge sequentially
    (Phase 4). Process uploads in batches to avoid timeouts.

14. **Read EVERY file.** The most common extraction failure is not reading a document at all.
    No file should be skipped. If a file can't be read (password-protected, corrupt, binary),
    flag it for the user — don't silently skip it.

15. **Every named person is an entity.** Estate planning documents name guardians, executors,
    successor trustees, beneficiaries, agents. LLC docs name attorneys. Tax returns name
    preparers. 1099s name advisors. Insurance summaries name agents. If a person has a name
    in a document, they become either an Individual or a Contact in Altitude.

16. **Each spouse gets their own trust.** When estate planning docs say "your respective Trusts"
    or "each of you are the Grantor and initial Trustee of your own Trust," that is TWO separate
    LegalEntity (TRUST) records — not one shared trust. This is the most common entity miss.

17. **1099s are account discovery tools.** Every 1099 cover page has an account number and a
    custodian name. Many 1099s also name the investment advisor/RIA. These are often the ONLY
    place where an account number appears. Never dismiss a 1099 as "just tax data."

18. **Emails and cover letters contain contacts.** An email forwarding LLC documents often has
    the attorney's full name, firm, phone, and email in the signature block. A tax return cover
    letter has the CPA firm's contact info. These are Tier 1 data for Contact entity creation.

19. **Sensitive data handling.** If the onboarding sheet or any document contains plaintext
    passwords, credit card numbers, or bank login credentials: (a) Do NOT store these in any
    Altitude field, (b) Flag to the user that credentials were found in plain text and recommend
    the client change all affected passwords immediately.

20. **TangibleAsset uses subtype-specific POST endpoints.** You CANNOT POST to `/api/v1/tangible-asset`
    directly — it returns 500 (abstract entity). Use the subtype endpoints:
    - `/api/v1/tangible-asset/vehicle` — for cars, boats, aircraft
    - `/api/v1/tangible-asset/real-property` — for homes, condos, land
    - `/api/v1/tangible-asset/luxury` — for watches, jewelry, handbags
    - `/api/v1/tangible-asset/collectible` — for art, wine, antiques
    - `/api/v1/tangible-asset/other` — for everything else

21. **Do NOT delete and recreate entity relationships.** Soft-deleted relationships still enforce
    uniqueness constraints. If you delete a relationship and try to recreate it with the same
    source+target+type, you will get a 409 Conflict. Either avoid deleting relationships, or
    use the hard-delete endpoint (`DELETE /{id}/hard`) for error correction.

22. **Identity documents use `OTHER` subtype.** `DRIVERS_LICENSE` and `PASSPORT` subtypes are
    for IdentificationDocument entities, NOT IndividualDocument. When uploading DLs or passports
    via `/api/v1/individual/{id}/document`, use `documentSubType: "OTHER"` with a descriptive
    title like "Brett Podolsky - Florida Driver's License".

21. **Cache JWT tokens.** Get ONE token at the start of Phase 6 and reuse it for all API calls.
    Do NOT authenticate before every request — the server has a rate limiter (~20 login attempts
    per 15 minutes per IP). If you hit rate limiting, restart the server to clear the in-memory
    cache, then get a single token and reuse it.

22. **Household → Individual uses OWNERSHIP at 100%, not MEMBER.** The relationship from a
    household to its individual members uses `relationshipType: "OWNERSHIP"` with the household
    as SOURCE and the individual as TARGET. **ALL members get percentage = 100** — the household
    owns 100% of each person, which drives valuation rollup. Do NOT use 50/50 for couples or
    0 for children. Do NOT use MEMBER (IND→HH) — that is for LLC membership only. Use
    generational roles (G1/G2/G3) in the `role` field for display, `isPrimary: true` on the
    first G1 member only.

23. **Create ALL insurance policies — no deprioritization.** Every policy in the insurance
    summary must be created, regardless of size. A $462/yr golf cart policy and a $605/yr
    cyber policy are just as important as a $10M umbrella. The skill extracts them — create them.

24. **Create ALL tangible assets from insurance schedules.** Jewelry, watches, and collectibles
    itemized on a Chubb Collections or similar schedule are individual TangibleAssets. Create
    each one via `/luxury` or `/collectible` with its scheduled value and serial number.

25. **JPEG and JPG are both valid.** When uploading images, use `contentType: "JPG"` for both
    `.jpg` and `.jpeg` files. For filenames with special characters (parentheses, commas,
    apostrophes), escape them in curl commands or use `--data-binary` with proper quoting.

26. **Investment accounts without statements.** If the onboarding sheet mentions investments
    (Loci Capital $750K, Stonetown $250K, etc.) but no account statements exist in the folder,
    still flag these in the Open Questions section. Do NOT create AccountFinancial entities
    without at minimum an account number or custodian — but DO list them as "accounts to be
    created once client provides statements."

27. **Professional relationships flow OUTWARD from the client entity.** For ADVISOR, ATTORNEY,
    ACCOUNTANT, and INSURANCE_AGENT: the client entity (Household, Individual, or LegalEntity) is
    the SOURCE, and the Contact is the TARGET. Example: `Hercules LLC → Jason Evans (ATTORNEY)`,
    NOT `Jason Evans → Hercules LLC`. The API accepts both directions, but outgoing from the
    entity is the correct data model pattern used by the demo data and the UI.

28. **Always cross-link insurance policies to tangible assets.** After creating both the
    insurance policy and the tangible asset: (a) PATCH the tangible asset with `isInsured: true`,
    `primaryInsurancePolicyNumber`, `insuredValue`, and `insuranceExpirationDate` for the summary
    fields displayed on asset cards. (b) POST to `/api/v1/tangible-asset/{id}/insurance` to create
    `TangibleAssetInsurance` child entries for the detailed "Insurance Policies" tab. Both steps
    are required — the PATCH sets summary fields, the POST populates the detail collection.
    **CRITICAL**: The POST requires `effectiveDate`, `expirationDate`, and `coverageAmount`
    (all NOT NULL in the database) — omitting them returns 409, not 400.

29. **Always cross-link liabilities to tangible assets.** After creating both the liability and
    the tangible asset it's secured by, PATCH the liability with `linkedTangibleAssetId` set to
    the tangible asset UUID. This enables the unified liability rollup to correctly attribute
    asset-secured debt and display it on the tangible asset detail view. Mortgages link to
    properties, auto loans link to vehicles, boat loans link to boats.

30. **Create vehicles from auto insurance schedules.** Auto insurance policies list specific
    vehicles (make, model, year, VIN). Each vehicle MUST be created as a TangibleAsset via
    `/api/v1/tangible-asset/vehicle` even if no separate vehicle document exists in the folder.
    The insurance schedule IS the source document. After creation, PATCH each vehicle with
    `isInsured: true` and the auto policy number, and create OWNERSHIP relationships.

31. **Entity creation order matters for cross-linking.** Always create entities in this order:
    Household → Individuals → Legal Entities → Accounts → **Tangible Assets** → **Insurance
    Policies** → **Liabilities** → Relationships → Estate Planning → Cross-Links (insurance↔asset,
    liability↔asset). Tangible assets must exist before liabilities and insurance can link to them.

32. **ALWAYS create entity associations after uploading documents.** The upload endpoint sets
    the type-specific FK (`individualId`, `legalEntityId`, etc.) but does NOT create an entity
    association. The UI uses `entityAssociations` to display document-entity links — without
    this step, documents appear unlinked in the UI. After every successful upload, call
    `POST /api/v1/document/{docId}/associations?entityType={TYPE}&entityId={ID}&associationType=OWNER&entityDisplayName={NAME}`.
    This is idempotent and REQUIRED for every document. See Phase 7 for full details.

33. **ALWAYS populate LLC detail fields.** For every LLC/LP/partnership legal entity, extract and
    PATCH these fields — they are commonly missed:
    - `registrationNumber` — state filing document number (from Articles of Organization or Sunbiz)
    - `taxClassification` — `PARTNERSHIP` for multi-member LLCs, `DISREGARDED_ENTITY` for single-member
    - `llcOperatingAgreementDate` — execution date of the operating agreement
    - `addressPrincipal` — principal place of business (usually the primary residence address)
    These fields appear in the Articles of Organization, Sunbiz filings, and Operating Agreements.

34. **ALWAYS set gender on ALL individuals.** Gender for children is often omitted because it's
    not on IDs or tax returns. Infer from first names if not explicitly stated. Do NOT leave
    gender null — it's a core demographic field.

35. **ALWAYS create successor trustee relationships.** Trust agreements name successor trustees
    (typically spouse as 1st, then parents/in-laws as 2nd/3rd). Create `SUCCESSOR_TRUSTEE`
    relationships with `priority` (1, 2, 3) and `role` ("1st Successor Trustee", etc.).
    This is a separate relationship type from `TRUSTEE` — both should exist.

36. **ALWAYS create beneficiary relationships for children to trusts.** When trust documents name
    children as primary beneficiaries, create `BENEFICIARY` relationships from each child to each
    trust with `role: "Primary Beneficiary"`. Don't assume the grantor/trustee relationships cover
    beneficiary status.

37. **Create family member contacts.** Extended family members named as guardians, successor
    trustees, POA agents, or beneficiaries in estate planning docs should be created as `Contact`
    entities (not full Individuals unless they become clients). Include phone, address, and a
    `biography` noting their relationship ("Brett's father. Named as successor trustee and
    guardian."). Create `ADVISOR` relationship from Household → Contact with role "Family Member".

38. **WINDSTORM is a valid InsurancePolicyCategory.** Use `WINDSTORM` (not `OTHER` or `HOMEOWNERS`)
    for wind/hurricane policies that are separate from base homeowners coverage. This is common
    in Florida and coastal areas where wind is carved out of the homeowners policy.

39. **Files with special characters in filenames break curl.** Filenames containing commas,
    parentheses with periods (e.g., `(Podolsky, B.).pdf`), or dollar signs cause curl error 26.
    Copy these files to `/tmp` with clean names before uploading, then delete the temp copies
    after upload completes.

---

## Running the Skill

When the user invokes this skill:

1. **Collect prerequisites**: API URL (production or development), authentication (API key or JWT),
   firmId (ask if not known)

2. **Identify the target household** folder (or process all if requested)

3. **Run Phase 1 + Phase 2 in parallel**: Launch two concurrent tasks:
   - **Task A**: Query Altitude for existing data → save `altitude_universe.json`
   - **Task B**: Scan and classify all files in the folder → save `file_tracker.md`
   These are independent — Altitude queries don't depend on file scanning.

4. **Run Phase 3 — Parallel Extraction**: After Phase 2 completes, group files into batches
   (by subdirectory, max ~12 files per batch). Spawn one extraction Agent per batch, all in
   a **single message** so they run concurrently. Each agent:
   - Reads every file in its batch
   - Extracts entities, relationships, contacts using document-type checklists
   - Writes results to `altitude_review/extraction_cache_batch_{N}.jsonl`
   - Writes tracker to `altitude_review/file_tracker_batch_{N}.md`

5. **Run Phase 3M — Merge**: After ALL extraction agents complete:
   - Concatenate all `extraction_cache_batch_*.jsonl` into `extraction_cache.jsonl`
   - Merge all `file_tracker_batch_*.md` into `file_tracker.md`
   - Verify 100% file coverage (every file marked READ)

6. **Run Phases 3.5 → 4**: Read the merged `extraction_cache.jsonl`. Run cross-document
   validation, self-audit, then match and merge against Altitude Universe.

7. **Run Phase 5**: Generate review package and present to user. Save payloads and
   conflicts to `altitude_review/` folder.

8. **Wait for approval** and conflict resolution

9. **Run Phases 6-7**: Push updates (PATCH), create new entities (POST), create relationships,
   upload documents. Track progress and report any failures.

### Extraction Agent Prompt Template

When spawning each extraction agent, use this prompt structure:

```
You are a document extraction agent for the {household_name} household onboarding.

Your task: Read EVERY file in your assigned batch and extract ALL entity data.

## Your Files (Batch {N})
{numbered list of absolute file paths}

## Output
Write extracted data to: {folder}/altitude_review/extraction_cache_batch_{N}.jsonl
Write file tracker to: {folder}/altitude_review/file_tracker_batch_{N}.md

## How to Read Files
- PDFs: Use Read tool. For 20+ page PDFs, use page index scan first (pypdf), then
  targeted deep read of data-rich pages.
- Word docs: `textutil -convert txt file.docx`, then Read the .txt
- Images: Read tool (Claude has vision)
- Emails: Parse with Python email module

## What to Extract (per file)
For EACH file, append one JSONL line to your cache with:
- file: relative path
- entities.individuals: [{name, dob, ssn, gender, address, email, phone, occupation, employer}]
- entities.legalEntities: [{name, type, ein, formationDate, jurisdiction, state, managementType}]
- entities.accounts: [{name, accountNumber, custodian, accountCategory, subCategory}]
- entities.tangibleAssets: [{name, category, assetType, address, value, serialOrIdentifier}]
- entities.insurancePolicies: [{name, policyCategory, policyNumber, carrier, coverage, premium}]
- entities.liabilities: [{name, type, lender, accountNumber, balance, rate, monthlyPayment}]
- relationships: [{source, target, type, percentage, role}]
- contacts: [{name, jobTitle, firm, email, phone, role}]
- estatePlanning: [{individual, field, value}]
- notes: free text with anything notable

## Document Type Checklists
{Read references/document_type_patterns.md and include the relevant checklists}

## Rules
- Read EVERY file. No skipping.
- Extract ALL named people — they become Individuals or Contacts.
- Track every field's source document.
- For large PDFs (tax returns), use the two-pass strategy:
  Pass 1: pypdf page index scan. Pass 2: Read only data-rich pages.
- Password-protected PDFs: check filename for password, decrypt with qpdf.
- Update file_tracker_batch_{N}.md after each file (status: READ, summary of what was found).
```

---

## Reference Files

- `references/altitude_api_schema.md` — Complete Altitude API field mappings and endpoints
- `references/altitude_api_endpoints.md` — Detailed search, PATCH, document upload, and relationship endpoints
- `references/document_type_patterns.md` — How to classify documents by filename and content
- `references/document_entity_association.md` — Which documents associate with which entity type + documentSubType values
- `references/match_merge_rules.md` — Detailed entity matching and field merge logic
