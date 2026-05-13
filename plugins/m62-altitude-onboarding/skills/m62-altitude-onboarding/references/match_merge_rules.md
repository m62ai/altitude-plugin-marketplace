# Entity Matching and Field Merge Rules

## Entity Tier Classification — Individual vs Contact-only

Before matching or creating any person extracted from a document, classify them
into one of three tiers. The tier determines which record type(s) to create and
how to wire them to the household. **This is the routing decision; matching
(below) happens within whatever tier the person ends up in.**

### Tier 1 — Economic principal → Individual + HH-OWNERSHIP (`economicOwnership: true`)

The person holds, or is a future principal of, economic value that rolls up to
the household. Examples:

- Grantor of the household's primary revocable trust
- Spouse / domestic partner of the principal (joint or community-property states)
- Dependent children of the principal
- Anyone whose own account ownership, LE membership, TA ownership, or insurance
  policy ownership shows up in the source documents

**Wire**: `HH → Individual OWNERSHIP @100% economicOwnership=true` per SKILL.md
"Always wire estate-plan / fiduciary-role parties to the household" rule.

### Tier 2 — Fiduciary or named non-principal → Individual + HH-OWNERSHIP (`economicOwnership: false`) + Contact

The person is named in a trust, will, AHCD, beneficiary form, POA, or guardian
nomination in a fiduciary or specific-gift capacity, but is not an economic
principal of the household. They need an Individual record to **carry their
outbound role edges** (HEALTHCARE_AGENT, BENEFICIARY, GUARDIAN, EXECUTOR,
TRUSTEE, etc.) — the edges need a real Individual target.

Tier-2 examples seen in production:
- Hannah's brother Toby Broke-Smith — healthcare agent + contingent remainder
  beneficiary on Hannah's Living Trust
- Jennifer Connolly — alternate healthcare agent (family friend, not blood
  relation)
- Marney Jurey — guardian-of-person nomination committee member for Celeste

