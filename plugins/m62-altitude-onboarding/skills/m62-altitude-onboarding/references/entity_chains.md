# Multi-Generational Entity Ownership Chains

Wealthy families rarely own assets directly. Instead they build layered structures using
corporations, trusts, LLCs, and partnerships — each layer serving a tax / governance /
estate-planning purpose. This reference documents the common chains you will encounter and
the correct Altitude relationship modeling for each.

---

## Why This Matters

The relationship matrix in `SKILL.md` Phase 4.5 is heavy on **individual → legal-entity**
rows (Dan owns LLC X). But real family structures have **legal-entity → legal-entity** rows
(Dan's trust owns management LLC, which is GP of partnership, which owns operating LLC,
which owns the house).

If you only model IND→LE relationships, the ownership graph is wrong and valuation rollup
will under-count or mis-attribute assets.

---

## Common Patterns

### Pattern 1 — Trust-Owned Family LLC

```
Individual (Dan) ──GRANTOR/TRUSTEE──▶ Dan A. Emmett Revocable Trust (LE: TRUST)
                                         │
                                         │ OWNERSHIP 95%  (MEMBER)
                                         ▼
                                    Rivermouth Management LLC (LE: LLC)
                                         │
                                         │ OWNERSHIP 100%
                                         ▼
                                    150-156 Rincon Point Rd (TA: REAL_PROPERTY)
```

**Relationships created:**
| Source | Target | Type | Percentage | Notes |
|---|---|---|---|---|
| Dan (IND) | Dan's Trust (LE) | GRANTOR | — | — |
| Dan (IND) | Dan's Trust (LE) | TRUSTEE | — | Initial trustee |
| Dan's Trust (LE) | RMM LLC (LE) | OWNERSHIP | 95% | Member |
| Rae's Trust (LE) | RMM LLC (LE) | OWNERSHIP | 5% | Member |
| RMM LLC (LE) | Property (TA) | OWNERSHIP | 100% | — |

**Do NOT** create a direct `Dan → Property` OWNERSHIP — the trust owns through RMM, not Dan.

---

### Pattern 2 — GP/LP Family Partnership

```
Individual (Dan)   Individual (Rae)
      │                 │
      │ GRANTOR/TRUSTEE  │ GRANTOR/TRUSTEE
      ▼                 ▼
  Dan's Trust       Rae's Trust
      │                 │
      └─────┬───────────┘
            │ OWNERSHIP (95%, 5%)
            ▼
     Rivermouth Management LLC (GP)
            │
            │ OWNERSHIP 1% (GP designation)
            ▼
     Rivermouth Partners LP ◀─── OWNERSHIP 24.75% each (LP) ─── 4 child trusts
            │
            │ OWNERSHIP 100%
            ▼
     Holding / Operating accounts
```

**Relationships:**
| Source | Target | Type | Percentage | Role |
|---|---|---|---|---|
| RMM LLC (LE) | Rivermouth Partners (LE) | OWNERSHIP | 1% | General Partner |
| Daniel W's Trust (LE) | Rivermouth Partners (LE) | OWNERSHIP | 24.75% | Limited Partner |
| Rosalind M's Trust (LE) | Rivermouth Partners (LE) | OWNERSHIP | 24.75% | Limited Partner |
| Morgan W's Trust (LE) | Rivermouth Partners (LE) | OWNERSHIP | 24.75% | Limited Partner |
| Tyler A's Trust (LE) | Rivermouth Partners (LE) | OWNERSHIP | 24.75% | Limited Partner |

Use `role` to capture GP vs LP designation; `percentage` captures the ownership split.

---

### Pattern 3 — Family Office Holdco Manager

```
Individual (Dan) ──OFFICER (CEO)──▶ McKinley Properties, Inc. (LE: CORPORATION / S-Corp)
                                        │
                                        │ (MANAGER — not owner)
                                        ▼
                                    Rivermouth Management LLC (LE: LLC)
                                    ...then onward to Partners LP etc.
```

The S-Corp here is a **manager**, not an owner. Use the `OFFICER` or `DIRECTOR` relationship
type, or the `MANAGER` role convention if the Altitude schema has no explicit MANAGER type.

The S-Corp is its own LegalEntity with its own officers/directors. Create relationships
from each named individual to the S-Corp: `OFFICER`, `DIRECTOR`, `AUTHORIZED_SIGNER` as
appropriate.