**Wire**:
1. `HH → Individual OWNERSHIP @100% economicOwnership=false` (visibility-only,
   doesn't count toward 100%-sum validator)
2. The role-specific outbound edge from this Individual
   (e.g. `Toby → Hannah HEALTHCARE_AGENT isPrimary=true`)
3. ALSO create a Contact record with the relationship label
   (e.g. firstName="Toby" lastName="Broke-Smith" jobTitle="Brother (Hannah's)")
   for human-readable family-tree display

### Tier 3 — Relation mentioned for context only → Contact only

The person is named in a document only to identify a family relationship
("Hannah's mother Johanna") without any role, ownership, or beneficial interest.
They don't need an Individual record — no edges will originate from them and no
edges target them. A Contact with a descriptive `jobTitle` is the complete
representation.

Tier-3 examples:
- Hannah's parents (Anthony + Johanna Broke-Smith) — mentioned as family of
  origin in the trust narrative, but neither is named as trustee, beneficiary,
  agent, or otherwise
- A grandparent or in-law mentioned in passing in an estate plan summary
- Children of a side branch mentioned in a family-tree narrative who have no
  beneficial or fiduciary tie

**Wire**: Contact only, with `jobTitle` capturing the relationship
(e.g. "Mother (Hannah's)", "Father-in-law (Kevin's)"). No Individual record. No
HH edge.

### Empty-Individual detection (Bret pattern, 2026-05-13)

After Tier 2 evaluation, if a person would get an Individual record but:
- has NO DOB / SSN / address / demographic data, AND
- carries ZERO outbound role edges after the document is fully processed
  (i.e. their fiduciary role turned out to be ambiguous or unsupported by the
  rest of the document's content)

then **downgrade to Tier 3** — skip Individual creation, create Contact only.
The empty Individual record adds no value (no economic data, no fiduciary
edges to host) and only inflates HH member counts.

Verita 2026-05-13 case: Bret Comolli was extracted from an Estate Plan Chart
with rationale "Kevin's brother — member of guardian nomination committee."
But the guardian committee edges are blocked by backend constraints (see
SKILL.md "Edge-cardinality reminders"), so Bret's Individual ended up with
zero outbound edges, just an inflating HH-membership claim. Correct
representation: Contact alone with `jobTitle: "Brother (Kevin's)"`.

### Decision flowchart

```
Person extracted from a document
├─ Has own account/LE/TA/policy ownership in any doc? ─── YES → Tier 1
└─ NO
   ├─ Named with a fiduciary/beneficiary/POA role? ─── YES
   │   ├─ Will the role-specific edge actually be created
   │   │   (i.e. not blocked by cardinality / type restrictions)?
   │   │   ├─ YES → Tier 2 (Individual + visibility HH edge + Contact)
   │   │   └─ NO  → Tier 3 (Contact only — empty-Individual rule)
   │   └─
   └─ Only named as a family relation, no role? ─── YES → Tier 3
```

### Why this matters (audit history)

The Comolli 2026-05-13 cleanup removed 4 phantom Individuals + 1 dangling edge
that arose from inconsistent application of these tiers:
- Marney, Jennifer, Toby — got Tier 2 treatment but with `economicOwnership=true`
  (wrong; should have been `false`). Resulted in falsely claiming HH membership.
- Bret — should have been Tier 3 (no outbound edges), got Tier 2 anyway.
- Plus 1 deleted-target dangling HH→Individual edge (separate backend bug,
  see Linear PLT-97).

Anthony Broke-Smith was the model of correct Tier-3 handling: Hannah's father,
no fiduciary role, Contact-only. (Created retroactively in this same cleanup
to match wife Johanna's existing Contact-only representation.)

## Entity Matching

### Matching Priority (ALL entity types)

**External provider IDs take precedence over every other signal.** When an Altitude entity
has `externalIds: [{provider, externalId}]` set (common when a firm imported a hierarchy
spreadsheet from Addepar/Orion/Schwab before onboarding), a matching external ID in the
extracted data is a **definitive match** regardless of name/DOB/EIN. Do NOT create a
duplicate entity. Do NOT overwrite the external ID — it is a stable cross-system key. See
SKILL.md Rule 42 on externally-synced accounts being READ-ONLY.

### Individual Matching

Match extracted individuals against existing Altitude records.

**Matching hierarchy (try in order, stop at first definitive match):**

0. **External ID Match** (definitive)
   - If the extracted data has any `externalIds[{provider, externalId}]` entry matching an
     Altitude individual's entry → confirmed same person; proceed to field merge.

1. **SSN Match** (definitive)
   - Normalize both SSNs to 9 digits (strip dashes, spaces)
   - If SSNs match exactly → confirmed same person
   - If both have SSNs but they differ → confirmed different people (stop)
   - **Cross-check**: before trusting an extracted SSN, confirm the value doesn't equal the
     EIN of any LegalEntity in the same folder. Grantor trusts often use the grantor's SSN
     as the EIN, so a carelessly filled worksheet can place the EIN in the SSN field. If
     the "SSN" matches a known EIN elsewhere, flag as probable conflation and leave SSN
     blank pending user confirmation.

2. **Name + DOB Match** (strong)
   - Normalize names: lowercase, strip titles (Mr/Mrs/Dr), strip suffixes (Jr/Sr/III)
   - Compare firstName + lastName (exact match, case-insensitive)
   - If names match AND DOB matches → confirmed same person
   - If names match but no DOB available → probable match (note for confirmation)

3. **Fuzzy Name + DOB Match** (strong)
   - Calculate name similarity (SequenceMatcher ratio)
   - If similarity ≥ 0.85 AND DOB matches → probable same person
   - Common variations to account for: Katherine/Kat/Kate, Michael/Mike, Robert/Bob
   - Maiden names: check if one name is a subset of the other

4. **Name + Address Match** (moderate)
   - If names match (≥ 0.8 similarity) AND same residential address → probable match
   - Same household address alone is not enough (family members share addresses)

5. **No Match** → candidate for new entity

**Same-family name collision rule**: when multiple candidates within the same household
match on first+last name alone (e.g. Dan A. Emmett father vs Daniel W. Emmett son), do NOT
merge. Require an additional disambiguator: middle initial, DOB, SSN, or explicit
role-in-document (grantor vs beneficiary, father vs son). Flag for user if none available.

**Matching output:**
```json
{
  "extracted_id": "ind_001",
  "altitude_id": "550e8400-...",
  "match_type": "SSN_MATCH",
  "confidence": "DEFINITIVE",
  "match_signals": ["SSN: 126746445", "Name: Brett Podolsky"]
}
```

### Legal Entity Matching

0. **External ID Match** (definitive)
   - Match on any matching `{provider, externalId}` pair.

1. **EIN/Tax ID Match** (definitive)
   - Normalize: strip dashes, keep only digits
   - Exact match → confirmed same entity
   - Both have EIN but differ → confirmed different entities
   - **Cross-check**: confirm the value is plausibly an EIN (`XX-XXXXXXX`). If it looks more
     like an SSN (`XXX-XX-XXXX`), it may be a grantor-trust tax ID equal to the grantor's
     SSN — record both facts.

2. **Legal Name Exact Match** (strong)
   - Case-insensitive comparison after normalizing punctuation
   - "LLC" = "L.L.C." = "Limited Liability Company"
   - If names match exactly → confirmed same entity

3. **Legal Name Fuzzy Match + Type** (strong)
   - Similarity ≥ 0.8 AND same entityType → probable match
   - Watch for: name changes, DBA names, abbreviated names

4. **No Match** → candidate for new entity

### Tangible Asset Matching

1. **Serial/Identifier Match** (definitive)
   - VIN for vehicles, APN/parcel for real property, serial for watches/art

2. **Address Match for Real Property** (strong)
   - Normalize addresses (standardize St/Street, Rd/Road, etc.)
   - Match street + city + state → confirmed same property

3. **Name + Category + Owner** (moderate)
   - If asset name matches, same category, same owner → probable match

4. **No Match** → candidate for new entity

### AccountFinancial Matching

1. **Account Number Match** (definitive)
   - If both have accountNumber, exact match → confirmed same account
   - If both have accountNumber but differ → confirmed different accounts

2. **Name + Custodian Match** (strong)
   - Account name fuzzy match (≥0.8) AND same custodianId → confirmed same account

3. **Name Fuzzy Match + Account Category** (probable)
   - Name similarity ≥ 0.8 AND same accountCategory → probable match
   - Review against transaction history to confirm

4. **No Match** → candidate for new entity

### Contact Matching

1. **Email Match** (definitive)
   - Normalize: lowercase, trim whitespace
   - Exact match → confirmed same contact

2. **First Name + Last Name + Job Title Match** (strong)
   - firstName exact match (case-insensitive) + lastName exact match + jobTitle similar → confirmed same contact
   - Skip if any field is null

3. **Phone Number Match + Last Name Match** (probable)
   - Primary phone exact match (digits only) + lastName match → probable contact
   - Watch for phone number portability and changes

4. **No Match** → candidate for new entity

### Insurance Policy Matching

1. **Policy Number Match** (definitive, confidence 1.0)
   - `policyNumber` exact match within same firm → confirmed same policy
   - If both have policyNumber but differ → confirmed different policies

2. **Name + Carrier Match** (strong, confidence 0.85)
   - `name` similarity ≥ 0.8 AND `carrierName` exact match (case-insensitive) → confirmed same policy
   - Normalize carrier names: "Northwestern Mutual" = "NML" = "NM Life"

3. **Carrier + Coverage + Category Match** (probable, confidence 0.7)
   - `carrierName` match AND `coverageAmount` match AND `policyCategory` match → probable same policy
   - Useful when policy name varies across documents (e.g., declaration page vs. premium statement)

4. **No Match** → candidate for new entity

### Liability Matching

1. **Account Number + Lender Match** (definitive, confidence 1.0)
   - `accountNumber` exact match + `lenderName` match within same firm → confirmed same liability
   - Normalize account numbers: strip spaces, dashes
   - If both have accountNumber but differ → confirmed different liabilities

2. **Name + Lender Match** (strong, confidence 0.85)
   - `name` similarity ≥ 0.8 AND `lenderName` exact match (case-insensitive) → confirmed same liability
   - Normalize lender names: "JPMorgan Chase" = "Chase" = "JP Morgan Chase Bank"

3. **Lender + Type + Balance Match** (probable, confidence 0.7)
   - `lenderName` match AND `liabilityType` match AND `currentBalance` within 5% tolerance → probable same liability
   - Balance tolerance accounts for accrued interest between statement dates

4. **No Match** → candidate for new entity

### Nested Entity Note (No Matching Required)

The following domain objects are NOT standalone entities — they are nested on their parent entity and updated via PATCH. No matching is needed; data is always merged directly into the parent entity's fields:

- **Estate Planning** (`estatePlanning` on Individual) — updated via `PATCH /api/v1/individual/{id}`
- **Philanthropic Profile** (`philanthropicProfile` on Individual) — updated via `PATCH /api/v1/individual/{id}`
- **Charitable Details** (`charitableDetails` on LegalEntity) — updated via `PATCH /api/v1/legal-entity/{id}`
- **Engagement Details** (`engagementDetails` on EntityRelationship) — updated via `PATCH /api/v1/entity-relationship/{id}`

When extracting data for these nested objects, match the PARENT entity (Individual, LegalEntity, or EntityRelationship) using the rules above, then include the nested fields in the PATCH payload for the parent.

---

## Relationship Extraction Rules

Extract and create relationships based on document analysis. Before creating any relationship via API, validate that the source→target entity type combination is valid for the relationship type.

### From Trust Agreements

Extract the following relationships from trust documents:

**Grantor → Trust**
- RelationshipType: `GRANTOR`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be TRUST)
- Required: Trust document clearly identifies grantor
- Example: "This Trust Agreement created by John Smith (the Grantor)..."

**Trustee → Trust**
- RelationshipType: `TRUSTEE`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be TRUST)
- Required: Document identifies trustee
- Optional: Store successor information in notes/supplemental attributes

**Successor Trustee → Trust**
- RelationshipType: `SUCCESSOR_TRUSTEE`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be TRUST)
- Required: Document identifies successor trustee
- Optional: Include `effectiveFrom` date (usually from trust document)