---

### Pattern 4 — Children Own Operating LLC Directly

```
┌── Daniel W ──OWNERSHIP 25%──┐
├── Rosalind M ──OWNERSHIP 25%─┼──▶ Casa Rincon LLC (LE) ──OWNERSHIP 100%──▶ Real Property (TA)
├── Morgan W ──OWNERSHIP 25%──┤           │ MANAGED BY
└── Tyler A ──OWNERSHIP 25%──┘           ▼
                                  Rivermouth Management LLC (manager)
```

Here the children own directly (not through their trusts). Verify by reading the LLC's
operating agreement — is the "Member" a natural person or a trust? This matters for
percentage attribution: if the member is the trust, the rollup goes to the trust first.

---

### Pattern 5 — ILIT (Irrevocable Life Insurance Trust) Chain

```
Individual (Dan) ──GRANTOR──▶ Smith ILIT (LE: TRUST, irrevocable)
                                  │ OWNERSHIP 100%
                                  ▼
                              Life Insurance Policy (INSURANCE_POLICY)
                                  │ INSURED
                                  ▲
Individual (Dan) ─────────────────┘

(Dan is the INSURED, the ILIT is the OWNER and BENEFICIARY)
```

Three relationships needed:
- Dan (IND) → ILIT (LE) — GRANTOR
- ILIT (LE) → Policy (INS_POL) — OWNERSHIP 100%
- Dan (IND) → Policy (INS_POL) — INSURED
- ILIT (LE) → Policy (INS_POL) — BENEFICIARY

Also set `InsurancePolicy.isIlitOwned = true` and `ilitLegalEntityId` pointing to the ILIT.

---

## Relationship Types for LE → LE

The standard relationship matrix is primarily IND→LE. For entity-to-entity rows, use these:

| LE→LE relationship | When to use | Needs % |
|---|---|---|
| OWNERSHIP | Trust owns LLC, LLC is member of LP, Holdco owns sub | Yes |
| MEMBER | Explicitly identified as LLC member (alternative to OWNERSHIP with role: "Member") | Yes |
| PARTNER | Explicitly a partner in a partnership | Yes |
| BENEFICIARY | Trust beneficiary is another entity (rare, but possible: charitable beneficiary trust, foundation) | Optional |
| BENEFICIAL_OWNERSHIP | Beneficial ownership through a chain | Yes |

**Manager designation** — if an LLC is manager-managed with another LE as manager (e.g.
McKinley Properties manages RMM LLC), Altitude lacks a first-class MANAGER relationship
type. Use `OFFICER` or capture in the LE's `llcManagementType` + a note, and document the
manager-LE as a note on the entity. (Pending: add `MANAGER` relationship type to Altitude.)

---

## Inference Tips

- **"Managed by" in Op Agreement** → `llcManagementType: MANAGER_MANAGED` + a Contact/LE
  relationship for the manager. If manager is an LE, use `MANAGER` semantics (see above).
- **"General Partner" / "Limited Partner"** in Partnership Agreement → OWNERSHIP with
  `role: "General Partner"` or `"Limited Partner"` and correct percentage.
- **"Member" in LLC Op Agreement** → OWNERSHIP with `role: "Member"` or `"Managing
  Member"`.
- **"Grantor", "Settlor", "Trustor"** → GRANTOR relationship.
- **"Trustee"** → TRUSTEE.
- **"Successor Trustee 1st / 2nd / 3rd"** → SUCCESSOR_TRUSTEE with priority 1 / 2 / 3.

## Order of Creation

Create entities in dependency order so that when you POST a relationship, both endpoints
already exist:

1. Household (if new)
2. Individuals (all family members, including those who only appear as trustees/grantors)
3. **Top-of-chain LEs** first (family-office S-Corp, revocable trusts)
4. **Middle-tier LEs** (holding LLCs, partnerships)
5. **Leaf LEs** (operating LLCs, property LLCs)
6. Accounts
7. Tangible Assets
8. Insurance Policies
9. Liabilities
10. Relationships (all at once, after all entities exist)

Never create a relationship whose target doesn't yet exist in Altitude — POST will 400.

---

## Generated
2026-04-21 — created in response to Emmett-household extraction revealing multi-generational
chain (McKinley Properties → RMM LLC → Rivermouth Partners → 4 child trusts + operating
LLCs) that the existing skill didn't model explicitly.