**Beneficiary → Trust**
- RelationshipType: `BENEFICIARY`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be TRUST)
- Optional: `percentage` field for distribution percentage
- Example: Percent interest in trust income/principal

**Drafting Attorney → Trust (CONTACT)**
- RelationshipType: `ATTORNEY`
- SourceEntityType: `CONTACT`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be TRUST)
- Required: Document identifies drafting attorney

### From LLC Operating Agreements

**Member → LLC**
- RelationshipType: `MEMBER`
- SourceEntityType: `INDIVIDUAL` or `LEGAL_ENTITY`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be LLC)
- Required: `percentage` field for membership percentage
- Example: "Member with 40% membership interest"

**Manager → LLC**
- RelationshipType: `OFFICER`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be LLC)
- Optional: `role` field set to "Manager"
- Note: Manager vs. Member distinction

**Registered Agent (CONTACT)**
- Store as note or supplemental attribute (not a primary relationship)
- Can create CONTACT entity and link in notes

### From Corporate Documents (C-Corp, S-Corp)

**Officer → Corporation**
- RelationshipType: `OFFICER`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be CORPORATION)
- Optional: `role` field for title (CEO, CFO, Secretary, etc.)
- Example: role="Chief Executive Officer"

**Director → Corporation**
- RelationshipType: `DIRECTOR`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be CORPORATION)
- Optional: `effectiveFrom` and `effectiveTo` for term dates

**Shareholder → Corporation**
- RelationshipType: `OWNERSHIP`
- SourceEntityType: `INDIVIDUAL` or `LEGAL_ENTITY`
- TargetEntityType: `LEGAL_ENTITY` (entityType must be CORPORATION)
- Required: `percentage` field for ownership percentage
- Example: "Owner of 25% of common stock"

### From Onboarding Sheets

**Spouse → Individual**
- RelationshipType: `SPOUSE`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `INDIVIDUAL`
- Constraint: max 1 on source entity
- Optional: `effectiveFrom` (marriage date)
- Note: Relationship is symmetric

**Children → Individual (Parent)**
- RelationshipType: `PARENT` (from child perspective) or `CHILD` (from parent perspective)
- SourceEntityType: `INDIVIDUAL` (parent)
- TargetEntityType: `INDIVIDUAL` (child)
- Optional: `effectiveFrom` (birth date or adoption date)
- Constraint: PARENT max 2 on target entity

**Household Membership → Individual**
- RelationshipType: `MEMBER`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `HOUSEHOLD`
- Optional: `percentage` for equal shares
- Optional: `isPrimary` for primary household member

### From Account Applications

**Account Owner → Account**
- RelationshipType: `OWNERSHIP`
- SourceEntityType: `INDIVIDUAL` or `LEGAL_ENTITY`
- TargetEntityType: `ACCOUNT_FINANCIAL`
- Required: `percentage` field (typically 100% for sole owner, split for joint)
- Optional: `isPrimary` for primary owner

**Authorized Signer → Account**
- RelationshipType: `AUTHORIZED_SIGNER`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `ACCOUNT_FINANCIAL`
- Note: Does NOT own the account, can execute transactions

**Beneficiary → Account**
- RelationshipType: `BENEFICIARY`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `ACCOUNT_FINANCIAL`
- Optional: `percentage` for distribution percentage
- Example: IRA or life insurance beneficiary designation

**Custodian → Account**
- Field: Set `custodianId` on AccountFinancialDto (NOT a relationship)
- Do NOT create an entity relationship for custodian

### From Estate Planning Documents

**POA Principal → Agent**
- RelationshipType: `POWER_OF_ATTORNEY`
- SourceEntityType: `INDIVIDUAL` (agent)
- TargetEntityType: `INDIVIDUAL` (principal)
- Optional: `role` field for type (financial POA, healthcare POA)
- Optional: `effectiveFrom` and `effectiveTo` dates
- Example: role="Financial Power of Attorney"

**Guardian → Minor/Incapacitated**
- RelationshipType: `GUARDIAN`
- SourceEntityType: `INDIVIDUAL` (guardian)
- TargetEntityType: `INDIVIDUAL` (ward)
- Constraint: max 1 on target entity
- Optional: `effectiveFrom` (guardianship start date)

### From Insurance Policy Documents

**Owner → Insurance Policy**
- RelationshipType: `OWNERSHIP`
- SourceEntityType: `INDIVIDUAL` or `LEGAL_ENTITY`
- TargetEntityType: `INSURANCE_POLICY`
- Required: `percentage` field (typically 100% for sole owner)
- Example: "Policy Owner: John Smith" on policy declaration

**Insured → Insurance Policy**
- RelationshipType: `INSURED`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `INSURANCE_POLICY`
- Note: May differ from owner (e.g., parent owns child's policy, ILIT owns life policy)
- Example: "Insured: Jane Smith" on life insurance policy

**Beneficiary → Insurance Policy**
- RelationshipType: `BENEFICIARY`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `INSURANCE_POLICY`
- Optional: `percentage` for distribution share
- Optional: `role` for "Primary" or "Contingent"
- Example: "Primary Beneficiary: Sarah Smith (50%), Michael Smith (50%)"

**Agent/Broker (CONTACT)**
- Extract agent name, phone, email from policy documents
- Create Contact entity and link via ADVISOR relationship to the policy owner Individual

### From Liability/Loan Documents

**Borrower → Liability**
- RelationshipType: `OWNERSHIP`
- SourceEntityType: `INDIVIDUAL` or `LEGAL_ENTITY`
- TargetEntityType: `LIABILITY`
- Required: `percentage` field (100% for sole borrower, split for joint)
- Example: "Borrower: John Smith" on loan agreement

**Co-Borrower → Liability**
- RelationshipType: `OWNERSHIP`
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `LIABILITY`
- Required: `percentage` field (typically equal split with primary borrower)
- Example: "Co-Borrower: Jane Smith" on mortgage deed

**Guarantor → Liability**
- RelationshipType: `ASSOCIATED_WITH` or note on the liability
- SourceEntityType: `INDIVIDUAL`
- TargetEntityType: `LIABILITY`
- Note: Personal guarantors on business loans — may not have a direct relationship type, record in notes/description

---

## EntityRelationshipType Reference (76 values)

The full enum has 76 values. Below are the ones most commonly extracted during onboarding, grouped by category.

### Ownership/Control
`OWNERSHIP`, `BENEFICIAL_OWNERSHIP`, `VOTING_RIGHTS`, `ECONOMIC_INTEREST`, `CONTROL`

### Fiduciary
`TRUSTEE`, `BENEFICIARY`, `SPECIFIC_GIFT_BENEFICIARY`, `GRANTOR`, `SUCCESSOR_TRUSTEE`, `SUCCESSOR_SPECIAL_TRUSTEE`, `AUTHORIZED_SIGNER`, `POWER_OF_ATTORNEY`, `GUARDIAN`, `INSURED`

### Advisory
`ADVISOR`, `CUSTODIAN`, `ACCOUNTANT`, `ATTORNEY`

### Family
`SPOUSE` (symmetric), `PARENT` (reciprocal: CHILD), `CHILD` (reciprocal: PARENT), `SIBLING` (symmetric)

Extended family: `SON_IN_LAW`, `DAUGHTER_IN_LAW`, `FATHER_IN_LAW`, `MOTHER_IN_LAW`, `BROTHER_IN_LAW`, `SISTER_IN_LAW`, `NIECE`, `NEPHEW`, `UNCLE`, `AUNT`

### Business
`EMPLOYEE`, `OFFICER`, `DIRECTOR`, `MEMBER`, `PARTNER`

### Entity Hierarchy
`PARENT_ENTITY` (reciprocal: SUBSIDIARY), `SUBSIDIARY` (reciprocal: PARENT_ENTITY), `AFFILIATE` (symmetric)

### Document & Reference
`REFERENCES`, `ATTACHED_TO`

### Generic
`ASSOCIATED_WITH` (symmetric), `RELATED_PARTY` (symmetric), `SUCCESSOR` (reciprocal: PREDECESSOR), `PREDECESSOR` (reciprocal: SUCCESSOR), `MIGRATED_TO`

### Tangible Asset Service Providers (29 types)
Real property: `PROPERTY_MANAGER`, `LANDSCAPER`, `HOUSEKEEPER`, `CARETAKER`, `SECURITY_PROVIDER`, `POOL_SERVICE`, `TENANT`
Aircraft: `PILOT`, `CO_PILOT`, `FLIGHT_INSTRUCTOR`, `AIRCRAFT_MECHANIC`, `HANGAR_MANAGER`
Marine: `CAPTAIN`, `CREW_MEMBER`, `MARINA_MANAGER`, `MARINE_MECHANIC`
Vehicles: `CHAUFFEUR`, `MECHANIC`, `DETAILER`
Art/Collectibles: `CURATOR`, `APPRAISER`, `RESTORER`, `GALLERY_CONTACT`, `AUCTION_HOUSE_CONTACT`
Luxury: `JEWELER`, `WATCHMAKER`
General: `INSURANCE_AGENT`, `STORAGE_MANAGER`, `SERVICE_PROVIDER`

### Validation Rules

**Percentage REQUIRED for**: `OWNERSHIP`, `BENEFICIAL_OWNERSHIP`, `VOTING_RIGHTS`, `ECONOMIC_INTEREST`

**Percentage OPTIONAL for**: `MEMBER`, `PARTNER`, `SUBSIDIARY`, `BENEFICIARY`

**Symmetric types** (auto-create both directions with single record): `SPOUSE`, `SIBLING`, `AFFILIATE`, `RELATED_PARTY`, `ASSOCIATED_WITH`

**Reciprocal pairs** (auto-create inverse record): `PARENT`/`CHILD`, `PARENT_ENTITY`/`SUBSIDIARY`, `SUCCESSOR`/`PREDECESSOR`

**Cardinality constraints**:
- `SPOUSE`: max 1 on source (a person can have max 1 spouse)
- `PARENT`: max 2 on target (a child can have max 2 parents)
- `GUARDIAN`: max 1 on target (a person can have max 1 guardian)
- `PARENT_ENTITY`: max 1 on target (an entity can have max 1 parent entity)
- `MIGRATED_TO`: max 1 on source (an account can only migrate to one target)

---

## Validation Before API Call

Before calling `POST /api/v1/entity-relationship`, validate:

1. **Entity Type Combinations are Valid**
   - `SPOUSE`: only INDIVIDUAL→INDIVIDUAL
   - `TRUSTEE`, `BENEFICIARY`, `GRANTOR`, `SUCCESSOR_TRUSTEE`: only to LEGAL_ENTITY with entityType=TRUST
   - `MEMBER`: INDIVIDUAL→HOUSEHOLD OR INDIVIDUAL→LEGAL_ENTITY (LLC)
   - `OWNERSHIP`, `BENEFICIAL_OWNERSHIP`: needs `percentage` field
   - `OFFICER`, `DIRECTOR`: typically INDIVIDUAL→LEGAL_ENTITY
   - `POWER_OF_ATTORNEY`: INDIVIDUAL→INDIVIDUAL
   - `GUARDIAN`: INDIVIDUAL→INDIVIDUAL, max 1 on target

2. **Required Fields Present**
   - sourceEntityId and sourceEntityType
   - targetEntityId and targetEntityType
   - relationshipType
   - percentage (for OWNERSHIP, BENEFICIAL_OWNERSHIP, VOTING_RIGHTS, ECONOMIC_INTEREST)
   - percentage optional but recommended for: MEMBER, PARTNER, SUBSIDIARY, BENEFICIARY

3. **Percentage Constraints**
   - If `percentage` provided, must be 0-100
   - Total percentage across related entities may need validation (optional)

4. **Date Constraints**
   - `effectiveFrom` must be before or equal to `effectiveTo` (if both present)
   - Consider document date as context

5. **Cardinality Constraints**
   - Check existing relationships before creating: SPOUSE (max 1), PARENT (max 2 on target), GUARDIAN (max 1 on target), PARENT_ENTITY (max 1 on target), MIGRATED_TO (max 1 on source)

6. **Symmetric/Reciprocal Behavior**
   - Symmetric types auto-create both directions (single record) -- do NOT create the reverse manually
   - Reciprocal pairs auto-create the inverse record -- do NOT create CHILD if you already created PARENT

---

## Field Merge Rules

### Document As-Of Date Resolution (determines "newness")

**Every document gets a single `asOfDate`** (ISO YYYY-MM-DD). Use this priority order,
first match wins:

1. Explicit "As of" date printed on the document (e.g., "As of 3/31/2026")
2. Document execution / signing / effective date (restated trust date, policy effective date,
   operating agreement date, signature date)
3. Filing or issue date (1099 tax year = Dec 31 of that year; deed recording date)
4. Statement period end date ("November 2025 statement" → 2025-11-30)
5. Filename-embedded date patterns: `YYYY.MM.DD`, `YYYY-MM-DD`, `MM.DD.YY`, `YYYY_MM`
   - Example: `Certificate of IconTrust 2025.05.15.pdf` → 2025-05-15
   - Example: `Glickman_David_portfolio_07-08-2025.xlsx` → 2025-07-08
   - Example: `2026.03.09 - meeting with David/` → 2026-03-09 (folder-level date)
6. File `mtime` (filesystem modification time) — **last resort only**, OneDrive/Dropbox
   sync often rewrites mtime, so this is unreliable

**Persist `asOfDate` on every extraction cache line** — the cache MUST carry this field so
Phase 4 can resolve conflicts deterministically.

### Cross-Document Merge (Phase 4.1) — Latest-Date-Wins

When the same entity field appears in multiple source documents with different values,
**the value from the document with the latest `asOfDate` wins**. This is the primary merge
rule — it supersedes "most complete value" when values actually differ.

**Decision table:**

| Situation | Action |
|---|---|
| One doc has value, another has null | Take the non-null value (no date needed) |
| Same value in both | MATCH — no action |
| Different values, both have asOfDate | **Latest asOfDate wins**. Record loser + reason. |
| Different values, neither has asOfDate | Prefer longer/more specific value; flag if ambiguous |
| Different values on an **immutable** field (SSN, DOB, EIN, formationDate, taxId) | HARD CONFLICT — flag for user, never auto-resolve |
| Amendment/Restatement document vs original | Amendment always wins; set `effectiveTo` on superseded relationships |
| Statement dated 2025-11 vs 2025-07 for same account | November wins (later) |
| Deed/filing docs with same address at different precisions | Prefer longer address **only if** its asOfDate is ≥ shorter version's |

**Field-category behavior:**

| Field Category | Merge Strategy |
|---|---|
| **Immutable** (SSN, DOB, EIN, formation date, taxId) | Must agree. Discrepancy = hard conflict |
| **Historical** (originalBalance, originationDate, purchasePrice, purchaseDate) | First confirmed value wins; don't overwrite |
| **Semi-stable** (legal name, gender, citizenship) | Latest-date-wins on real differences |
| **Mutable** (address, phone, email, employer, marital status, occupation) | Latest-date-wins always |
| **Balance / valuation** (currentBalance, currentValue, cashValue) | Latest-date-wins always |
| **Trustees / beneficiaries / managers** | Latest restatement/amendment wins; older ones become historical |
| **Cumulative** (tags, roles, multi-value relationships) | Union of all values |
| **Descriptive** (biography, notes, descriptions) | Prefer newest comprehensive version; concatenate if complementary |

**Tracking**: Every merged field carries `{value, winningSource, winningAsOfDate,
supersededValues: [{value, source, asOfDate}...]}` in the cache. This is what Phase 5
uses to render the review table.

### Altitude Diff (Phase 4.3) — Also Latest-Date-Wins

When comparing extracted data against existing Altitude entity, treat the Altitude record's
`updatedAt` as that value's asOfDate. Altitude may have been updated by another source
(direct UI edit, another ingestion) since the documents were produced.

**Five-way classification for each field:**

```
FILL         = Altitude is null/empty, extracted has value
               → Safe to auto-update. Include in PATCH payload.

MATCH        = Both have the same value (after normalization)
               → No action needed.

SUPERSEDE    = Both have values, they differ, and extracted.asOfDate > altitude.updatedAt
               → Queue for PATCH. Show both values in the review table so the user can audit.

STALE        = Both have values, they differ, but altitude.updatedAt >= extracted.asOfDate
               → KEEP Altitude. Show both values in review as FYI (user may still override).

HARD_CONFLICT = Both have values on an immutable field (SSN, DOB, EIN, formationDate, taxId)
               → BLOCK. Flag for explicit user decision. Never auto-resolve.

KEEP         = Altitude has value, extracted is null
               → Leave Altitude value unchanged.
```

**Normalization before comparison:**
- Strings: trim whitespace, case-insensitive compare
- SSN: strip to 9 digits
- EIN: strip to digits
- Dates: normalize to YYYY-MM-DD
- Phone numbers: strip to digits only
- Addresses: compare street + city + state + zip (ignore formatting)
- Booleans: normalize true/false/yes/no/"true"/"false"

**Special handling:**
- `addressLegal` is a nested object — compare each sub-field (street1, city, state, postalCode)
- Trust and LegalEntity nested objects — compare each sub-field individually
- Arrays (tags, relationships) — check for additions, not exact equality

---

## Expanded Field Lists for Diff Comparison

### INDIVIDUAL_FIELDS
Core: firstName, lastName, email, phoneNumberPrimary, phoneNumberSecondary, faxNumber, dateOfBirth, gender, taxId, taxIdType, taxIdIssuingCountry

Extended:
- `financialProfile.netWorth` - Total liquid net worth
- `financialProfile.annualIncome` - Annual income
- `financialProfile.riskTolerance` - Risk tolerance level
- `taxIdType` - Type of tax ID (SSN, ITIN, EIN, etc.)
- `taxIdIssuingCountry` - Country that issued tax ID
- `dateOfDeath` - Date individual passed away
- `addressEmployer` - Business/employer address
- `lifecycleStatus` - Status (ACTIVE, PROSPECT, INACTIVE, DECEASED)

Address fields: addressLegal, addressMailing, addressEmployer

### LEGAL_ENTITY_FIELDS
Core: legalName, entityType, taxId, taxIdType, dateIncorporated, jurisdiction, incorporationState, incorporationCountry

Extended:
- `corpAuthorizedShares` - Authorized share count (corporations)
- `corpIssuedShares` - Issued share count (corporations)
- `fiscalYearEnd` - Month/day of fiscal year end
- `nominee` - Whether entity is a nominee (boolean)
- `taxClassification` - Tax classification (C-Corp, S-Corp, LLC, Partnership, Trust, etc.)

LLC-specific (when entityType=LLC):
- `llcManagementType` - LLC management structure (MEMBER_MANAGED, MANAGER_MANAGED)

Trust-specific (when entityType=TRUST):
- `investmentAdvisor` - ID of investment advisor contact/entity
- `distributionAdvisor` - ID of distribution advisor contact/entity
- `crummeyPowerHolders` - List of individuals with Crummey powers
- `powersOfAppointment` - General/special powers of appointment
- `spendthriftProvisionText` - Spendthrift clause text
- `gstExemptionStatus` - GST exemption allocation status
- `insuranceProvisions` - Life insurance instructions
- `amendmentNumber` - Current amendment number
- `lastAmendmentDate` - Date of last amendment
- `isRestatement` - Whether this is a restatement
- `restatementDate` - Date of restatement
- `pourOverTrustName` - Name of pour-over will trust
- `trustAliases` - Alternative names for trust

### TANGIBLE_ASSET_FIELDS
Core: name, category (LUXURY, VEHICLE, REAL_PROPERTY, COLLECTIBLE, OTHER), acquisitionDate, acquisitionValue

Extended:
- `assetType` - Specific asset type (e.g., "Hermès Handbag", "2021 Mercedes-Benz")
- `acquisitionType` - How acquired (PURCHASE, GIFT, INHERITANCE, etc.)
- `taxBasis` - Cost basis for tax purposes
- `taxBasisDate` - Date of tax basis measurement
- `estateDisposition` - Intended disposition in estate (SELL, DONATE, KEEP, TRUST)
- `currentValue` - Current estimated market value
- `currentValueAsOfDate` - Date the current value was last assessed
- `designatedBeneficiaryId` - Individual designated to receive asset
- `primaryInsurancePolicyNumber` - Policy number of primary insurance coverage

Location fields: location (for real property)

### ACCOUNT_FINANCIAL_FIELDS
Core: name, accountNumber, accountCategory (INVESTMENT, CASH, RETIREMENT, etc.), active

Extended:
- `subCategory` - More specific account type (e.g., Individual Taxable, Trust, IRA)
- `wrapper` - Account wrapper type (529, UGMA, Donor-Advised Fund, etc.)
- `taxStatus` - Tax treatment (INDIVIDUAL_TAXABLE, INDIVIDUAL_IRA, TRUST, etc.)
- `currencyCode` - Primary currency (USD, EUR, GBP, etc.)
- `custodianId` - UUID of custodian entity
- `strategyId` - UUID of associated strategy
- `ownershipType` - Ownership structure (INDIVIDUAL, JOINT, TRUST, etc.)

Metadata: createdDate, lastModifiedDate, inceptionDate, closedDate

### CONTACT_FIELDS
Core: firstName, lastName, email, phoneNumberPrimary, phoneNumberSecondary, faxNumber, jobTitle

Extended:
- `jobTitle` - Business title/role
- `addressLegal` - Legal/office address
- `addressMailing` - Preferred mailing address
- `middleName` - Middle name
- `namePrefix` - Title/prefix (Mr., Dr., etc.)
- `nameSuffix` - Suffix (Jr., Sr., III, etc.)
- `biography` - Notes/biography

### INSURANCE_POLICY_FIELDS
Core: name, policyNumber, carrierName, policyCategory (LIFE, UMBRELLA, LONG_TERM_CARE, DISABILITY, HEALTH, AUTO, HOMEOWNERS, FLOOD, CYBER, COLLECTIONS, WINDSTORM, OTHER), policyStatus (ACTIVE, LAPSED, CANCELLED, PAID_UP, SURRENDERED, MATURED, PENDING)

Extended:
- `coverageAmount` - Total coverage/face value amount
- `annualPremium` - Annual premium cost
- `paymentFrequency` - MONTHLY, BI_WEEKLY, QUARTERLY, ANNUAL, INTEREST_ONLY
- `effectiveDate` - Policy start date
- `expirationDate` - Policy end date (null for permanent policies)
- `applicationDate` - Application submission date
- `issueDate` - Date policy was issued
- `firstPaymentDate` - First premium payment date (drives computed nextPaymentDate)
- `deductible` - Deductible amount
- `description` - Free-text description (max 4000)

Read-only (do NOT include in PATCH/POST):
- `owners` - List of OwnershipInfoDto (entities that own this policy via OWNERSHIP relationships)
- `documentCount` - Number of documents attached to this policy
- `nextPaymentDate` - Computed from firstPaymentDate + paymentFrequency

Life-specific (when policyCategory=LIFE):
- `lifePolicyType` - TERM, WHOLE_LIFE, UNIVERSAL, VARIABLE_UNIVERSAL, INDEXED_UNIVERSAL, SURVIVORSHIP, GROUP_TERM
- `deathBenefit` - Death benefit amount
- `cashValue` - Current cash surrender value
- `cashValueAsOfDate` - Date cash value was last computed
- `loanBalance` - Outstanding policy loan balance
- `termLengthYears` - Term length in years
- `termExpirationDate` - Term expiration date
- `isConvertible` - Whether term is convertible to permanent
- `conversionDeadline` - Conversion option deadline
- `isIlitOwned` - Whether owned by ILIT (estate planning)
- `ilitLegalEntityId` - UUID of ILIT legal entity
- `isSecondToDie` - Survivorship/second-to-die policy
- `secondInsuredIndividualId` - UUID of second insured
- `guaranteedDeathBenefit` - Whether death benefit is guaranteed
- `riders` - Policy riders description (free-text)
- `surrenderChargeSchedule` - Surrender charge schedule
- `dividendOption` - CASH, PREMIUM_REDUCTION, ACCUMULATE_AT_INTEREST, PAID_UP_ADDITIONS, ONE_YEAR_TERM

Umbrella-specific (when policyCategory=UMBRELLA):
- `excessLiabilityCoverage` - Excess liability amount
- `underlyingAutoRequired` - Required underlying auto liability limit
- `underlyingHomeRequired` - Required underlying homeowners limit
- `underlyingPoliciesDescription` - Description of underlying policies
- `coversRentalProperties` - Whether rental properties covered
- `coversWatercraft` - Whether watercraft covered
- `uninsuredMotorist` - Whether uninsured motorist included

LTC-specific (when policyCategory=LONG_TERM_CARE):
- `dailyBenefitAmount` - Maximum daily benefit
- `benefitPeriodDescription` - Benefit period description (e.g., "3 Years")
- `benefitPeriodMonths` - Benefit period in months
- `eliminationPeriodDays` - Waiting period before benefits start (days)
- `inflationProtectionType` - NONE, SIMPLE, COMPOUND_3_PERCENT, COMPOUND_5_PERCENT, CPI_LINKED, FUTURE_PURCHASE_OPTION
- `coversHomeCare` - Whether home care is covered
- `coversAssistedLiving` - Whether assisted living is covered
- `coversNursingFacility` - Whether nursing facility is covered
- `coversAdultDayCare` - Whether adult day care is covered
- `sharedBenefitRider` - Whether shared spousal benefit rider included
- `isPartnershipQualified` - Whether Partnership-qualified (Medicaid asset protection)
- `remainingBenefitPool` - Remaining benefit pool dollars

Disability-specific (when policyCategory=DISABILITY):
- `monthlyBenefitAmount` - Monthly disability benefit
- `benefitPeriodDescription` - Benefit period (e.g., "To Age 65")
- `eliminationPeriodDays` - Waiting period before benefits start (days)
- `isOwnOccupation` - Whether own-occupation coverage
- `ownOccupationPeriodDescription` - Own-occ period before transitioning to any-occ
- `costOfLivingAdjustment` - Whether COLA rider included
- `futureIncreaseOption` - Whether future increase option available
- `residualDisabilityRider` - Whether residual disability rider included
- `isGroupPolicy` - Whether employer-provided group policy
- `isTaxableBenefit` - Whether benefits are taxable

Homeowners-specific (when policyCategory=HOMEOWNERS):
- `dwellingCoverage` - Coverage A: Dwelling coverage amount
- `otherStructuresCoverage` - Coverage B: Other structures
- `personalPropertyCoverage` - Coverage C: Personal property/contents
- `lossOfUseCoverage` - Coverage D: Loss of use / additional living expenses
- `liabilityCoverage` - Coverage E: Personal liability
- `medicalPaymentsCoverage` - Coverage F: Medical payments to others
- `deductibleWindHail` - Deductible for wind/hail damage
- `deductibleAllOtherPerils` - Deductible for all other perils
- `windExcluded` - Whether wind/hurricane is excluded (common in FL)
- `constructionType` - Construction type of dwelling (e.g., "Concrete Block")
- `yearBuilt` - Year dwelling was built

Flood-specific (when policyCategory=FLOOD):
- `floodZone` - FEMA flood zone designation (e.g., "AE")
- `communityNumber` - NFIP community number
- `nfip` - Whether this is an NFIP policy vs private
- `buildingCoverage` - Building/dwelling structure coverage
- `contentsCoverage` - Personal property/contents coverage
- `hasElevationCertificate` - Whether elevation certificate is on file

Cyber-specific (when policyCategory=CYBER):
- `aggregateLimit` - Policy aggregate limit
- `retentionAmount` - Self-insured retention / deductible
- `coversRansomware` - Ransomware/cyber extortion coverage
- `coversDataBreach` - Data breach notification and response coverage
- `coversBusinessInterruption` - Business/income interruption coverage
- `coversSocialEngineering` - Social engineering fraud coverage
- `coversIdentityTheft` - Identity theft restoration coverage

Collections-specific (when policyCategory=COLLECTIONS):
- `totalScheduledValue` - Total value of all scheduled items
- `blanketCoverageLimit` - Blanket coverage limit for unscheduled items
- `agreedValue` - Whether items are at agreed value (no depreciation)
- `coversBreakage` - Whether accidental breakage is covered
- `coversMysteriousDisappearance` - Whether mysterious disappearance is covered
- `coversWorldwide` - Whether coverage extends worldwide
- `scheduledItemCount` - Number of individually scheduled items
- `collectionCategories` - Categories of items covered (e.g., "Jewelry, Watches, Fine Art")

**Merge strategy for Insurance Policies:**
- Fill empty fields (never overwrite existing non-null values)
- `policyNumber` is immutable once set
- Subtype-specific fields (life, umbrella, LTC, disability) only merge when `policyCategory` matches
- Flag conflicts: different `coverageAmount`, `annualPremium`, `policyStatus` across documents
- Relationship extraction: look for owner names (OWNERSHIP), insured persons (INSURED), beneficiaries (BENEFICIARY) in policy documents
- `cashValue` and `cashValueAsOfDate` should be treated as a pair — prefer the most recent `cashValueAsOfDate`
- `loanBalance` prefer most recent document

### LIABILITY_FIELDS
Core: name, accountNumber, lenderName, liabilityType (MORTGAGE, SECOND_MORTGAGE, HOME_EQUITY_LOC, STUDENT_LOAN, PERSONAL_LOAN, PRIVATE_LOAN, CREDIT_LINE, MARGIN_LOAN, AUTO_LOAN, BOAT_LOAN, AIRCRAFT_LOAN, ART_LOAN, BUSINESS_LOAN, CREDIT_CARD, PLEDGED_ASSET_LINE, OTHER), liabilityStatus (CURRENT, DELINQUENT, IN_DEFERMENT, IN_FORBEARANCE, PAID_OFF, DEFAULTED, CHARGED_OFF)

Extended:
- `originalBalance` - Original principal at origination
- `currentBalance` - Current outstanding balance
- `balanceAsOfDate` - Date the balance was last verified
- `creditLimit` - Credit limit (for revolving credit)
- `availableCredit` - Available credit remaining
- `interestRate` - Annual interest rate percentage
- `interestRateType` - FIXED, VARIABLE, HYBRID
- `indexRateDescription` - Index rate for variable loans (e.g., "Prime + 1.5%")
- `rateCap` - Maximum rate cap for variable loans
- `rateFloor` - Minimum rate floor for variable loans
- `monthlyPayment` - Required monthly payment
- `minimumPayment` - Minimum payment due (revolving credit)
- `paymentFrequency` - MONTHLY, BI_WEEKLY, QUARTERLY, ANNUAL, INTEREST_ONLY
- `nextPaymentDate` - Next payment due date
- `originationDate` - Loan origination/facility open date
- `maturityDate` - Loan maturity or renewal date
- `isSecured` - Whether secured by collateral (default false)
- `collateralDescription` - Description of collateral (e.g., property address)
- `linkedTangibleAssetId` - UUID cross-reference to tangible asset collateral
- `linkedAccountFinancialId` - UUID cross-reference to linked financial account
- `hasLien` - Whether the loan has a lien on the collateral asset
- `lienPosition` - Lien priority position (e.g., "FIRST", "SECOND")
- `lienRecordingInfo` - Lien recording information (county, instrument number, etc.)
- `payoffAmount` - Current payoff amount (may include fees, differ from currentBalance)
- `payoffGoodThrough` - Date through which the payoff quote is valid
- `lastPaymentDate` - Date of the most recent payment made
- `isInterestDeductible` - Whether interest is tax-deductible
- `interestDeductionType` - MORTGAGE_INTEREST, INVESTMENT_INTEREST, STUDENT_LOAN_INTEREST, BUSINESS_INTEREST, NONE
- `interestPaidYtd` - Interest paid year-to-date
- `interestPaidPriorYear` - Interest paid prior tax year
- `description` - Detailed description (max 4000)

Read-only (do NOT include in PATCH/POST):
- `owners` - List of OwnershipInfoDto (entities that own this liability via OWNERSHIP relationships)
- `documentCount` - Number of documents attached to this liability

**Merge strategy for Liabilities:**
- Fill empty fields (never overwrite existing non-null values)
- `accountNumber` is immutable once set
- Balance fields (`currentBalance`, `interestRate`, `monthlyPayment`) prefer most recent `balanceAsOfDate`
- `interestPaidYtd` and `interestPaidPriorYear` prefer Form 1098 data (most authoritative tax source)
- Flag conflicts: different `interestRate`, `monthlyPayment`, `lenderName` across documents
- Relationship extraction: look for borrower names in loan documents (create OWNERSHIP relationship from Individual/LegalEntity to Liability)
- `linkedTangibleAssetId`: if a mortgage references a property, try to match to an existing TangibleAsset and set this cross-reference
- `linkedAccountFinancialId`: if a margin loan or PAL references a brokerage account, try to match and set this cross-reference

---

## Confidence Levels

Assign confidence to each matched entity:

| Confidence | Criteria |
|---|---|
| **HIGH** | Definitive match (SSN/EIN) + zero field conflicts |
| **MEDIUM** | Strong match (name+DOB) OR definitive match with 1-2 minor conflicts |
| **LOW** | Fuzzy match OR multiple field conflicts |
| **NEW** | No match found — will create new entity |

---

## Output Format

The match-merge process produces:

```json
{
  "matched_entities": [
    {
      "entity_type": "INDIVIDUAL",
      "extracted_name": "Brett Podolsky",
      "altitude_id": "550e8400-...",
      "match_type": "SSN_MATCH",
      "confidence": "HIGH",
      "fills": [
        { "field": "dateOfBirth", "value": "1988-02-19", "source": "The Whole Shebang.docx" }
      ],
      "matches": [
        { "field": "firstName", "altitude_value": "Brett", "extracted_value": "Brett" }
      ],
      "conflicts": [
        { "field": "email", "altitude_value": "old@email.com", "extracted_value": "new@email.com", "source": "Onboarding Sheet" }
      ],
      "patch_payload": {
        "dateOfBirth": "1988-02-19"
      }
    }
  ],
  "new_entities": [
    {
      "entity_type": "INDIVIDUAL",
      "extracted_name": "Paz Lula Podolsky",
      "confidence": "NEW",
      "create_payload": { ... }
    }
  ],
  "relationships": [
    {
      "source_entity_id": "550e8400-...",
      "source_entity_type": "INDIVIDUAL",
      "target_entity_id": "550e8400-...",
      "target_entity_type": "LEGAL_ENTITY",
      "relationship_type": "TRUSTEE",
      "percentage": null,
      "source": "Trust Agreement.pdf"
    }
  ],
  "document_associations": [
    {
      "file_path": "/path/to/drivers_license.png",
      "entity_type": "INDIVIDUAL",
      "entity_name": "Brett Podolsky",
      "entity_id": "550e8400-...",
      "documentSubType": "DRIVERS_LICENSE",
      "contentType": "PNG"
    },
    {
      "file_path": "/path/to/life_policy.pdf",
      "entity_type": "INSURANCE_POLICY",
      "entity_name": "Northwestern Mutual Whole Life",
      "entity_id": "550e8400-...",
      "documentSubType": "POLICY_DECLARATION",
      "contentType": "PDF"
    },
    {
      "file_path": "/path/to/mortgage_statement.pdf",
      "entity_type": "LIABILITY",
      "entity_name": "Chase Home Mortgage",
      "entity_id": "550e8400-...",
      "documentSubType": "ACCOUNT_STATEMENT",
      "contentType": "PDF"
    }
  ]
}
```

---

## Structural Corrections (added 2026-04-21)

Standard Match & Merge produces FILL / MATCH / SUPERSEDE / STALE / HARD_CONFLICT lists per
entity (see SKILL.md Step 4.3). A sixth category — **STRUCTURAL_CORRECTION** — is needed
when the existing Altitude state is actively wrong according to authoritative source
documents (operating agreements, partnership agreements, trust instruments, Articles).

**Trigger conditions** — any of:
- Extracted ownership relationships have different source/target from existing relationships
  for the same target entity.
- Extracted ownership percentages sum to 100% but Altitude has 100% assigned to a different
  owner.
- Extracted entity type contradicts Altitude (e.g. Altitude says LLC, Articles say
  Corporation).
- Extracted jurisdiction/formation-state contradicts Altitude.

**Output format for review**:
```
## Structural Corrections (user authorization required)

### Correction: Casa Rincon LLC ownership
- **Altitude current**: Dan Emmett (IND) → Casa Rincon LLC (LE), OWNERSHIP 100%
  relationshipId: 8f3c...
- **Document reality**: 4 Emmett children @ 25% each (Operating Agreement 2014-07-22 § 3.1)
- **Affected relationships to replace**: 1
- **New relationships to create**: 4
- **Recommended action**: HARD_DELETE existing + POST 4 new
- **Blast radius**: Ownership rollup shifts from Dan to the 4 children
- **User decision**: [approve HARD_DELETE / approve MARK_HISTORICAL / defer]
```

**API recipe — HARD_DELETE** (for "never was true" corrections):
```bash
OLD_ID="8f3c..."
curl -X DELETE "$API/api/v1/entity-relationship/$OLD_ID/hard" -H "X-API-Key: $KEY"
# then POST new OWNERSHIP relationships
```

**API recipe — MARK_HISTORICAL** (for "was true, has ended" transitions):
```bash
OLD_ID="8f3c..."
curl -X PATCH "$API/api/v1/entity-relationship/$OLD_ID" \
  -H "Content-Type: application/merge-patch+json" -H "X-API-Key: $KEY" \
  -d '{"effectiveTo":"2025-07-08"}'
# then POST new relationships with effectiveFrom: "2025-07-08"
```

Do NOT use soft-delete (`DELETE /{id}` without `/hard`) — the uniqueness constraint on
(source, target, type) is enforced even on soft-deleted rows, so a subsequent POST with the
same tuple fails with HTTP 409. This is the same constraint SKILL.md Rule 21 and Rule 41
(role replacements) rely on.

---

## Generated
2026-03-19 (last updated 2026-04-21: external ID matching, SSN/EIN cross-check, same-family
name collision rule, Structural Corrections workflow)
