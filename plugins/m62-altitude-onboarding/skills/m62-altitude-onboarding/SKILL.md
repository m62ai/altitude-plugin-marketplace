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

## Life-event modes (detect early, branch appropriately)

Before anything else, sniff the folder for **life-event signals** that change how this flow
should behave. If any of these markers are present, add a banner to the review and branch.

| Signal in folder | Mode | Implications |
|---|---|---|
| `divorce`, `MSA`, `Judgment`, `schedule of assets`, `FL-150`, `<client> divorce documents` | **Divorce / post-divorce** | Expect HISTORICAL spouse, joint-trust division, community property allocation. Expect the final MSA/Judgment to be authoritative — if missing, defer ownership decisions. Treat ex-spouse as Contact (optionally Individual for historical SPOUSE). |
| `prenuptial`, `transmutation`, `Cal Fam Code §852` | **CP transmutation** | All pre-marital separate property may now be community. Don't assume pre-2025 ownership carries forward. |
| `estate of`, `probate`, `letters testamentary` | **Post-death** | Primary individual may be deceased. Use `lifecycleStatus=DECEASED` and `dateOfDeath`. Estate is the active entity, not the individual. |
| `prospect`, unsigned client agreement | **Pre-engagement** | Record client-since date. Anything dated before the signed client agreement is prospect data. |
| Folder from partner firm (e.g. <partner firm> Share) with `USE THESE PER ...` or `LATEST` or `FINAL` directory/filename prefixes | **Authority markers** | Prefer files in authority-marked folders over other sources when resolving conflicts. |

**For the Divorce mode specifically**: (a) Every joint-titled asset belongs in **Tier B —
Pending MSA** until the final judgment specifies allocation. Don't create joint-trust
accounts under the client's Household without flagging. (b) The ex-spouse is NOT a client.
Create as a Contact with role "Former spouse / counterparty" OR as an Individual with
`SPOUSE` relationship marked HISTORICAL (set `effectiveTo` to the decree date once known).
(c) Family trusts that existed before the divorce are typically being divided — track them
as HISTORICAL and create the NEW post-divorce trusts as current entities.

## Fund-entity flood (aggregate vs create individually)

When the client's household includes an operating partner at a VC/PE firm, or any limited
partner in 50+ investment vehicles (Accel, Sequoia, KKR, Accel-India, IDG-Accel China, etc.),
you will extract hundreds of partnership LegalEntities (Accel XVI Investors LLC, Accel
London VII LP, etc.). These are typically already tracked in Addepar at the position level.

**Default rule: DO NOT create individual LegalEntity records for investment fund vehicles.**
Instead:
- Track aggregate exposure as supplemental attributes on the parent trust or account
  ("Total Accel carry: $120M unrealized, $40M side-funds")
- If the client wants entity-level tracking, create a single umbrella LegalEntity
  (e.g. "Accel Carry — the household's Trust") with supplemental attributes listing the
  component funds
- Full fund list stays in the extraction cache (`altitude_review/extraction_cache.jsonl`)
  for audit / future refinement

## Absence-as-data: empty folders and missing documents

Wealth management firms often use standardized folder templates. When you encounter empty
folders (`Insurance/`, `Investments/`, `Client Reporting/`, `Miscellaneous/`), treat them
as **absence signals**, not ignore-able:

- Empty `Insurance/` → "No insurance documents collected yet" → open question: does client have
  policies we need to request?
- Empty `Investments/` → "No investment docs" → is this because investments are via a separate
  custodian, or because we haven't collected them?
- Empty `Client Reporting/` → "Client may be pre-engagement" → confirm client-since date

Record absence facts in `altitude_review/open_questions.json` and the review, don't drop them.

## Addepar-sync provenance (do not clobber synced fields)

Any entity whose `externalIds` includes `provider: ADDEPAR` is populated by nightly Addepar
sync. PATCHing Addepar-owned fields risks having your changes overwritten on the next sync.

Rule of thumb before PATCHing:
1. Check `externalIds` on the entity — if `provider=ADDEPAR` exists, the Addepar sync owns:
   - Account: accountNumber, custodianId, accountCategory, provider-side balances, position data
   - Individual: synced name + DOB from the Addepar "party" record
   - Household: the Addepar hierarchy name
2. Only PATCH fields that are NOT owned by Addepar (estatePlanning, email, phone,
   supplementalAttributeValues, Altitude-side metadata)
3. If you must PATCH a synced field, leave a note in the review flagging the sync conflict risk

## Auto-HISTORICAL SPOUSE when divorce signals are present

If any file in the folder matches the Divorce / post-divorce life-event signals (MSA,
Judgment, schedule of assets, FL-150, protective-order stipulation, "divorce decree", etc.),
the SPOUSE relationship MUST be created HISTORICAL, not current:

```json
{
  "relationshipType": "SPOUSE",
  "sourceEntityType": "INDIVIDUAL", "sourceEntityId": "<clientA>",
  "targetEntityType": "INDIVIDUAL", "targetEntityId": "<clientB>",
  "effectiveTo": "<decree date | stipulation date | best available divorce-milestone date>",
  "role": "Former spouse (divorced <date> per <source doc>)"
}
```

**Priority for `effectiveTo`**:
1. Final MSA / Judgment of Dissolution date (if in folder)
2. Court-filed stipulation date (e.g. "Stip re Protective Order [F.MM.DD.YY]")
3. Date of earliest divorce filing visible in the folder
4. If none available, create the SPOUSE WITHOUT `effectiveTo` but flag in Open Questions
   "No divorce decree date found — SPOUSE marked current until MSA is produced"

**DO NOT** create the SPOUSE as current with `role: "Spouse (separation pending divorce)"` —
the frontend renders it as "married" regardless of role. Use `effectiveTo` to make it
HISTORICAL. If unknown, either omit the relationship entirely or flag the date gap.

**Caveat — field-nulling limitation**: Spring merge-patch ignores null values on
`entity-relationship` PATCH, so setting `effectiveFrom` to null after creation does NOT
work. Always set `effectiveFrom` correctly (or OMIT it) AT CREATION time. For SPOUSE where
the marriage date is unknown, omit `effectiveFrom` at POST time rather than defaulting to
"today".

## Always create PARENT/CHILD edges for household children

The Household→Individual OWNERSHIP relationship (skill default) establishes MEMBERSHIP but
NOT family structure. The frontend's family tree, estate plan chart, and beneficiary
flowchart ALL depend on `PARENT` (and inverse `CHILD`) edges. After creating the Household
OWNERSHIP edges, also create:

For each minor-or-adult child in the household with at least one identified parent:
```json
{
  "relationshipType": "PARENT",
  "sourceEntityType": "INDIVIDUAL", "sourceEntityId": "<parent-individual>",
  "targetEntityType": "INDIVIDUAL", "targetEntityId": "<child-individual>",
  "effectiveFrom": "<child's DOB>",
  "role": "Biological parent"  // or "Adoptive parent", "Step-parent"
}
```

**Cardinality**: PARENT has `maxCardinality: 2` on the target — a child can have max 2
PARENT edges. Create one per identified biological/legal parent. If only one parent is
identified (e.g. the non-client parent is unknown or deceased), create just the one edge.

**Include the ex-spouse as a parent**: In post-divorce cases where the ex-spouse is the
children's other parent, the ex-spouse needs to be an Individual (not just a Contact) to
serve as the PARENT source. Always create the ex-spouse as an Individual with HISTORICAL
SPOUSE, THEN create PARENT edges from BOTH parents to each child.

**Inverse CHILD edges**: the `EntityRelationshipType` enum maps `PARENT ↔ CHILD` as inverse
reciprocals (see `getInverseType()`). Depending on the backend version, creating PARENT may
or may not auto-create CHILD. Verify after creation; if missing, create CHILD explicitly.

## Vendor firms and institutions are Contacts, NOT LegalEntities

**Rule**: A `LegalEntity` in Altitude represents an entity the household has an **ownership,
beneficial, fiduciary (as grantor/trustee/beneficiary), or membership** interest in —
trusts they created, LLCs they own, partnerships they're a partner in, corporations they
hold shares of. Everything else is a Contact, even if it is technically a corporation in
the real world.

**Do NOT create a LegalEntity for**:
- **Corporate trustees / executor firms** providing fiduciary service (e.g. fiduciary trust
  companies, professional executor services). Create the company as a Contact with
  `jobTitle: "Corporate Trustee"` or `biography: "<company name>"`; use an individual
  officer's Contact if a specific person is named in the trust/will.
- **Schools / universities** the client or their children attend. Create as a Contact with
  `jobTitle: "School"` or similar, or just note in Individual's supplemental attributes.
- **Custodian banks** (Schwab, Fidelity, Merrill, Wells Fargo, etc.) — these are modeled
  separately as `Custodian` entities on accounts. Never a LegalEntity.
- **Law firms, accounting firms, advisory firms** whose individual professionals we've
  already created as Contacts. The firm name lives on the Contact's `biography`.
- **Investment fund vehicles** the client indirectly holds via a carry/side-fund interest
  (see "Fund-entity flood" — aggregate at the parent trust, don't create per-fund entities).
- **Government agencies, courts, tax authorities, registrars** mentioned in documents.
- **Vendors** (property management companies, insurance brokerages, auction houses, galleries,
  etc.) — Contact with biography identifying the firm.

**DO create a LegalEntity for**:
- Trusts the household is the grantor/beneficiary/trustee of
- LLCs / LPs / partnerships the household owns or is a member/partner of
- Corporations the household holds shares in (if material and tracked at entity level)
- DAFs and private foundations the household funded
- Operating companies the household controls
- Holdco entities in the household's ownership chain

**If in doubt, ask**: "Does the household have an ownership, fiduciary, or beneficial
interest in this entity, OR is it just providing a service?" Services → Contact. Interest
→ LegalEntity.

Example miss: a recent onboarding created "Trust Company X" (a
corporate trustee providing fiduciary service) as a LegalEntity with EXECUTOR and
SUCCESSOR_TRUSTEE relationships pointing to it. Correct model: Trust Company X is a Contact
(the individual officer or the company with `jobTitle: "Corporate Trustee"`), and the
EXECUTOR / SUCCESSOR_TRUSTEE relationships originate from the Contact using the
CONTACT→INDIVIDUAL / CONTACT→LEGAL_ENTITY validator rules.

## Firm users are NOT Contacts — check before creating

Advisors, analysts, COOs, client-service staff, and any other employee of the firm that
owns this household are already system Users and will be attached to the household via its
**FirmTeam** membership (separate admin flow). Do NOT create them as per-household Contacts.

**Mandatory precheck — before POSTing ANY Contact:**

```bash
# Get the firm's users once at the start of the run and cache them
curl -s "${BASE}/user?firmId=${FIRM_ID}&size=200" -H "X-API-Key: ${API_KEY}" \
  | jq -r '(.content // .)[] | "\(.email // .login)\t\(.firstName) \(.lastName)"' \
  > altitude_review/firm_users.tsv
```

Then for every Contact candidate, block creation if ANY of these match:
- The candidate's email is in the firm users list (exact match)
- The candidate's email domain matches the firm's domain (e.g. `@<firm-domain>.com`, `@m62.ai`)
- The candidate's full name (first+last, case-insensitive) matches a firm user

If matched, record in `altitude_review/firm_users_skipped.md` (name + why) and skip Contact
creation entirely. They are NOT the client's relationship — they are the firm serving the
client. The FirmTeam admin flow handles attachment to the household.

**Who SHOULD be a Contact:**
- External professionals: outside attorneys, outside CPAs, insurance agents at external
  brokerages, prior-firm advisors (e.g. pre-transition), corporate trustees from other
  companies (e.g. an independent corporate trustee)
- Family members and personal contacts (healthcare agents, successor trustees, guardians,
  executors who are individuals)
- Vendors / service providers (property managers, household staff when recorded as Contacts,
  marina managers, etc.)

**Who should NOT be a Contact (belongs on FirmTeam instead):**
- The firm's lead advisor, co-advisor, junior advisors, analysts, planners
- Firm operations (COO, CTO, compliance officer, head of ops)
- Firm client-service team (client-service associates, administrative staff)
- Firm interns
- **Any email ending in the firm's domain**

Real example: a recent onboarding run wrongly created 5 firm employees (all matching the
firm's email domain) as Contacts + ADVISOR relationships. They belong on the household's
FirmTeam, not as per-household Contacts. Always run the precheck above first.

## Prerequisites

### Required Tools

This skill runs cross-platform (macOS, Linux, Windows). The following tools must be installed
and on the user's `PATH` **before** running. Verify each at the start of Step 0 with
`shutil.which(...)` and fail fast with a clear message if anything is missing — do NOT
attempt to install tooling automatically.

| Tool | Why | macOS | Linux | Windows |
|---|---|---|---|---|
| **Python 3.9+** | Script runtime for .docx/.xlsx/.eml/large PDFs | `brew install python` | `apt install python3` | `winget install Python.Python.3.12` (avoid the Microsoft Store stub — it silently redirects to a non-functional alias) |
| **pip packages** | Document parsing | `pip install pypdf python-docx openpyxl requests` | same | same |
| **qpdf** | Decrypt password-protected PDFs | `brew install qpdf` | `apt install qpdf` or `dnf install qpdf` | `winget install qpdf.qpdf` or `choco install qpdf` or `scoop install qpdf` |
| **poppler** (pdftotext) | **Text-first PDF extraction (REQUIRED, not optional)** — the default PDF read strategy uses `pdftotext -layout` before falling back to Claude's Read tool. Avoids the 2000px image-dimension limit that scanned-PDF pages can hit. | `brew install poppler` | `apt install poppler-utils` | `winget install oschwartz10612.Poppler` or `choco install poppler` |
| **tesseract** (OCR) | Fallback for scanned PDFs where `pdftotext` returns empty (i.e., pure image PDFs — trust documents, deeds, handwritten notes). Pipe `pdftoppm -r 150` → `tesseract` to get text. | `brew install tesseract` | `apt install tesseract-ocr` | `winget install UB-Mannheim.TesseractOCR` or `choco install tesseract` |
| **pandoc** (optional) | Cross-platform .docx → text | `brew install pandoc` | `apt install pandoc` | `winget install JohnMacFarlane.Pandoc` |
| **curl** | Occasional API examples (all scripted work uses `requests`) | built-in | built-in | built-in on Windows 10 1803+ (`C:\Windows\System32\curl.exe`) |

**Verify with this snippet** (use `PYTHON` from Cross-Platform Setup below):

```python
# check_prereqs.py
import shutil, socket, sys
missing = []
# Required tools
for tool in ("qpdf", "pdftotext"):        # pandoc + tesseract are optional-but-recommended
    if not shutil.which(tool):
        missing.append(tool)
# Python packages
try:
    import pypdf, docx, openpyxl, requests  # noqa: F401
except ImportError as e:
    missing.append(f"python package: {e.name}")
# DNS reachability check (fail fast if the user is on a restricted network)
try:
    socket.gethostbyname("api.m62.live")
except socket.gaierror:
    missing.append("DNS: cannot resolve api.m62.live (check network or set up hosts override — see Step 0.c)")
if missing:
    sys.exit(f"Missing prerequisites: {', '.join(missing)}")
print("All prerequisites OK")
```

### Windows-Specific Notes

1. **Python alias trap**: Windows 10+ ships a `python.exe` stub that opens the Microsoft
   Store instead of running Python. Verify with `python --version`. If it opens the Store,
   disable the alias under *Settings → Apps → Advanced app settings → App execution aliases*
   and install real Python from [python.org](https://www.python.org/downloads/windows/) or winget.
2. **Long paths (MAX_PATH 260)**: household folders with deep nesting can exceed Windows'
   legacy 260-character path limit. Either enable long paths (`reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f` as admin, then reboot)
   or place household folders at a short root like `C:\cl\` instead of the default Documents tree.
3. **File paths in prompts**: when passing file paths to sub-agents, use **forward slashes or
   raw strings** in Python (`r"C:\cl\Smith"` or `"C:/cl/Smith"`). Mixing backslashes with
   regular strings causes `\n`, `\t`, `\r` escapes to fire unexpectedly.
4. **PowerShell execution policy**: running `.ps1` scripts may be blocked by the default
   `Restricted` policy. For the refresh scripts, either run with `powershell -ExecutionPolicy Bypass -File tools\refresh-api-spec.ps1` or set the policy once with
   `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
5. **No bash-isms**: Do not write `&&`, `||`, `$(...)` command substitution, `${VAR}`
   expansion, single-quote heredocs, or `python -c "..."` with embedded newlines.
   Always write scripts to a `.py` file and run them with `python script.py`.
6. **Line endings**: Python handles CRLF/LF transparently. If you write a `.py` helper
   script on Windows, don't worry about line endings.

### Step 0: Load Saved Configuration + Authenticate

**Do this FIRST before anything else.**

Altitude implements a full **OAuth 2.1 + PKCE + Dynamic Client Registration** authorization
server — the exact same protocol Claude uses for its MCP/connector integrations
(RFC 8414 / RFC 7591 / RFC 9728 / RFC 7636). This is the preferred interactive auth mode
for the skill: the user signs in on Altitude's own hosted login page in a browser, approves
the client, and the skill receives a JWT access token via a local loopback callback.

The access token returned by OAuth is a standard Altitude JWT — it works for **every**
REST endpoint (`/api/v1/individual`, `/api/v1/household`, `/api/v1/document`, etc.), not
just MCP endpoints, despite the `mcp:read`/`mcp:write` scope names.

**Auth modes supported:**

| Mode | Header used on every request | When to use |
|---|---|---|
| **OAuth (browser)** | `Authorization: Bearer <access_token>` | **Default for interactive use.** Altitude-hosted login, optional MFA, refresh tokens. |
| **API Key** | `X-API-Key: ak_live_...` | Automation, CI, long-lived server integrations. No browser needed. |
| **JWT (direct)** | `Authorization: Bearer <id_token>` | Fallback: user pastes a JWT obtained out-of-band (e.g., from the Altitude UI session). |

#### 0.a — Config file schema

`{HOME_DIR}/.altitude/config.json` (where `HOME_DIR` is `$HOME` on macOS/Linux or
`%USERPROFILE%` on Windows). The config supports all three modes via an `authMode`
discriminator:

```json
{
  "authMode": "oauth" | "api_key" | "jwt",
  "baseUrl": "https://api.m62.live",
  "firmName": "Firm A",

  "apiKey": "ak_live_xxxxxxxx",                    // if authMode=api_key
  "jwt": "eyJhbGciOiJIUzUxMi...",                  // if authMode=jwt (manual paste)

  // if authMode=oauth — populated by the OAuth flow below:
  "oauth": {
    "clientId": "{firm-uuid}",
    "accessToken": "eyJhbGciOiJIUzUxMi...",
    "refreshToken": "k8f3...",
    "tokenType": "Bearer",
    "expiresAt": "2026-04-18T18:00:00Z",
    "scope": "mcp:read mcp:write",
    "email": "advisor@firm.com"                    // cached only for display
  }
}
```

**Security rules** (enforce strictly):
1. **NEVER write the password to disk.** OAuth is specifically designed so the skill never
   sees the password — the browser handles that directly with Altitude.
2. Keep the config file `chmod 600` on Unix; on Windows, NTFS per-user ACLs under
   `%USERPROFILE%` provide equivalent protection.
3. When the `accessToken` is within 5 minutes of expiry, silently refresh via
   `POST /oauth/token` with `grant_type=refresh_token`. If the refresh fails (revoked,
   expired), fall back to the full browser auth flow.

#### 0.b — If config exists and credentials are current

- `authMode=api_key` + `apiKey` set → smoke-test with `GET /api/v1/authenticate` → use
- `authMode=oauth` + `accessToken` not expired → use immediately
- `authMode=oauth` + `accessToken` expired but `refreshToken` valid → refresh silently
- Any other state → run the appropriate auth flow below

#### 0.c — Auth Mode 1: OAuth (browser, recommended for interactive use)

**This is the Claude-connector flow.** The skill acts as a public OAuth client:

1. **Discover endpoints** — GET `{baseUrl}/.well-known/oauth-authorization-server` returns:
   ```json
   {
     "issuer": "https://api.m62.live",
     "authorization_endpoint": "https://api.m62.live/oauth/authorize",
     "token_endpoint": "https://api.m62.live/oauth/token",
     "registration_endpoint": "https://api.m62.live/oauth/register",
     "scopes_supported": ["mcp:read", "mcp:write"],
     "grant_types_supported": ["authorization_code", "refresh_token"],
     "response_types_supported": ["code"],
     "code_challenge_methods_supported": ["S256"],
     "token_endpoint_auth_methods_supported": ["none"]
   }
   ```
   Cache these endpoints.

2. **Dynamically register the skill as an OAuth client** (RFC 7591). This is a one-time
   operation — after the first successful registration, reuse the `clientId` from config.
   POST `{registration_endpoint}` with JSON:
   ```json
   {
     "client_name": "M62 Altitude Onboarding Skill",
     "redirect_uris": ["http://127.0.0.1:<random-free-port>/callback"],
     "grant_types": ["authorization_code", "refresh_token"],
     "token_endpoint_auth_method": "none",
     "response_types": ["code"]
   }
   ```
   Allowed redirect URIs are `http://localhost`, `http://127.0.0.1`, or `https://`. The
   response contains `client_id` — save it to `config.oauth.clientId` for reuse.

3. **Start a local loopback HTTP server** on `127.0.0.1:<port>` to receive the OAuth
   redirect. Bind port **0** to let the OS pick a free port, then read the assigned port.

4. **Generate PKCE values** (RFC 7636, S256 only):
   ```python
   import secrets, hashlib, base64
   code_verifier = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode()
   code_challenge = base64.urlsafe_b64encode(
       hashlib.sha256(code_verifier.encode()).digest()
   ).rstrip(b"=").decode()
   state = secrets.token_urlsafe(32)  # CSRF protection
   ```

5. **Open the browser** to the authorization endpoint with query parameters:
   ```
   {authorization_endpoint}
     ?response_type=code
     &client_id={clientId}
     &redirect_uri=http://127.0.0.1:{port}/callback
     &scope=mcp:read%20mcp:write
     &state={state}
     &code_challenge={code_challenge}
     &code_challenge_method=S256
   ```
   The user sees **Altitude's own login page** (not the skill's UI) in their browser,
   enters their email + password, and Altitude authenticates them. On success, Altitude
   redirects to `http://127.0.0.1:{port}/callback?code=XXX&state=YYY`.

6. **Local server catches the redirect**, validates `state`, captures `code`, shows the
   user a "Signed in — you can close this tab" page, then shuts down.

7. **Exchange code for tokens** — POST `{token_endpoint}` as
   `application/x-www-form-urlencoded`:
   ```
   grant_type=authorization_code
   &code={captured_code}
   &code_verifier={code_verifier}
   &redirect_uri=http://127.0.0.1:{port}/callback
   &client_id={clientId}
   ```
   Response (200):
   ```json
   {
     "access_token": "eyJhbGciOiJIUzUxMi...",
     "token_type": "Bearer",
     "expires_in": 3600,
     "refresh_token": "k8f3...",
     "scope": "mcp:read mcp:write"
   }
   ```
   Save `accessToken`, `refreshToken`, `expiresAt = now + expires_in - 30s` (30s buffer),
   and `tokenType` to `config.oauth.*`.

**Complete script** — write this to a temp file and run it. It handles the whole flow
including the loopback server:

```python
# altitude_oauth_login.py
import base64, hashlib, http.server, json, os, pathlib, secrets, socketserver
import sys, threading, urllib.parse, urllib.request, webbrowser

BASE = sys.argv[1]  # e.g., https://api.m62.live

# 1. Discover endpoints
meta_url = f"{BASE}/.well-known/oauth-authorization-server"
meta = json.loads(urllib.request.urlopen(meta_url, timeout=10).read())

# 2. Load or register client
home = pathlib.Path(os.environ.get("USERPROFILE") or os.environ["HOME"])
cfg_path = home / ".altitude" / "config.json"
cfg_path.parent.mkdir(exist_ok=True)
cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
client_id = cfg.get("oauth", {}).get("clientId")

# 3. Pick a free loopback port
with socketserver.TCPServer(("127.0.0.1", 0), None) as s:
    port = s.server_address[1]
redirect_uri = f"http://127.0.0.1:{port}/callback"

if not client_id:
    reg_body = json.dumps({
        "client_name": "M62 Altitude Onboarding Skill",
        "redirect_uris": [redirect_uri],
        "grant_types": ["authorization_code", "refresh_token"],
        "token_endpoint_auth_method": "none",
        "response_types": ["code"],
    }).encode()
    req = urllib.request.Request(meta["registration_endpoint"], data=reg_body,
                                 headers={"Content-Type": "application/json"})
    reg = json.loads(urllib.request.urlopen(req, timeout=10).read())
    client_id = reg["client_id"]
    print(f"Registered OAuth client: {client_id}")

# 4. PKCE
cv = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode()
cc = base64.urlsafe_b64encode(hashlib.sha256(cv.encode()).digest()).rstrip(b"=").decode()
state = secrets.token_urlsafe(32)

# 5. Loopback server to catch the redirect
result = {}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass  # silence
    def do_GET(self):
        qs = urllib.parse.urlparse(self.path).query
        params = dict(urllib.parse.parse_qsl(qs))
        result.update(params)
        body = b"<html><body><h2>Signed in. You can close this tab.</h2></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        threading.Thread(target=self.server.shutdown, daemon=True).start()

server = http.server.HTTPServer(("127.0.0.1", port), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()

# 6. Open the browser
auth_url = meta["authorization_endpoint"] + "?" + urllib.parse.urlencode({
    "response_type": "code", "client_id": client_id, "redirect_uri": redirect_uri,
    "scope": "mcp:read mcp:write", "state": state,
    "code_challenge": cc, "code_challenge_method": "S256",
})
print(f"Opening browser to: {auth_url}")
try: webbrowser.open(auth_url)
except Exception: print("Could not open browser automatically — open the URL manually.")

# Wait for callback (with 5 min timeout)
import time
deadline = time.time() + 300
while not result and time.time() < deadline:
    time.sleep(0.5)
server.shutdown()

if "error" in result:
    sys.exit(f"OAuth error: {result.get('error')} — {result.get('error_description','')}")
if result.get("state") != state:
    sys.exit("OAuth state mismatch — possible CSRF. Aborting.")
if "code" not in result:
    sys.exit("Timed out waiting for OAuth redirect.")

# 7. Exchange code for tokens
token_body = urllib.parse.urlencode({
    "grant_type": "authorization_code",
    "code": result["code"], "code_verifier": cv,
    "redirect_uri": redirect_uri, "client_id": client_id,
}).encode()
req = urllib.request.Request(meta["token_endpoint"], data=token_body,
    headers={"Content-Type": "application/x-www-form-urlencoded"})
tok = json.loads(urllib.request.urlopen(req, timeout=10).read())

# 8. Save config
import datetime
expires_at = datetime.datetime.utcnow() + datetime.timedelta(seconds=tok["expires_in"] - 30)
cfg["authMode"] = "oauth"
cfg["baseUrl"] = BASE
cfg.setdefault("oauth", {}).update({
    "clientId": client_id,
    "accessToken": tok["access_token"],
    "refreshToken": tok.get("refresh_token"),
    "tokenType": tok.get("token_type", "Bearer"),
    "expiresAt": expires_at.isoformat() + "Z",
    "scope": tok.get("scope"),
})
cfg_path.write_text(json.dumps(cfg, indent=2))
if os.name == "posix":
    os.chmod(cfg_path, 0o600)
print("OAuth login complete. Config saved.")
```

#### 0.d — OAuth token refresh (automatic)

When the access token is close to expiry, refresh silently:

```python
# altitude_oauth_refresh.py
import json, os, pathlib, urllib.parse, urllib.request, datetime, sys
home = pathlib.Path(os.environ.get("USERPROFILE") or os.environ["HOME"])
cfg = json.loads((home / ".altitude" / "config.json").read_text())
base = cfg["baseUrl"]
oa = cfg["oauth"]
body = urllib.parse.urlencode({
    "grant_type": "refresh_token",
    "refresh_token": oa["refreshToken"],
    "client_id": oa["clientId"],
}).encode()
req = urllib.request.Request(f"{base}/oauth/token", data=body,
    headers={"Content-Type": "application/x-www-form-urlencoded"})
try:
    tok = json.loads(urllib.request.urlopen(req, timeout=10).read())
except urllib.error.HTTPError as e:
    # Refresh failed (token revoked, expired) — caller should re-run full OAuth flow
    sys.exit(f"REFRESH_FAILED:{e.code}")
expires_at = datetime.datetime.utcnow() + datetime.timedelta(seconds=tok["expires_in"] - 30)
oa["accessToken"] = tok["access_token"]
if tok.get("refresh_token"):  # refresh rotation
    oa["refreshToken"] = tok["refresh_token"]
oa["expiresAt"] = expires_at.isoformat() + "Z"
(home / ".altitude" / "config.json").write_text(json.dumps(cfg, indent=2))
```

#### 0.e — Auth Mode 2: API Key (automation)

User pastes the key (it starts with `ak_live_` for production or `ak_test_` for dev).
Smoke-test with `GET {baseUrl}/api/v1/authenticate` — 200 means the key is valid. Save
with `authMode="api_key"`.

#### 0.f — Auth Mode 3: Direct JWT paste (fallback)

If the user already has a JWT (from the Altitude UI's browser session, for example), they
can paste it directly. Save with `authMode="jwt"` and `jwt=<token>`. This mode has no
refresh capability — when the JWT expires, prompt for a new paste or switch to OAuth.

#### 0.f.5 — DNS reachability test + loopback fallback

**Run this test at Step 0 before any API calls.** On some networks (corporate DNS,
split-horizon, DNS rebinding filters) `api.m62.live` fails to resolve via the system
resolver even though the service is reachable by IP. This has caused 100% of API calls
in the skill to fail with connection timeouts in prior runs.

```python
# altitude_dns_probe.py — run first, cache result
import socket, subprocess, json, os, pathlib, sys
def try_system_dns():
    try:
        ip = socket.gethostbyname("api.m62.live")
        return ("system", ip)
    except socket.gaierror:
        return None
def try_public_dns():
    for server in ("1.1.1.1", "8.8.8.8", "9.9.9.9"):
        try:
            out = subprocess.check_output(
                ["dig", f"@{server}", "api.m62.live", "+short", "+time=3"],
                text=True, timeout=5
            ).strip().splitlines()
            ips = [x for x in out if x and not x.startswith(";")]
            if ips: return ("public", ips[0])
        except Exception: pass
    return None

result = try_system_dns() or try_public_dns()
if not result:
    sys.exit("DNS: cannot resolve api.m62.live via any method. Check network/VPN/firewall.")

method, ip = result
home = pathlib.Path(os.environ.get("USERPROFILE") or os.environ["HOME"])
probe_file = home / ".altitude" / "dns_probe.json"
probe_file.parent.mkdir(exist_ok=True)
probe_file.write_text(json.dumps({"method": method, "ip": ip, "target": "api.m62.live"}))
print(f"DNS OK via {method}: {ip}")
```

**If `method == "system"`** → system DNS works, use normal Python `requests` or `curl`.

**If `method == "public"`** → system DNS is broken but public DNS has the IP. Every
subsequent API call must override. Two patterns:

1. **`curl` with `--resolve`** (simplest, reliable):
   ```bash
   curl --resolve "api.m62.live:443:<IP>" -H "X-API-Key: $KEY" "https://api.m62.live/api/v1/..."
   ```

2. **Python `requests` with connection patching** (cleaner for scripts):
   ```python
   # altitude_http.py
   import json, os, pathlib, requests
   from urllib3.util import connection
   home = pathlib.Path(os.environ.get("USERPROFILE") or os.environ["HOME"])
   probe = json.loads((home / ".altitude" / "dns_probe.json").read_text())
   if probe["method"] == "public":
       _orig = connection.create_connection
       def _patched(addr, *args, **kwargs):
           host, port = addr
           if host == "api.m62.live":
               addr = (probe["ip"], port)
           return _orig(addr, *args, **kwargs)
       connection.create_connection = _patched
   # Now use requests normally — DNS patching is transparent
   ```

On Windows with `curl.exe`, the same `--resolve` flag works. PowerShell's `Invoke-WebRequest`
does not support `--resolve`; use `curl.exe` or a Python script via PowerShell instead.

**Re-probe every hour** (IP can change). Cache the IP in `dns_probe.json` with a TTL check.

#### 0.g — Pick the right header per request

The skill's helper emits the correct header automatically based on `authMode`:

```python
# altitude_auth.py — load once, reuse everywhere
import json, os, pathlib, datetime
home = pathlib.Path(os.environ.get("USERPROFILE") or os.environ["HOME"])
cfg = json.loads((home / ".altitude" / "config.json").read_text())

def ensure_fresh():
    """Refresh OAuth token if within 5 minutes of expiry."""
    if cfg.get("authMode") != "oauth": return
    exp = datetime.datetime.fromisoformat(cfg["oauth"]["expiresAt"].rstrip("Z"))
    if exp - datetime.datetime.utcnow() < datetime.timedelta(minutes=5):
        import subprocess, sys
        subprocess.check_call([sys.executable, "altitude_oauth_refresh.py"])
        # reload
        global cfg
        cfg = json.loads((home / ".altitude" / "config.json").read_text())

def headers():
    ensure_fresh()
    mode = cfg.get("authMode", "api_key")
    if mode == "api_key":
        return {"X-API-Key": cfg["apiKey"]}
    if mode == "oauth":
        return {"Authorization": f"Bearer {cfg['oauth']['accessToken']}"}
    if mode == "jwt":
        return {"Authorization": f"Bearer {cfg['jwt']}"}
    raise RuntimeError(f"Unknown authMode: {mode}")

def base_url(): return cfg["baseUrl"]
def firm_name(): return cfg.get("firmName", "")
```

#### 0.h — Prompt the user to choose

If no usable config exists, ask:

> How should I authenticate to Altitude?
> 1. **OAuth (browser, recommended)** — I'll open Altitude's login page in your browser. You sign in there; I never see your password. I'll cache a short-lived access token + refresh token.
> 2. **API Key** (automation) — you paste an `ak_live_...` key. Good for CI or long-running integrations where no human is present.
> 3. **JWT paste** (fallback) — paste a JWT obtained from your existing Altitude browser session.

And: "Which environment? Production (`https://api.m62.live`) or Development (`http://localhost:8080`)?"

Then run the script for the chosen mode, save config, and proceed.

#### 0.i — Backwards compatibility

Config files without `authMode` but with `apiKey` set should be treated as `authMode=api_key`
for transparent upgrade. Write out an updated config with `authMode` set on the next run.

### Cross-Platform Setup

Detect the operating system and set platform-appropriate defaults. Do this ONCE at the start
and reuse throughout:

```python
import platform, shutil, os, tempfile

OS = platform.system()  # "Windows", "Darwin", "Linux"

# Python command
PYTHON = "python" if OS == "Windows" else "python3"

# Temp directory (NEVER hardcode /tmp/)
TMPDIR = tempfile.gettempdir()  # e.g., C:\Users\X\AppData\Local\Temp on Windows, /tmp on Unix

# Word doc converter
if shutil.which("textutil"):
    DOCX_CMD = "textutil -convert txt"          # macOS
elif shutil.which("pandoc"):
    DOCX_CMD = "pandoc -t plain -o"             # Cross-platform
else:
    DOCX_CMD = None  # Fall back to python-docx (see below)

# PDF decryptor
QPDF = shutil.which("qpdf")
# Install if missing:
#   macOS:   brew install qpdf
#   Windows: choco install qpdf  OR  winget install qpdf  OR  scoop install qpdf
#   Linux:   apt install qpdf    OR  dnf install qpdf
```

Save these values and use them for all subsequent commands. When this skill says `python3`,
use `PYTHON`. When it says `/tmp/`, use `TMPDIR`. When it says `textutil`, use `DOCX_CMD`.

### Full OpenAPI Spec

The full Altitude OpenAPI specification is available at `api-docs/api.json` relative to this
skill's directory. If you encounter an endpoint or schema not covered in the reference files,
search the full spec: `Glob pattern "**/m62-altitude-onboarding/**/api.json"` then use Grep
to find specific endpoints or schema definitions.

### Additional Requirements

- **firmId** (UUID) for the target firm — typically discovered during Phase 1 when querying Altitude

---

## Workflow Overview

```
Phase 0.5: External Sources    → Load firm-CRM / advisor-DB / custodian-API records as authoritative data
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

**Batching rules — split by subdirectory, then by count. Hard cap: 25 files per batch.**

1. **Group files by subdirectory** first. Each top-level folder in the household directory
   becomes a candidate batch (e.g., `Identification/`, `LLC/`, `Tax Documents/`,
   `Financial Statements/`, `Insurance/`, `Estate Planning/`).

2. **Cap every batch at 25 files.** Any group exceeding 25 gets split:
   - 26-50 files → 2 batches of ~18-25
   - 51-75 files → 3 batches of ~17-25
   - 76+ → more splits, 25-file cap
   Never let a single batch exceed 30 files — sub-agent context pressure becomes severe
   beyond that, and image-heavy PDFs compound the load.

3. **If a subdirectory has < 4 files**, merge it with another small directory into one batch.

4. **Target batch size**: 15-20 files is the sweet spot. Very small families (< 10 files
   total) use 1 batch; larger families get 5-10 batches running in parallel.

5. **Parallelism budget**: 5-8 concurrent agents is the default target. 10+ concurrent
   agents has hit output-size limits in practice; split into waves if needed.

6. **Imbalance is OK** — don't force-balance batches. A batch of 16 mixed files + a batch
   of 22 all-statements is fine. Grouping by document type (all statements together, all
   trust docs together) is more valuable than perfect file-count parity, because agents
   can apply type-specific heuristics (statement period parsing, trust role extraction).

**Historical precedent**:
- Family X (85 files) → 5 batches of 10-21 files, completed in ~9 minutes
- Family Y (215 files) → 8 batches of 16-37 files; the 37-file batch strained context and retried once. Cap of 25 would have prevented the retry.

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

## Phase 0.5: External-Source Preload (pluggable, run BEFORE Phase 1)

Many firms maintain authoritative client data **outside** the household document folder:
CRM exports, Salesforce / HubSpot databases, internal wealth-platform APIs, custodian
data feeds, partner-firm shared drives, or household-spreadsheet templates. Fields in
these sources (DOB, SSN, email, phone, billing rates, outside-advisor rosters) are often
**more complete and more canonical** than what lives in discovery-folder documents —
they're the firm's system of record.

Loading these BEFORE Phase 1 lets the skill treat their fields as authoritative
extraction records (with `asOfDate = source timestamp`), so Phase 4's latest-date-wins
resolution naturally favors them over stale PDFs.

### Rule — always check for external sources first

Before starting Phase 1, ask or auto-detect:

> Are there any firm-side authoritative data sources for this household that I should
> load before reading documents? Examples: CRM exports, Salesforce queries, an internal
> platform API, shared-drive spreadsheets maintained by the advisor team, custodian
> direct feeds, or a household intake spreadsheet.

If the user has one, connect it. If they don't, proceed directly to Phase 1.

### Source adapter interface

**External sources are pluggable — never hard-code "CSV" as the only shape.** Implement
a thin adapter per source type. Each adapter must produce the same shape so downstream
phases don't care where the data came from:

```python
# altitude_external_source.py — base protocol
from typing import Protocol, Iterable
from dataclasses import dataclass

@dataclass
class ExternalRecord:
    source_name: str          # "firm-crm", "salesforce", "advisor-platform-api", ...
    record_type: str          # "household" | "individual" | "contact" | "billing" | "entity" | "service_partner" | ...
    household_key: str        # normalized household identifier (name, external id, etc.)
    fields: dict              # flat dict of field -> value
    as_of_date: str           # ISO date — used for latest-date-wins
    provenance: dict          # {"file": "...", "row": 42, "url": "...", "query": "..."} — auditable

class ExternalSource(Protocol):
    def detect(self, household_folder: str, config: dict) -> bool: ...
    def load(self, household_folder: str, config: dict) -> Iterable[ExternalRecord]: ...
```

### Adapter catalog — known source types

| Source type | Example | Detection | Auth |
|---|---|---|---|
| **File-based CSV export** | Firm's `/Partner Share - Altitude/CRM/*.csv`, firm-drive "Client Masters" | Walk up from the household folder looking for `../../CRM/*.csv` or a configured `crm_paths`; hydrate files first (Step 2.0) | Filesystem ACL |
| **File-based spreadsheet intake** | Household onboarding worksheet (`Client Information Sheet.xlsx`) | Exists inside the household folder at `Onboarding/*.xlsx` with recognized tab names | Filesystem |
| **Firm internal API** | A `GET /crm/households/{name}` against the firm's platform | Config provides `crm_api_base` + `crm_api_key` | Bearer / API key |
| **Salesforce / HubSpot** | SOQL/REST query for matching Household account | Config provides OAuth tokens | OAuth |
| **Custodian direct feed** | Schwab/Fidelity client master, Addepar client export | Config provides custodian credentials | OAuth / API key |
| **Database (Postgres / BigQuery / etc.)** | Firm's internal client DB | Config provides connection string; query by last name | DSN / service account |
| **Another Altitude tenant** (partner-firm handoff) | Partner firm's cross-firm household export | Config provides source tenant + API key | API key |

Implementation strategy:

1. **Start with what you have**. For the firm today that's CSV. Implement
   `FirmCrmCsvSource` (4 CSVs: Client_Households_Export, Connections_Export,
   Leads_Export, Service_Partners_Export).
2. **Make the interface source-agnostic from day one** so adding `FirmApiSource` or
   `SalesforceSource` tomorrow doesn't require rewiring Phase 4.
3. **Cache provenance aggressively** — `ExternalRecord.provenance` should let Phase 5
   reviewers trace every field back to row 42 of that CSV or GET call XYZ.

### Field-mapping contract

Every adapter outputs normalized field names matching Altitude's DTO vocabulary, NOT the
external source's column names. This keeps Phase 4 simple — it doesn't need to know
that CRM calls SSN "Tax ID" and Salesforce calls it "tax_identifier". The adapter does
that translation.

Example — a firm CRM Client_Households_Export row maps to:

```python
ExternalRecord(
    source_name="firm-crm",
    record_type="individual",
    household_key="FamilyA",
    fields={
        "firstName": "Client", "lastName": "A",
        "dateOfBirth": "1980-01-15",
        "ssn": "000000000",                  # 9 digits, dashes stripped
        "email": "clienta@example.com",
        "phoneNumberPrimary": "5555550100",  # digits only
        "occupation": "Executive",
        "employerName": None,                # CRM says "Self-employed" — map to null, not a string
        "gender": None,                      # blank in CRM, will fill from DL in docs
    },
    as_of_date="YYYY-MM-DD",                 # CRM export date (mtime of source file)
    provenance={"source": "Client_Households_Export.csv", "row": 1,
                "path": "/Partner Share - Altitude/CRM/Client_Households_Export.csv"},
)
```

### Merging external records into the extraction cache

Phase 3's extraction cache (`extraction_cache.jsonl`) accepts one JSON line per
**document**. External records are conceptually similar — one line per **external row
or record**. Add them to the same cache with a synthetic "file" key so the rest of the
pipeline treats them uniformly:

```jsonl
{"file": "[external:firm-crm] Client_Households_Export.csv row 1", "readAt": "2026-04-22T12:00Z", "fileNumber": -1, "asOfDate": "2026-04-22", "entities": {"individuals": [{"name": "Client A", "dob": "1980-01-15", "ssn": "000000000", "_source_kind": "external_crm"}]}}
{"file": "[external:firm-crm] Service_Partners_Export.csv row 3", "readAt": "2026-04-22T12:00Z", "fileNumber": -2, "asOfDate": "2026-04-22", "contacts": [{"firstName": "External", "lastName": "Manager", "jobTitle": "Manager", "biography": "Management Firm X", "_source_kind": "external_crm"}]}
```

Negative `fileNumber` values mark external records so Phase 3M can filter/count them
separately from document extractions. `asOfDate` drives latest-date-wins (Rule 40).

### Billing, fees, team assignments

CRM / external sources are usually the **only** place where household-level billing
terms and firm-team assignments live — they don't appear in trust agreements or tax
returns. Always map these fields if the external source has them:

- `Household.billing.*` (feeStructure, feePercent, minimumFee, frequency, method)
- `Household.firmTeam` (AL Team, CP Team — FirmTeam assignment, NOT Contacts)
- Outside professionals roster (Service Partners) — these become Contacts via the same
  cross-doc dedup rules as document-sourced Contacts

### Security constraints

External sources commonly contain unredacted SSN, SIN, DOB, and billing data. Treat
with same discipline as Rule 9 (sensitive data):

1. Never log raw SSN or tax IDs — only the last 4 on trace logs.
2. Write external-source findings to `altitude_review/sensitive_data.json` if the source
   returned anything `critical` severity.
3. Memory-only for OAuth tokens / DSNs — the skill's auth helper (`altitude_auth`) is
   NOT the right place for firm-DB credentials; use separate `.altitude/external_sources/`
   config, same `chmod 600` rules.

### Phase 5 review additions

When external sources contributed, the review must have a dedicated section:

```markdown
## External-Source Contributions

Loaded before Phase 1:
- `firm-crm` (CSV): 4 files, 12 records (1 household, 1 individual, 5 contacts, 5 connections, 1 billing)
- (if present) `firm-api` (REST): 1 household query, 8 field updates

### Fields contributed by external sources (will be queued as auto-fills or latest-date-wins)

| Entity | Field | External Value | Source | asOfDate |
|--------|-------|---------------|--------|----------|
| Client A (Individual) | dateOfBirth | 1980-01-15 | firm-crm / Client_Households_Export.csv row 1 | YYYY-MM-DD |
| Client A (Individual) | ssn | ***-**-9754 | firm-crm / Client_Households_Export.csv row 1 | 2026-04-22 |
| Family A (Household) | billing.feeStructure | AUM_BASED | firm-crm / Client_Households_Export.csv row 1 | 2026-04-22 |
| External Manager (new Contact) | — | — | firm-crm / Service_Partners_Export.csv row 1 | 2026-04-22 |
```

This gives the RM a clear audit trail showing which fields came from firm-internal
records vs discovery documents.

---

## Phase 1: Query Altitude — Get Existing Household Universe

Before touching any documents, query Altitude to understand what already exists.

### API Response Shapes — READ THIS FIRST

Altitude endpoints return two different response shapes. Confusing them leads to silent bugs
(e.g. `len(resp) == 2` is the dict key count, not the item count).

| Endpoint pattern | Shape | Count extraction |
|---|---|---|
| `GET /api/v1/{entity}?size=N` (list) | `{"content":[], "page":{"totalElements":N,...}}` | `resp["page"]["totalElements"]` |
| `GET /api/v1/{entity}/search?searchFor=X` | Paginated wrapper (same) | same |
| `GET /api/v1/{entity}/by-individual/{id}` / `by-household/{id}` / `by-owner/{type}/{id}` | Paginated wrapper | same |
| `GET /api/v1/entity-relationship/from/{type}/{id}` / `/to/...` | **Bare JSON array** `[...]` | `len(resp)` |
| `GET /api/v1/household/{id}/relationships/from` | **Bare JSON array** | `len(resp)` |
| `GET /api/v1/{entity}/{id}` (single) | Bare JSON object | n/a |

**Write a universal parser** once and reuse:
```python
def items(resp):
    if isinstance(resp, list): return resp
    if isinstance(resp, dict) and "content" in resp: return resp["content"]
    return []

def total(resp):
    if isinstance(resp, list): return len(resp)
    if isinstance(resp, dict): return resp.get("page", {}).get("totalElements", len(resp.get("content", [])))
    return 0
```

### Graph-First Discovery Rule

Phase 1 discovery **starts from the household and traverses the relationship graph outward**.
Name-pattern search is a fallback — account names in Altitude are often generic ("Holding",
"Custody", "Quantinno") and won't match family-surname searches. Step 1.3 has the traversal
algorithm; Step 1.4 is a fallback for orphan accounts.

### Step 1.1: Search for the household

```
GET /api/v1/household/search?searchFor={household_name}&size=50
X-API-Key: {api_key}
```

or with JWT:

```
GET /api/v1/household/search?searchFor={household_name}&size=50
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

**Account graph traversal — DO NOT trust `household.totalAccountCount`.** In practice the
household count often exceeds the number of accounts reachable via direct
`HOUSEHOLD → ACCOUNT_FINANCIAL` relationships, because most accounts hang off trusts and
LLCs, not the household itself. In a $1.22B household with 48 accounts, fewer than a
dozen were directly owned by the household — the rest were inside trust/LLC sub-graphs.

**Traversal algorithm** (implement this before moving past Phase 1):

```python
# altitude_account_graph.py — recursively discover all accounts reachable from household
visited_entities = set()   # (entity_type, entity_id) pairs we've already expanded
all_accounts = {}          # account_id -> basic info

def expand(entity_type, entity_id):
    key = (entity_type, entity_id)
    if key in visited_entities: return
    visited_entities.add(key)
    rels = api_get(f"/api/v1/entity-relationship/from/{entity_type}/{entity_id}")
    for r in rels:
        if r["targetEntityType"] == "ACCOUNT_FINANCIAL":
            all_accounts[r["targetEntityId"]] = {
                "id": r["targetEntityId"],
                "name": r["targetEntityName"],
                "ownerType": entity_type,
                "ownerId": entity_id,
                "ownerName": "<look up from existing cache>",
            }
        elif r["targetEntityType"] in ("LEGAL_ENTITY", "INDIVIDUAL"):
            expand(r["targetEntityType"], r["targetEntityId"])  # recurse

expand("HOUSEHOLD", household_id)
```

This expands Household → its individuals and legal entities → each of their
outgoing relationships → any sub-LEs they hold → all the way down to every leaf
ACCOUNT_FINANCIAL. The number of accounts discovered should match or exceed
`household.totalAccountCount`. If the discovered count is LOWER, flag as open question
(the household counter may include hard-deleted or orphan accounts).

**Account search fallback** — some accounts may not be wired into the relationship graph
(orphan accounts created directly). Also search by household name tokens AFTER graph
traversal to catch these:

```
GET /api/v1/account-financial/search?searchFor={householdNameToken}&size=100
```

For each individual in the household:
```
GET /api/v1/individual/{id}
```

For each legal entity in the household:
```
GET /api/v1/legal-entity/{id}
```

For each account discovered via the traversal above:
```
GET /api/v1/account-financial/{id}
```

For each contact in the household:
```
GET /api/v1/contact/{id}
```

**⚠ Endpoint-choice warning** — For TangibleAsset / Liability / InsurancePolicy,
two forms exist per entity:
- `/{entity}/by-individual/{id}`, `/by-household/{id}`, `/by-legal-entity/{id}` — read
  the direct FK column only; **does NOT traverse entity relationships**. An asset owned
  only via an OWNERSHIP relationship (no FK set) is invisible to these endpoints.
- `/{entity}/by-owner/{ENTITY_TYPE}/{id}` — traverses the entity-relationship graph.
  Returns a strict superset of the FK-only endpoint.

**Availability matrix (verify at run-time via `OPTIONS` probe or by-individual fallback):**

| Entity | `/by-owner/{TYPE}/{id}` | `/by-individual` | `/by-household` | `/by-legal-entity` |
|---|---|---|---|---|
| tangible-asset | ✅ (since launch) | — | ❌ (use /by-owner/HOUSEHOLD) | — |
| liability | ✅ (PR "backend consistency", 2026-04-23) | ✅ | ✅ | ✅ |
| insurance-policy | ✅ (PR "backend consistency", 2026-04-23) | ✅ | ✅ | ✅ |

**Always use `/by-owner/{TYPE}/{id}` for Phase 1 discovery** after the 2026-04-23 PR is
deployed to your target environment. On older builds (pre-PR), the endpoint returns 404
for `liability` and `insurance-policy` — fall back to the three narrower endpoints. Code
defensively with an error-shape-aware parser:

```python
def items(resp):
    if isinstance(resp, dict) and resp.get("status", 0) >= 400:
        raise RuntimeError(f"API error: HTTP {resp['status']} — {resp.get('detail', resp)}")
    if isinstance(resp, list): return resp
    if isinstance(resp, dict) and "content" in resp: return resp["content"]
    return []
```

The skill's legacy `len(resp)` / `resp.get('content', resp)` patterns will silently
interpret a 404 JSON body (`{"status":404, "detail":..., ...}`) as a page of 7 items
(the dict's key count) — this was observed on the recent production run. Always guard
on `status >= 400` first.

```
GET /api/v1/tangible-asset/by-owner/INDIVIDUAL/{individualId}
GET /api/v1/tangible-asset/by-owner/LEGAL_ENTITY/{legalEntityId}
GET /api/v1/tangible-asset/by-owner/HOUSEHOLD/{householdId}

GET /api/v1/liability/by-owner/INDIVIDUAL/{individualId}
GET /api/v1/liability/by-owner/HOUSEHOLD/{householdId}

GET /api/v1/insurance-policy/by-owner/INDIVIDUAL/{individualId}
GET /api/v1/insurance-policy/by-owner/LEGAL_ENTITY/{legalEntityId}
GET /api/v1/insurance-policy/by-owner/HOUSEHOLD/{householdId}
```

Store all of this as the **"Altitude Universe"** — the complete current state of the
household in Altitude. This is the baseline for comparison.

### Step 1.4: Search for accounts and contacts by name

Additionally, search for any accounts and contacts by name pattern. **Per Rule 67,
all entity searches that DO support `parentHouseholdId` MUST pass it** (account search
included). Contact search is firm-wide by design.

```
GET /api/v1/account-financial/search?searchFor={account_name_pattern}&parentHouseholdId={hh_id}&size=50
GET /api/v1/contact/search?searchFor={contact_name_pattern}&size=50  # firm-wide; apply per-result graph filter
```

### Step 1.4b: Rollup health check (Rule 68)

`GET /api/v1/household/{id}` rollup fields (`primaryIndividualName`, `totalAccountCount`,
`totalMarketValue`, `totalTangibleAssetValue`) may be NULL even when the household has
populated entities — they are computed by a nightly job. Build authoritative counts
from the per-type list endpoints scoped to `parentHouseholdId`, NOT from the
household rollup:

```python
counts = {
  "individuals":      total(api_get(f"/individual?parentHouseholdId={hh_id}&size=1")),
  "legal_entities":   total(api_get(f"/legal-entity?parentHouseholdId={hh_id}&size=1")),
  "accounts":         total(api_get(f"/account-financial?parentHouseholdId={hh_id}&size=1")),
  "tangible_assets":  total(api_get(f"/tangible-asset?parentHouseholdId={hh_id}&size=1")),
  "liabilities":      total(api_get(f"/liability?parentHouseholdId={hh_id}&size=1")),
  "insurance":        total(api_get(f"/insurance-policy?parentHouseholdId={hh_id}&size=1")),
}
```

If `/household/{id}` rollups disagree with the per-type counts, log a "rollup
staleness" warning to surface in the Phase 5 review.

### Step 1.5: Lookup-by-prior-UUID pass (only on rerun) — Rule 69

If `run_state.json` exists from a prior run, before proceeding to Phase 2, GET
every UUID in `run_state.entities.*` with `?scope=ALL_TENANTS` and classify each
into one of four buckets that map directly to the `classification` field of
`stale_prior_uuids.json` (see deliverable below):

| # | Bucket | Lookup result | `classification` value | Recovery action |
|---|--------|--------------|------------------------|-----------------|
| (a) | **live_in_universe** | found AND in current universe | `live` (NOT stale — do not write to file) | none — expected steady state |
| (b) | **orphan_since_prior_run** | found AND NOT in current universe | `orphan` (NOT stale in the deletion sense — write under a separate `orphans[]` key for Phase 6 OWNERSHIP wiring) | re-wire via Phase 6 OWNERSHIP edges |
| (c) | **soft_deleted** | returns row with `deleted: true` only when `?includeDeleted=true&scope=ALL_TENANTS` | `soft_deleted` | record in `run_state.softDeletedAwaitingHardDelete[]` per Rule 66; fleet aggregator schedules admin hard-delete |
| (d) | **hard_deleted** | 404 even with `?scope=ALL_TENANTS&includeDeleted=true` | `hard_deleted` | remove the UUID from `run_state.entities.*` so the next run does not retry the lookup |

If the lookup result is ambiguous (e.g. transient 5xx, network timeout, scope
mismatch the skill cannot disambiguate), classify as `unknown` and surface in the
Phase 5 review for the user — do not silently treat as hard-deleted.

This catches prior-run-created entities invisible to the standard graph traversal.

#### Deliverable — `stale_prior_uuids.json`

The skill MUST write `{household_folder}/altitude_review/stale_prior_uuids.json`
at the end of Step 1.5 — even on a fresh run with zero prior UUIDs and even when
zero stale UUIDs are found. The fleet aggregator that runs after the family runs
relies on the file's presence to confirm Step 1.5 executed; an absent file is
treated as "Step 1.5 was skipped" and triggers a rerun. Same convention as
`cross_contamination_findings.json` (Rule 71) and `backend_enum_gaps.json`
(Rule 72).

Schema (one entry per stale — buckets (c) and (d) — UUID; bucket (a) is omitted;
bucket (b) orphans live under `orphans[]`):

```json
{
  "household": "<name>",
  "household_id": "<uuid>",
  "stale_uuids": [
    {
      "uuid": "5ef14ddc-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "prior_label": "feedTheFuture",
      "prior_run": "2026-04-15-run-12",
      "lookup_status": "404_with_scope_ALL_TENANTS",
      "classification": "hard_deleted",
      "fleet_aggregator_action": "remove_from_run_state"
    }
  ],
  "orphans": [
    {
      "uuid": "<uuid>",
      "prior_label": "<label from run_state>",
      "prior_run": "<date or run-id>",
      "lookup_status": "200_found_outside_universe",
      "classification": "orphan",
      "fleet_aggregator_action": "schedule_phase6_ownership_wire"
    }
  ]
}
```

Empty-result form (still required):

```json
{"household": "<name>", "household_id": "<uuid>", "stale_uuids": [], "orphans": []}
```

`prior_label` is the key under `run_state.entities.*` that pointed to the UUID
(e.g. `legalEntities.feedTheFuture`). `prior_run` is the prior `run_state.runId`
or the prior `run_state.completedAt` date — whichever the prior file recorded.

#### Rule 69 — Lookup prior-run UUIDs and emit `stale_prior_uuids.json`

On every rerun, before Phase 2, the skill MUST resolve every UUID in the prior
`run_state.entities.*` against `?scope=ALL_TENANTS` (with `includeDeleted=true`
for the soft-delete probe), classify each as `live` / `orphan` / `soft_deleted` /
`hard_deleted` / `unknown`, and write the stale and orphan UUIDs to
`altitude_review/stale_prior_uuids.json`. The file is mandatory — empty schema
must still be written when zero stale or orphan UUIDs are found, so the fleet
aggregator can reliably read it. Soft-deleted UUIDs are also added to
`run_state.softDeletedAwaitingHardDelete[]` per Rule 66; hard-deleted UUIDs are
removed from `run_state.entities.*` before Phase 2 begins.

### Step 1.5b: Build the Altitude Universe index

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

### Step 1.6: Externally-synced-account health check (IMMEDIATE ALERT — do not defer to Phase 4.8)

As soon as the universe is built, scan all accounts for broken external syncs BEFORE
launching extraction agents. The user needs to see this up-front so they can open a
parallel sync-health ticket while the onboarding runs.

```python
# altitude_sync_health.py
broken = []
for acct in universe["accounts"]:
    ext_ids = acct.get("externalIds") or []
    has_provider = any(e.get("provider") for e in ext_ids)
    mv = acct.get("totalMarketValue")
    last_synced = next((e.get("lastSyncedAt") for e in ext_ids if e.get("provider")), None)
    if has_provider and (mv is None or float(mv) == 0 or last_synced is None):
        broken.append({
            "id": acct["id"], "name": acct["name"], "mv": mv,
            "providers": [e.get("provider") for e in ext_ids],
            "lastSyncedAt": last_synced,
        })

if broken:
    print("⚠ WARNING — accounts with broken/zero external sync (do NOT patch these):")
    for b in broken: print(f"  {b}")
    # Persist to altitude_review/addepar_discrepancies_preextraction.json
```

Rule 42 (externally-synced accounts are read-only) still applies during extraction. The
Phase 1 early alert is additive — it surfaces the problem to the operator so they can
(a) open a sync-health ticket in parallel, and (b) expect extraction to flag the account
as "needs investigation" rather than "broken due to onboarding script."

---

## Phase 2: Scan & Classify Documents

### Step 2.0: OneDrive / cloud-sync hydration pre-scan (REQUIRED before spawning agents)

OneDrive, Dropbox, iCloud and Box store files as "dataless placeholders" until accessed —
reading one triggers a download. In extraction sub-agents, a cloud-stub read times out
after tens of seconds (default socket timeout), wasting compute. Detect unhydrated files
**before** spawning agents and report them to the user for bulk hydration in Finder/Explorer
before the expensive extraction runs.

```python
# altitude_hydration_scan.py
#
# IMPORTANT: do NOT use `dd bs=1 count=1` as the stub probe. On OneDrive/macOS
# an attribute lookup for a 1-byte read blocks for seconds even on already-
# hydrated files — a 3-second threshold mis-flags nearly every file as a stub
# (16x false-positive rate observed on recent run).
#
# Correct probe: attempt an actual 4 KB read through Python with a signal
# timeout (POSIX) or a daemon thread join (Windows). Hydrated files return in
# < 10 ms; real cloud stubs either time out or raise OSError 60 ("Operation
# timed out").
import os, platform, signal, sys, threading
from pathlib import Path

HOUSEHOLD = sys.argv[1]              # absolute path to household folder
HYDRATION_TIMEOUT_SECS = 30          # ceiling for first-time hydration on slow links

class _Timeout(Exception): pass

def is_cloud_stub(path: str, timeout_secs: int = HYDRATION_TIMEOUT_SECS) -> bool:
    """True only if the file truly fails to hydrate within `timeout_secs`."""
    result = {"ok": False}

    def _read():
        try:
            with open(path, "rb") as f: f.read(4096)
            result["ok"] = True
        except Exception: pass  # treat any read error as a stub

    if platform.system() == "Windows":
        t = threading.Thread(target=_read, daemon=True); t.start(); t.join(timeout_secs)
        return not result["ok"]
    def _on_alarm(sig, frame): raise _Timeout()
    old = signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(timeout_secs)
    try: _read()
    except _Timeout: return True
    finally: signal.alarm(0); signal.signal(signal.SIGALRM, old)
    return not result["ok"]

stubs = []
for root, _, files in os.walk(HOUSEHOLD):
    if "altitude_review" in root: continue
    for f in files:
        if f.startswith(".DS_Store"): continue
        p = os.path.join(root, f)
        if is_cloud_stub(p): stubs.append(p)

if stubs:
    print(f"❌ {len(stubs)} cloud-stub files detected (read times out):")
    for s in stubs: print(f"  {s}")
    print()
    print("TO HYDRATE (macOS Finder):")
    print("  Right-click the folder(s) containing these files → 'Always Keep on This Device'")
    print("TO HYDRATE (Windows Explorer):")
    print("  Right-click → 'Always keep on this device'")
    print("After hydration (green circle icons), re-run the scan.")
    sys.exit(2)
else:
    print(f"✅ All files hydrated. Safe to proceed with extraction.")
```

**If stubs are found**: present the list to the user in a compact form (grouped by
parent directory, counts), ask them to hydrate, then **re-run this scan** before
proceeding. Do NOT launch extraction agents if any unhydrated files remain — they
will consume hundreds of seconds of agent time timing out on reads.

**If all files are hydrated**: proceed to the file cache check, then document classification.

### Step 2.05: Incremental-Run File Cache (skip-already-seen)

**Goal**: on a rerun, do not re-extract files whose content hasn't changed since the last
successful extraction. Saves substantial time for large households and avoids burning tokens
on repeat OCR of 100-page trust agreements.

Maintain a persistent cache at `{household_folder}/altitude_review/file_cache.json`:

```json
{
  "version": 1,
  "lastRunAt": "2026-04-21T18:40:00Z",
  "files": {
    "Onboarding/Trust Agreement.pdf": {
      "mtime": "2025-05-06T14:22:00Z",
      "size": 2457123,
      "sha256": "a1b2c3...",
      "extractedAt": "2026-04-21T18:05:12Z",
      "cacheLineNumbers": [23],
      "status": "READ"
    }
  }
}
```

**Cache-hit rule** — a file can be SKIPPED if and only if ALL three hold AND `force` is OFF:
1. The path exists in `file_cache.json`.
2. Current `mtime` and `size` match the cached values exactly **OR** `sha256` matches.
3. The cache's `cacheLineNumbers` references still exist in `extraction_cache.jsonl` and
   parse correctly.

**Cloud-sync caveat** (OneDrive / Dropbox / iCloud / Box): filesystem `mtime` can change
without file content changing when cloud sync touches the file. Prefer `sha256` as the
primary cache key when running against a cloud-synced folder. Fall back to `mtime+size` only
when sha256 computation is prohibitively slow.

**Force mode** — bypasses the cache and re-reads every file, overwriting cache entries with
fresh extraction. Supported invocations:
- `force=true` / `--force` / `no-cache=true` — bypass cache for all files
- `force=<glob>` — bypass cache for matching paths only (e.g. `force=Tax/**/*.pdf`)

Use force mode when:
- The extraction logic has changed (new entity types, new rules, new checklist items)
- The skill has been updated and you want to re-run with the new prompts
- You suspect prior extraction missed data (OCR was incomplete)
- The user explicitly asks to re-extract or reprocess

Default: `force=false`. Log each file as `SKIPPED (cache hit)` or `READ (force=true, cache
bypassed)` in the tracker.

**Orchestrator snippet** (run before spawning extraction agents):

Write `file_cache_scan.py` and run `{PYTHON} file_cache_scan.py` (Cross-Platform Setup):

```python
# file_cache_scan.py
import hashlib, json, os, pathlib, sys
from datetime import datetime, timezone

household_folder = sys.argv[1]
force = (len(sys.argv) > 2 and sys.argv[2] in ("true", "--force", "no-cache"))
force_paths = sys.argv[3:]  # optional glob patterns

def sha256_file(p, chunk=1024*1024):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(chunk), b""): h.update(b)
    return h.hexdigest()

review_dir = pathlib.Path(household_folder) / "altitude_review"
review_dir.mkdir(exist_ok=True)
cache_path = review_dir / "file_cache.json"
cache = {"version": 1, "files": {}}
if cache_path.exists():
    cache = json.loads(cache_path.read_text())

to_process, to_skip = [], []
for root, _, files in os.walk(household_folder):
    if "altitude_review" in root: continue
    for fn in files:
        if fn.startswith(".DS_Store"): continue
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, household_folder).replace(os.sep, "/")
        st = os.stat(full)
        current_mtime = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat()
        entry = cache["files"].get(rel)
        force_this = force or any(pathlib.PurePath(rel).match(p) for p in force_paths)
        if (not force_this and entry and entry.get("size") == st.st_size and
                (entry.get("sha256") == sha256_file(full) or entry.get("mtime") == current_mtime)):
            to_skip.append(rel)
        else:
            to_process.append(rel)

print(json.dumps({"process": to_process, "skip": to_skip, "force": force}))
```

Pass `process` to the extraction agents. Pre-populate `file_tracker.md` with one row per
`skip` file: `| N | path | SKIPPED (cache hit) | (see extraction_cache line K) |`. After
extraction agents complete, update `file_cache.json` with the new mtime/sha256/extractedAt
for each processed file.

### Step 2.1: Classify Documents

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
  with personal notes, **generic LLM/schema templates with no populated family data**
  (see Generic-Template Detection heuristic in `references/document_type_patterns.md`)

**Document-to-entity association** — each document maps to an entity type for upload:
Read `references/document_entity_association.md` for the complete mapping of which
document types associate with which Altitude entity type and what `documentSubType`
to use.

---

## Phase 3: Extract Entities from Documents

### PDF Reading — TEXT-FIRST by default

**⚠ CRITICAL: Do NOT start with Claude's Read tool on PDFs.** Claude's Read tool rejects
images with any dimension >2000px, and many scanned PDFs (trust documents, deeds,
handwritten notes, high-res scans) include pages that trip this limit. The result is
`"image exceeds 2000px dimension limit"` errors that abort whole extraction batches.

**Required reading order for every PDF**:

1. **Text-first via `pdftotext`** (poppler) — works on any PDF with embedded text:
   ```bash
   pdftotext -layout -nopgbrk "file.pdf" - | head -c 200000 > /tmp/extracted.txt
   ```
   Then Read `/tmp/extracted.txt`. This is fast, safe, and avoids the image limit entirely.

2. **If `pdftotext` returns mostly blank or gibberish** → the PDF is a scan. Render each
   page to a PNG first:
   ```bash
   # Render pages 1-5 at 200 dpi, cap long side via -scale-to 1800 so Claude can read
   pdftoppm -r 200 -scale-to 1800 -f 1 -l 5 "file.pdf" /tmp/scan_page -png
   ```

   Then choose the OCR path based on content type:

   **2a. Handwritten content** (meeting notes, signed statements, margin annotations) →
   **use Claude's Read tool on each PNG directly**. Claude vision handles cursive,
   mixed-case, and arrows/margin marks fluently; tesseract does not. In practice
   tesseract on handwriting returns word-salad ("hy borotvw , 2p 7. vf shaves") while
   Claude transcribes the same page accurately. Skip tesseract entirely for handwriting.

   **2b. Typeset scanned text** (faxed letters, older trust documents printed and
   re-scanned, filings) → tesseract is reliable and much cheaper than vision:
   ```bash
   for png in /tmp/scan_page-*.png; do
     tesseract "$png" "${png%.png}" -l eng --psm 6
   done
   cat /tmp/scan_page-*.txt > /tmp/extracted.txt
   ```
   Then Read `/tmp/extracted.txt`. If tesseract output looks garbled (low confidence,
   nonsense words, missing punctuation), fall back to Claude Read on the PNGs.

3. **Only fall back to Claude's Read tool on the raw PDF** as a last resort — and only if
   the file is **< 5 MB** (to avoid loading many high-res pages). If Read fails with the
   2000px error, mark the file `status=FAILED_IMAGE_TOO_LARGE` in the tracker and move on.
   Do not loop.

**Use `pypdf` for page-index scanning** — this is still the best way to find the data-rich
pages in a 200-page tax return without loading every page's content:

### Large PDF Strategy (20+ pages)

Tax returns and combined statements are often 50-200+ pages. Reading only the first few pages
will miss K-1 summaries, W-2s, 1099s, Schedule H, and passthrough entity details buried deep
in the document. Use this two-pass strategy, **built on the text-first foundation above**:

**Pass 1 — Page Index Scan** (fast, text-only):

Use `PYTHON` from the Cross-Platform Setup section for all Python invocations.
On Windows, write multi-line scripts to a temp `.py` file instead of using `-c` to
avoid shell quoting issues.

```python
# page_scan.py — write this to a temp file, then run: python page_scan.py
import sys
from pypdf import PdfReader
reader = PdfReader(sys.argv[1])
print(f'Total pages: {len(reader.pages)}')
for i, page in enumerate(reader.pages):
    text = (page.extract_text() or '')[:150].replace('\n', ' | ')
    print(f'  Page {i+1}: {text}')
```

Run: `{PYTHON} page_scan.py "file.pdf"` (where `{PYTHON}` is `python` on Windows and `python3` on macOS/Linux, per Cross-Platform Setup above).

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
For each flagged page, extract text with `pdftotext -f N -l N "file.pdf"` (where N is the
page number) to a temp file and Read that. Only use Claude's Read tool on the original PDF
for the flagged pages if `pdftotext` returns empty for that specific page (indicating a
scanned page). For a typical 200-page return, you'll usually need to read 15-25 key pages.

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
qpdf --password=PASSWORD --decrypt input.pdf decrypted.pdf
```
Write the decrypted file to the same directory as the input, or to a temp directory
(use Python `tempfile.mkdtemp()` if needed — do NOT hardcode `/tmp/`).

If `qpdf` is not installed:
- **macOS**: `brew install qpdf`
- **Windows**: `choco install qpdf` or `winget install qpdf` or `scoop install qpdf`
- **Linux**: `apt install qpdf` or `dnf install qpdf`

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
- **Word docs (.docx)**: Convert using the platform's `DOCX_CMD` (see Cross-Platform Setup).
  Fallback chain: `textutil` (macOS) → `pandoc` (cross-platform) → `python-docx` (write a
  `docx_read.py` script — see Standard Document Extraction below for the exact script).
  If all fail, flag for user — don't silently skip.
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
| 1 | Identification/DL.png | READ | Client B, Spouse B, DOBs, addresses |
| 2 | LLC/Operating Agreement.pdf | READ | Members: Client B 60%, Spouse B 40% |
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

#### ⛔ STRICT SCHEMA RULE — ONE JSON OBJECT PER LINE, ONE LINE PER FILE

**Every line in the JSONL file MUST be a single valid JSON object with at minimum these
required top-level keys**: `file`, `fileNumber`, `readAt`, `entities`.

**Forbidden**:
- Splitting one file's data across multiple lines (no "Dan as Individual on line 5, Dan's
  trust as LegalEntity on line 6"). All entities/relationships/contacts extracted from a
  single file belong on the SAME line as nested arrays under `entities`.
- Concatenating multiple JSON objects on one line without a newline between them.
- Pretty-printed multi-line JSON.

**Orchestrator MUST validate** each batch file after the extraction agent completes, before
merging. If validation fails, respawn a repair agent for that batch with stricter prompts.

```python
# validate_jsonl.py — run after each batch completes, before merge
import json, pathlib, sys
def validate_jsonl(path):
    errors = []
    with open(path) as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line: continue
            try:
                obj = json.loads(line)
            except Exception as e:
                errors.append(f"Line {i}: invalid JSON ({e})")
                continue
            for key in ("file", "fileNumber", "entities"):
                if key not in obj:
                    errors.append(f"Line {i}: missing required key '{key}'")
            if "entities" in obj and not isinstance(obj["entities"], dict):
                errors.append(f"Line {i}: 'entities' must be a dict")
    return errors

for batch in sorted(pathlib.Path(sys.argv[1]).glob("extraction_cache_batch_*.jsonl")):
    errs = validate_jsonl(batch)
    print(f"{'FAIL' if errs else 'OK'} {batch.name}: {errs[:5] if errs else ''}")
```

Each line captures everything extracted from a single file:

```jsonl
{"file": "Identification/DL.png", "readAt": "2026-03-19T22:00:00Z", "fileNumber": 1, "entities": {"individuals": [{"name": "Client B", "dob": "1985-06-01", "gender": "M", "dlNumber": "XXXXXXXXX", "dlState": "FL", "dlExpiry": "2031-06-01", "address": "123 Main Street, City, ST 00000"}]}, "relationships": [], "contacts": [], "accounts": [], "notes": "Both Client B and Spouse B DLs on same image"}
{"file": "LLC/OperatingLLC/Operating Agreement.pdf", "readAt": "2026-03-19T22:01:00Z", "fileNumber": 2, "entities": {"legalEntities": [{"name": "Operating LLC X1", "type": "LLC", "managementType": "MEMBER_MANAGED", "opAgreementDate": "2022-09-29"}]}, "relationships": [{"source": "Client B", "target": "Operating LLC X1", "type": "OWNERSHIP", "percentage": 50, "role": "Managing Member"}], "contacts": [{"name": "Registered Agent Name", "role": "Registered Agent", "address": "456 Agent Way, City, ST 00000"}], "accounts": [], "notes": "Principal: 123 Main Street"}
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

**On resume**, check for existing cache (use `os.path.join` for cross-platform paths):
```python
import json, os
cache_path = os.path.join('altitude_review', 'extraction_cache.jsonl')
existing = []
try:
    with open(cache_path) as f:
        existing = [json.loads(line) for line in f if line.strip()]
    last_file = max(e['fileNumber'] for e in existing)
    print(f"Resuming from file {last_file + 1} ({len(existing)} files already cached)")
except FileNotFoundError:
    print("No cache found, starting fresh")
```

### Standard Document Extraction

For each Tier 1 and Tier 2 document, extract structured data. Use Claude's native tools:

- **PDFs**: Use Claude Read tool natively (supports text and scanned PDFs with vision)
> **Windows note**: Do NOT use `python -c "..."` with embedded newlines or nested quotes.
> Windows cmd and PowerShell mangle multi-line argv strings and single-quote escaping
> differently from bash. The cross-platform pattern is: **write the script to a temp `.py`
> file with the `Write` tool, then run it as `python script.py`**. This avoids every
> shell-quoting pitfall on every OS. All snippets below use this pattern.

- **Word docs (.docx)**: Use the platform's `DOCX_CMD` (see Cross-Platform Setup):
  - macOS: `textutil -convert txt file.docx` then read the `.txt`
  - Cross-platform: `pandoc file.docx -t plain` (pipe or redirect output)
  - Python fallback (works everywhere): write `docx_read.py` below, then `python docx_read.py "file.docx"`

```python
# docx_read.py
import sys
from docx import Document
for p in Document(sys.argv[1]).paragraphs:
    print(p.text)
```
  Install `python-docx` if needed: `pip install python-docx`
- **Images (.jpg, .png)**: Use Claude Read tool — Claude can see images natively (multimodal)
- **Spreadsheets (.xlsx)**: Write `xlsx_read.py` below, then `python xlsx_read.py "file.xlsx"`. Install if needed: `pip install openpyxl`

```python
# xlsx_read.py
import sys, openpyxl
wb = openpyxl.load_workbook(sys.argv[1], data_only=True)
for sheet in wb.sheetnames:
    ws = wb[sheet]
    print(f"=== {sheet} ({ws.max_row} rows x {ws.max_column} cols) ===")
    for row in ws.iter_rows(values_only=True):
        print(row)
```

- **Emails (.eml)**: Write `eml_read.py` below, then `python eml_read.py "file.eml"`. Extract entity data from the email body (e.g., account confirmations, policy updates, advisor correspondence).

  **⛔ Attachment rule — DO NOT mark the .eml READ until every attachment has been
  processed as its native file type.** The .eml body is often a short cover note
  ("Christine – attached is the draft trust, please review") while the attachments
  contain the real data (the actual trust agreement, the signed engagement letter, the
  K-1 schedules). Missing an attachment = missing an entity.

  Required tracker handling:
  1. Count `msg.walk()` parts with a filename. Log each as a sub-file (`5a`, `5b`, `5c`).
  2. After saving, classify each attachment by extension and process via the same rules
     (PDF → pdftotext → extraction; DOCX → pandoc → extraction; JPG/PNG → Claude Read).
  3. Mark the parent .eml READ **only after** every sub-file is READ.
  4. If `sum(attachment_sizes) > 0.5 * body_size` OR any attachment is a PDF/DOCX/XLSX
     and the orchestrator is about to move on without processing it → HARD STOP, process
     attachments first.

```python
# eml_read.py — prints headers + body, saves attachments to temp dir
import email, os, sys, tempfile
with open(sys.argv[1], 'rb') as f:
    msg = email.message_from_binary_file(f)
for h in ('From', 'To', 'Date', 'Subject'):
    print(f"{h}: {msg[h]}")
att_dir = os.path.join(tempfile.gettempdir(), 'eml_attachments')
os.makedirs(att_dir, exist_ok=True)
for part in msg.walk():
    ctype = part.get_content_type()
    if ctype == 'text/plain':
        body = part.get_payload(decode=True)
        if body:
            print(body.decode(errors='replace'))
    fn = part.get_filename()
    if fn:
        out_path = os.path.join(att_dir, fn)
        with open(out_path, 'wb') as out:
            out.write(part.get_payload(decode=True))
        print(f"Saved attachment: {out_path}")
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
- Profession: occupation, employerName (DTO field is `employerName`, NOT `employer` —
  PATCHing `{employer: "..."}` is silently dropped), jobTitle

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

### Step 3.4: Sensitive Data Detection (mandatory, first-class artifact)

**Before merging extraction caches, scan for sensitive data that must NEVER enter API
payloads or the main extraction cache.** This includes:

- Credit card numbers (PCI DSS)
- Plaintext passwords / passphrases
- Social media / banking login credentials
- Full SSNs in document body text (outside structured extraction fields)
- Passport numbers, driver's license numbers beyond the structured DL fields
- Wire/ACH routing + account number pairs for unrelated parties
- Private encryption keys or API tokens pasted into documents

**Write a separate artifact**: `altitude_review/sensitive_data.json` — lists every
finding with file, a short description, and a redaction recommendation. This artifact
is visible to the user in the review but is **NEVER merged into `create_payloads.json`,
`extraction_cache.jsonl`, or any API-facing file**.

**Schema**:
```json
[
  {
    "id": 1,
    "file": "Onboarding/Fischer Travel Participation Agreement.pdf",
    "fileNumber": 14,
    "type": "credit_card",
    "description": "Visa ending 9115, expiry 9/29, CVV visible",
    "recommendation": "Rotate card immediately. Redact before uploading document OR upload only the redacted version. Never store in any Altitude field.",
    "severity": "high"
  },
  {
    "id": 2,
    "file": "Family Office/FO Tracker/SRB SIN PW.pdf",
    "type": "credential",
    "description": "Social Insurance Number password (Canadian SIN auth)",
    "recommendation": "Move to password manager (1Password/Bitwarden). Do not upload raw file to Altitude.",
    "severity": "high"
  }
]
```

**Severity levels**:
- `critical` — PCI data (credit cards), plaintext banking passwords → warn user explicitly in Phase 5 review
- `high` — passport #s, SIN passwords, full SSN in body text → flag for redaction
- `medium` — partial credentials, personal-notes-with-secrets → flag, low action required
- `low` — reference notes, flagged for awareness

**Extraction agents must emit sensitive findings to this artifact, NOT to notes or
entity fields.** Each batch writes its own `sensitive_data_batch_{N}.json` which the
orchestrator merges.

**In Phase 5 review**, include a dedicated "Sensitive Data Found" section at the top
(above normal entity updates) so the user sees it immediately. If any `critical`
severity items exist, the review should recommend pausing Phase 6 until rotation is
confirmed.

**Document upload policy**: files containing sensitive data should either be
(a) redacted before upload, (b) excluded from upload with a note, or (c) uploaded with
a warning tag so downstream consumers know the file needs handling. Default: **do NOT
upload files with `severity=critical` unless the user explicitly overrides**.

### Step 3.5: Cross-Document Validation Pass

After extracting from ALL documents, run these mandatory checks before proceeding to Phase 4:

**-1. Duplicate-content detection (rendered-page SHA match).** Two PDFs with different file
   hashes often contain byte-identical rendered content — a common pattern is the same
   scanned meeting notes saved under two subfolders (e.g. `Meeting Materials/` and
   `Trust and Estate/`). Deduplicate BEFORE entity extraction so you don't double-count
   attributions:
   ```bash
   # For every pair of PDFs with identical page count within this household:
   pdftoppm -r 100 -f 1 -l 1 "a.pdf" /tmp/a -png
   pdftoppm -r 100 -f 1 -l 1 "b.pdf" /tmp/b -png
   # Compare first-page PNG SHAs:
   shasum /tmp/a-1.png /tmp/b-1.png
   ```
   If SHAs match → one is a duplicate. Mark the later-mtime or alphabetically-later file as
   `status: DUPLICATE_OF(other_file)` in the tracker; still upload both files for folder
   fidelity, but do NOT duplicate their extracted entities in the cache. This check is
   cheap (~100ms per pair) and catches the "same meeting notes saved twice" pattern that
   wastes extraction tokens.

**-0.5. Cross-document CONTACT merge (fuller-identity-wins).** The same person often
   appears in multiple documents with varying completeness — e.g. file #3 (handwritten
   notes) mentions "Jane @ Law Firm X" while file #5 (email signature) reveals
   "Jane Doe, Partner, Law Firm X LLP, jdoe@example.com, +1-555-555-0100".
   Merge rule:
   - For each pair of extracted Contacts where name similarity ≥ 0.7 AND (firm matches
     OR email matches OR phone matches), merge into one record.
   - For each field, take the MOST COMPLETE value across all source documents (full name
     over first name; email over no email; firm name over "@ Law Firm X" shorthand).
   - Track ALL source documents on the merged record (e.g. `sources: ["file 3", "file 5"]`)
     so the audit trail survives.
   - If the merge is ambiguous (similar name but different email domains) → leave as two
     separate Contacts and flag in open_questions.

0. **⛔ CRITICAL: Latest-date-wins field resolution** — When the **same field** appears on the
   same entity in multiple documents with different values, the value from the **most recent
   source document wins**. This is the single most important merge rule — it supersedes the
   "most complete value" heuristic below when values actually differ.

   **Determine each document's "as-of date" using this priority** (first match wins):
   1. Explicit "As of" date printed on the document (e.g., "As of 3/31/2026")
   2. Document execution/signing/effective date (e.g., restated trust date, policy effective date)
   3. Filing or issue date (e.g., 1099 tax year = Dec 31 of that year; deed recording date)
   4. Statement period end date (e.g., "November 2025 statement" → 2025-11-30)
   5. Filename-embedded date patterns: `YYYY.MM.DD`, `YYYY-MM-DD`, `MM.DD.YY`, `YYYY_MM` (e.g.,
      `Certificate of IconTrust 2025.05.15.pdf` → 2025-05-15; `DL_2024.docx` → 2024-01-01 as
      month/day unknown fallback)
   6. File `mtime` (filesystem modification time) — only as a **last resort**, as OneDrive/
      Dropbox sync often rewrites mtime to the download time

   **Persist `asOfDate` on every cache entry**: each JSONL line in
   `extraction_cache_batch_{N}.jsonl` must include an `asOfDate` field (ISO format
   YYYY-MM-DD) so Phase 4 can resolve conflicts deterministically.

   **Apply to every scalar field** — address, email, phone, marital status, employer,
   occupation, trustee, beneficiary, policy status, account balance, valuation, etc.
   **Exceptions** (older value wins):
   - `dateOfBirth`, `ssn`, `formationDate`, `taxId` — immutable; first confirmed value wins,
     later contradictions are conflicts to flag
   - `originalBalance`, `originationDate`, `purchaseDate`, `purchasePrice` — historical
     values, don't overwrite with later docs
   - `firstName`, `lastName` at birth — flag middle/preferred name additions as enrichment
     rather than replacement

   **Apply to amendments & restatements**: a "Restated Trust" or "Second Amendment" supersedes
   the original trust agreement for ALL trustee/grantor/beneficiary fields. The original
   becomes historical (set `effectiveTo` on old relationships). Filename tokens to watch:
   `Amendment`, `Restated`, `Restatement`, `Amended`, `Second`, `Third`, `Revised`, `Updated`,
   `Final` (prefer `Final` over `draft`).

   **Apply to account statements**: a November 2025 statement's balance/valuation supersedes
   a July 2025 statement's for the same account. Older statements are read for history, not
   for the current balance.

   **In Phase 5 review**, when a field is overwritten by a later doc, show BOTH values so the
   reviewer can audit the decision:

   | Field | Winning Value | Winning Source (date) | Superseded Value | Superseded Source (date) |
   |-------|--------------|----------------------|------------------|--------------------------|
   | addressLegal | 123 Main St, Denver CO | Driver's License (2025-08-14) | 456 Oak Ave, Boulder CO | 2022 Tax Return (2023-04-15) |

1. **Name enrichment** — For each individual, find the MOST COMPLETE version of their name
   across all documents. Tax returns and account statements often reveal middle names that
   onboarding sheets omit. For actual name *conflicts* (different spellings), apply the
   latest-date-wins rule from item 0.

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

When merging across documents for the **same field**:
1. **Different values** → latest-date-wins (see Phase 3.5 Step 0). Record winner, loser, and
   both `asOfDate`s for Phase 5 review.
2. **One null, one non-null** → take the non-null value (no date check needed).
3. **Different levels of specificity** (e.g., "Denver" vs "Denver, CO 80202") → prefer the
   more specific value **only if** its source is newer or equal in age; otherwise latest-date-wins.
4. **Immutable fields** (ssn, dateOfBirth, formationDate, taxId) → first confirmed value wins;
   flag any later contradiction as a hard conflict, don't overwrite silently.

Always track all source documents + their as-of dates on every field.

### Step 4.2: Match extracted entities to Altitude Universe

For each merged extracted entity, attempt to match it to an existing Altitude entity.

**MANDATORY household-scoped search.** Per Rule 67, every Phase 4.2 search call MUST
pass `parentHouseholdId={current_household_id}`:

```
GET /api/v1/individual/search?searchFor={X}&parentHouseholdId={hh_id}
GET /api/v1/legal-entity/search?searchFor={X}&parentHouseholdId={hh_id}
GET /api/v1/account-financial/search?searchFor={X}&parentHouseholdId={hh_id}
GET /api/v1/tangible-asset/search?searchFor={X}&parentHouseholdId={hh_id}
GET /api/v1/liability/search?searchFor={X}&parentHouseholdId={hh_id}
GET /api/v1/insurance-policy/search?searchFor={X}&parentHouseholdId={hh_id}
```

After every search, **client-filter results by `parentHouseholdId`** (defense-in-depth):
skip any result whose `parentHouseholdId` points to a different household. Treat
results with `parentHouseholdId=null` as orphan candidates — emit an Open Question
rather than silently claiming them (see Rule 67 + Rule 60 orphan-LE triage).

**Contact search is firm-wide** (`/contact/search` does not honor the filter — Contacts
are firm-wide by design). For Contact match candidates, apply the per-result graph
check from Rule 67 to determine "shared firm-wide Contact" vs "this household's
exclusive Contact" before merging.

**External provider IDs take precedence over every other signal.** When an Altitude entity
has `externalIds: [{provider, externalId}]` set (common when a firm imported a hierarchy
spreadsheet from Addepar/Orion/Schwab before onboarding), a matching external ID in the
extracted data is a **definitive match** — use the existing entity, do NOT create a
duplicate, and do NOT overwrite the externalIds array (see Rule 42 on externally-synced
accounts).

**Individual matching against Altitude:**
1. **External ID match** (Addepar/Orion/Schwab) → definitive match, use existing
2. SSN exact match (if both have SSN) → definitive match
3. firstName + lastName exact match (case-insensitive) → strong match
4. firstName + lastName fuzzy match (≥ 0.85 similarity) + DOB match → strong match
5. lastName match + DOB match → probable match (flag for confirmation)
6. No match → candidate for new entity creation

**Legal Entity matching against Altitude:**
1. **External ID match** → definitive match
2. EIN/taxId exact match → definitive match
3. legalName exact match (case-insensitive) → strong match
4. legalName fuzzy match (≥ 0.8 similarity) + entityType match → strong match
5. No match → candidate for new entity creation

**Account matching against Altitude:**
1. **External ID match** → definitive match
2. accountNumber exact match → definitive match
3. Account name fuzzy match (≥ 0.85 similarity) + custodian match → strong match
4. No match → candidate for new entity creation

**Contact matching against Altitude:**
1. **External ID match** → definitive match
2. email exact match → definitive match
3. phone exact match → definitive match
4. firstName + lastName exact match (case-insensitive) + jobTitle match → strong match
5. **FIRM-WIDE contact search** (do this before creating any new Contact): Query
   `GET /api/v1/contact/search?searchFor={firstName}+{lastName}&size=50` to find existing
   Contacts across OTHER households in the same firm. A JPM banker serving Firm A may
   already exist under a different household — reuse, don't duplicate. If found:
   - Add the new household as an additional client relationship on the existing Contact
     (relationship: HOUSEHOLD→CONTACT, type ADVISOR/ATTORNEY/etc.)
   - Merge any new fields (if the existing Contact has no email and you have one, PATCH)
   - Do NOT create a duplicate Contact
6. No match anywhere → candidate for new entity creation

**Firm-wide dedup applies especially to**: JPM bankers, attorneys (Kirkland & Ellis,
large law firms, etc.), CPAs (large firms serve multiple clients), insurance agents,
Firm A's own staff (they work across every household). These should be shared Contacts,
not per-household duplicates.

**Tangible Asset matching against Altitude:**
1. **External ID match** → definitive match
2. serialOrIdentifier exact match → definitive match
3. Name + category + owner match → strong match
4. Address match (for real property) → strong match
5. No match → candidate for new entity creation

**Insurance Policy matching against Altitude:**
1. **External ID match** → definitive match
2. policyNumber exact match → definitive match
3. name + carrierName match (case-insensitive) → strong match
4. carrierName + coverageAmount + policyCategory match → probable match
5. No match → candidate for new entity creation

**Liability matching against Altitude:**
1. **External ID match** → definitive match
2. accountNumber + lenderName exact match → definitive match
3. name + lenderName match (case-insensitive) → strong match
4. lenderName + liabilityType + currentBalance within 5% → probable match
5. No match → candidate for new entity creation

**Same-family name collision** — when multiple candidates within the same household match on
first+last name alone (e.g., Dan A. Emmett father vs Daniel W. Emmett son), do NOT merge.
Require a disambiguator (middle initial, DOB, SSN, or explicit role-in-document). Flag for
user if none is available. See Rule 45.

### Step 4.3: Field-level diff against Altitude

For each matched entity, compare every field. Altitude records carry an `updatedAt` timestamp
(the last write time for that entity). Treat `updatedAt` as the Altitude value's effective
date when resolving conflicts.

```
For each field in the extracted entity:
  altitude_value     = existing_altitude_entity[field]
  altitude_asof      = existing_altitude_entity.updatedAt   # last API write
  extracted_value    = extracted_entity[field].value
  extracted_asof     = extracted_entity[field].asOfDate     # from Phase 3.5 Step 0

  IF altitude_value is null/empty AND extracted_value is not null/empty:
    → FILL: Queue this field for automatic update (safe to copy)

  ELIF altitude_value is not null/empty AND extracted_value is not null/empty:
    IF altitude_value == extracted_value:
      → MATCH: Values agree, no action needed
    ELIF field is immutable (ssn, dateOfBirth, formationDate, taxId):
      → HARD_CONFLICT: Values differ on an immutable field — flag for user, do NOT auto-resolve
    ELIF extracted_asof > altitude_asof:
      → SUPERSEDE: Documents have newer info → queue for update, show both values in review
    ELSE:  # altitude_asof >= extracted_asof
      → STALE: Altitude was updated more recently than the document — keep Altitude, show
        both in review in case the user wants to override

  ELIF altitude_value is not null/empty AND extracted_value is null/empty:
    → KEEP: Altitude has data we don't, leave it alone
```

Generate six lists for each entity (five field-level + one relationship-level):
1. **Auto-fill fields** — empty in Altitude, has value from documents
2. **Matching fields** — same value in both (no action)
3. **Supersede fields** — documents newer than Altitude, will overwrite (show diff in review)
4. **Stale fields** — Altitude newer than documents, will keep Altitude (show in review as FYI)
5. **Hard-conflict fields** — immutable fields that differ → block on user decision
6. **Structural corrections** — see Step 4.3.5 below

### Step 4.3.5: Structural Correction Handling

A **structural correction** arises when Altitude's existing relationship/structure is
actively wrong per authoritative source documents — distinct from field-level conflicts:
- Existing ownership percentages contradict operating agreements or partnership agreements
  (e.g., Altitude shows Dan owning 100% of Casa Rincon LLC, but the operating agreement
  clearly lists 4 children at 25% each)
- Existing entity type contradicts Articles (Altitude says LLC, Articles say Corporation)
- Existing trustee/officer lists contradict current trust/corporate documents

**Do NOT auto-apply structural corrections.** Surface them in the review under
`## Structural Corrections (user authorization required)` with:
- Current Altitude state (relationship id(s), source/target, percentage)
- Document reality (per document citation)
- Affected relationships to replace
- New relationships to create
- Recommended action: `HARD_DELETE` or `MARK_HISTORICAL`
- Blast radius (which rollups / displays shift)

**Choosing HARD_DELETE vs MARK_HISTORICAL:**
- **HARD_DELETE** (`DELETE /api/v1/entity-relationship/{id}/hard`) — use when the prior
  relationship was simply incorrect (data-entry error, hierarchy-spreadsheet approximation).
  No audit trail needed for "never was true."
- **MARK_HISTORICAL** (`PATCH /api/v1/entity-relationship/{id}` with `effectiveTo={today}`)
  — use when the prior relationship WAS true but ended (LP sold their interest, trustee
  resigned). Preserves the audit trail.

> ⚠️ Soft-delete does NOT release uniqueness. If you soft-delete OWNERSHIP X→Y and POST a
> new OWNERSHIP X→Y, you get HTTP 409. Use hard-delete or mark-historical — never
> soft-delete-and-recreate with the same source+target+type. This is the same constraint
> Rule 41 (Role replacements) relies on.

API recipes:
```bash
# HARD_DELETE (for "never was true")
OLD_ID="8f3c..."
curl -X DELETE "$API/api/v1/entity-relationship/$OLD_ID/hard" -H "X-API-Key: $KEY"

# MARK_HISTORICAL (for "was true, has ended")
curl -X PATCH "$API/api/v1/entity-relationship/$OLD_ID" \
  -H "Content-Type: application/merge-patch+json" -H "X-API-Key: $KEY" \
  -d '{"effectiveTo":"2025-07-08"}'
# then POST new relationships with effectiveFrom: "2025-07-08"
```

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
| OWNERSHIP (revocable trust) | Trust agreements (grantor → revocable trust) | IND→LE | Yes (100%) | Unidirectional. **MANDATORY alongside GRANTOR when trust is revocable** — see Rule 60 |
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
| HEALTHCARE_AGENT | Advance healthcare directive, DPANOC | IND→IND | No | Unidirectional (source is the agent; target is the person whose healthcare they decide) — use `role` to mark "Primary" / "Alternate" for priority |
| EXECUTOR | Will | IND→IND, LE→IND | No | Unidirectional — use `role` to mark "Primary" / "Contingent". Corporate fiduciaries (trust companies) as LE source. |
| TRUST_PROTECTOR | Modern trust instruments | IND→LE, CONTACT→LE, LE→LE | No | Unidirectional — independent oversight of trustees |
| OWNERSHIP (LE→LE) | Trust owns LLC, LLC is member of LP, Holdco owns sub | LE→LE | Yes | Unidirectional (parent → child entity) |
| MEMBER (LE→LE) | LLC where another entity (not a natural person) is a member | LE→LE | Yes | Unidirectional |
| PARTNER (LE→LE) | Partnership where an entity (not a natural person) is a partner | LE→LE | Yes | Unidirectional |

**Entity-to-entity chains**: multi-generational family structures often involve LE→LE
ownership (Trust → LLC → LP → operating-LLC → real property). See
`references/entity_chains.md` for worked examples and the correct relationship types for
each pattern (trust-owned LLC, GP/LP partnership, holdco-manager, ILIT chain).

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
| Client B | Operating LLC X1 | OWNERSHIP | CURRENT | 2022-09-15 | | 50%, Managing Member |
| Client B | External Attorney | ATTORNEY | CURRENT | 2023-05-22 | | Estate planning |
| Client B | Old CPA Firm | ACCOUNTANT | HISTORICAL | 2020-01-01 | 2023-12-31 | Replaced by New CPA Firm |
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

### Step 4.7: Role Replacements (Trustee / Advisor / Attorney / Accountant / Officer Changes)

When documents show that a role holder has been **replaced** (new trustee named in an
amendment, new CPA preparing the current tax return, new attorney on the restated trust,
resigned/removed officer), the skill must reflect the change — NOT merely add a new
relationship while leaving the old one active.

**Detect replacement signals:**

- Amendment/restatement documents name a DIFFERENT person in the same role as the original
  (e.g., original 2022 trust names John Smith as trustee; 2023 Second Amendment names
  Trust Company X — John Smith is replaced)
- A new document explicitly states a removal/resignation ("effective 3/15/2024, Jane Doe
  resigned as Co-Trustee")
- The **current** filing at a corporate registry lists a different officer than earlier docs
- A newer tax return is prepared by a different CPA firm than prior years

**Action on replacement — depends on whether the prior relationship EXISTS in Altitude:**

**Case A: Prior holder + relationship EXIST in Altitude** (full retire-and-replace path):

1. **Retire the old relationship** by PATCHing `effectiveTo` to the replacement date:
   ```
   PATCH /api/v1/entity-relationship/{oldRelationshipId}
   Content-Type: application/merge-patch+json
   {
     "effectiveTo": "2023-12-18",
     "notes": "Replaced by {new role holder} per {source document}. Superseded at Phase 6."
   }
   ```
   Do NOT delete the old relationship — Altitude needs the historical record (hard-delete
   also triggers the soft-delete uniqueness conflict in rule #21).

2. **Create the new relationship** with `effectiveFrom` = replacement date:
   ```
   POST /api/v1/entity-relationship
   {
     "sourceEntityType": "...", "sourceEntityId": "...",
     "targetEntityType": "...", "targetEntityId": "<new role holder>",
     "relationshipType": "TRUSTEE",
     "effectiveFrom": "2023-12-18",
     "effectiveTo": null,
     "notes": "Replaces {old holder name} retired on same date"
   }
   ```

3. **role_replacements.json** entry: `action: "retire_old_and_create_new"` with both
   old and new relationship IDs for the audit trail.

**Case B: Prior holder does NOT exist in Altitude** (create-new-only path — the common case):

Documents reference a prior trustee/grantor/advisor who was never imported into Altitude
(e.g., a 2012 trust grantor superseded by a 2020 restatement — only the current state
is in Altitude). In this case:

1. **(Optional) Create the historical holder as a Contact** — for audit-trail completeness,
   but not strictly required. Mark with `biography` noting they are historical.

2. **Create the new relationship** as above with `effectiveFrom` = replacement date.

3. **role_replacements.json** entry: `action: "create_new_only"` with `replacesPriorHolder`
   field noting the superseded name for provenance.

**Detection — how to tell which case applies**:

For each relationship marked `isReplacement: true` in the extraction cache:

```python
# Check if any existing Altitude relationship matches the role being replaced
existing = api_get(f"/api/v1/entity-relationship/from/{source_type}/{source_id}")
candidates = [r for r in existing
              if r["relationshipType"] == new_type
              and r["effectiveTo"] is None]  # only active ones
if candidates:
    # Case A: we found the relationship to retire
    action = "retire_old_and_create_new"
    old_relationship_id = candidates[0]["id"]  # or match by target if multiple
else:
    # Case B: no existing relationship to retire, just create
    action = "create_new_only"
```

**If multiple existing relationships match** (e.g., GWN Trust has 2 current TRUSTEE
relationships and the restatement replaces both with a corporate trustee) — retire ALL
matching ones with the same effectiveTo date. Do NOT silently pick one.

**Within Phase 6 execution order**: run retirement PATCHes BEFORE creating new
relationships. Altitude's uniqueness constraint rejects duplicates: you must retire the
old one first so the new POST doesn't hit 409 Conflict.

4. **In Phase 5 review**, render replacements as their own table:

   | Role | Old Holder | New Holder | Replacement Date | Source Document |
   |------|------------|------------|------------------|-----------------|
   | Trustee of DPG Trust | John Smith (CONTACT) | Trust Company X (CONTACT) | 2023-12-18 | Second Amendment and Restatement of the DPG Trust (signed 12.18.23) |

**Common replacement scenarios to watch for:**
- Trust restatement naming new trustee, successor trustee, or distribution advisor
- LLC operating agreement amendment naming new managing member
- Corporate board meeting minutes replacing officers
- Current tax return preparer differs from prior-year preparer → old CPA relationship retires
- New engagement letter for attorney/advisor → flag whether it supersedes a prior engagement
- Named-insured change on insurance policy → update OWNERSHIP relationships on the policy

**When unsure**: if the document does not explicitly state a replacement (could be an
additional co-trustee rather than a replacement), leave the old relationship intact and
flag in Open Questions. Never silently retire a relationship on ambiguous signals.

### Step 4.7b: Upgrading relationship edges (Rule 73)

**Use PATCH on the existing edge — NEVER POST a second edge between the same source
and target with a different `relationshipType`.** Altitude's relationship store enforces
a uniqueness constraint on `(sourceEntityId, targetEntityId)` (across types, not just
within a single type). POSTing a new OWNERSHIP edge when a MEMBER edge already exists
between the same pair returns **HTTP 409 Data Integrity** — observed during the Tusk
Family Wave 1 rerun on MEMBER → OWNERSHIP upgrades.

The fix is to mutate the edge in place: locate the existing edge, then PATCH its
`relationshipType` (and any added fields like `percentage`) via JSON Merge Patch.
This preserves the edge's UUID and audit history (`createdAt`, original creator,
prior `relationshipType`) — POST-and-DELETE breaks that lineage and is the wrong
shape for a "this MEMBER is now an OWNER" event, which is a type upgrade, not a
new relationship.

**Recipe:**

```bash
# 1. Locate the existing edge (preferred form: traverse from source, filter by target)
SRC_TYPE="INDIVIDUAL"; SRC_ID="<src uuid>"; TGT_ID="<tgt uuid>"
EXISTING=$(curl -s -H "X-API-Key: $KEY" \
  "$API/api/v1/entity-relationship/from/${SRC_TYPE}/${SRC_ID}" \
  | jq --arg t "$TGT_ID" '.[] | select(.targetEntityId == $t and .effectiveTo == null)')
REL_ID=$(echo "$EXISTING" | jq -r '.id')
OLD_TYPE=$(echo "$EXISTING" | jq -r '.relationshipType')
echo "Upgrading edge ${REL_ID}: ${OLD_TYPE} -> OWNERSHIP"

# 2. PATCH the edge — body uses JSON Merge Patch semantics (null fields ignored)
curl -X PATCH "$API/api/v1/entity-relationship/${REL_ID}" \
  -H "Content-Type: application/merge-patch+json" -H "X-API-Key: $KEY" \
  -d '{
    "relationshipType": "OWNERSHIP",
    "percentage": 50,
    "notes": "Upgraded from '"${OLD_TYPE}"' per <source document>"
  }'
```

> The `/from/{sourceType}/{sourceId}` form is the documented traversal endpoint
> (api.json line ~97483). The base list endpoint
> `GET /api/v1/entity-relationship?sourceEntityId=...&targetEntityId=...` accepts
> dynamic field filters per its OpenAPI description and works for the same lookup
> when the source-type is unknown — prefer the typed `/from/...` form when you
> already know the source type, falling back to dynamic filters only when you do
> not.

**Common cases this applies to:**

- **MEMBER → OWNERSHIP** — LLC member receives a percentage allocation in a later
  amendment; the previously-typeless membership edge becomes a typed ownership stake.
  (Tusk Family case.)
- **TRUSTEE → GRANTOR** — on the death of the original grantor, a co-trustee becomes
  the new grantor of a successor trust; the existing TRUSTEE edge is upgraded rather
  than duplicated.
- **BENEFICIARY → OWNERSHIP** — a remainder beneficiary becomes outright owner upon
  trust termination or distribution; the BENEFICIARY edge is upgraded to OWNERSHIP
  with the distributed percentage.

**When NOT to use PATCH-upgrade:**

- The old edge represents an event that genuinely ended (e.g. trustee resigned
  before the grantor died) — that is the role-replacement case from Step 4.7,
  use retire-and-create (mark `effectiveTo`, then POST the new edge).
- The new relationship has a different source or target (e.g. ownership moves to
  a different person) — that is a transfer, use `POST /api/v1/entity-relationship/transfer`.

#### Rule 73 — Upgrade existing relationship edges via PATCH, not POST + DELETE

When a relationship between an existing source/target pair changes
`relationshipType` (e.g. MEMBER becomes OWNERSHIP, TRUSTEE becomes GRANTOR), the
skill MUST PATCH the existing edge's `relationshipType` (and any new fields like
`percentage`) rather than POST a new edge of the new type. POSTing a second edge
between the same `(sourceEntityId, targetEntityId)` pair — regardless of type —
returns HTTP 409 Data Integrity. PATCH preserves the edge UUID and audit history
(created date, original creator, original relationship metadata); a POST + DELETE
sequence breaks that lineage and is the wrong semantics for a type upgrade.
Locate the existing edge via
`GET /api/v1/entity-relationship/from/{sourceType}/{sourceId}` filtered by
`targetEntityId` (or via dynamic filters on the base list endpoint), then PATCH
with `Content-Type: application/merge-patch+json`. This rule is distinct from
Rule 41 (role replacement, where the role-holder changes — old edge is retired
via `effectiveTo`, new edge is POSTed for the new holder). Use PATCH-upgrade
ONLY when the source AND target are unchanged and only the type/percentage shifts.

### Step 4.8: Addepar (or any externally-synced) Account Handling — READ-ONLY

Accounts with an active external sync (Addepar, Orion, Black Diamond, custodian direct feed)
are **authoritative from the external source**. The onboarding skill must NOT overwrite
their fields from documents — the external sync will either overwrite the manual change on
its next run (data loss) or produce conflicting records.

**Detect externally-synced accounts:**

After fetching each account in Phase 1.3 (`GET /api/v1/account-financial/{id}`), check:
- `externalIds[]` array — if any entry has `provider: "ADDEPAR"` (or `ORION`, `BLACK_DIAMOND`,
  `SCHWAB`, `FIDELITY`, etc.), the account is externally synced
- `providerDetails.sourceSystemName` — same signal via the older field

Mark each account as one of:

| Status | Meaning | Skill Action |
|--------|---------|--------------|
| `SYNCED_HEALTHY` | Has external provider + non-zero `totalMarketValue` | **Read-only** on core fields; flag discrepancies between docs and Altitude but do NOT PATCH. Still update non-synced metadata (nickname, description, tags, tax notes) if extracted from docs. |
| `SYNCED_BUT_ZERO` | Has external provider but `totalMarketValue == 0` or null `lastSyncedAt` | **Flag to user** — sync configured but not running. Don't update fields; show the user the expected values from docs so they can investigate the sync. |
| `NOT_SYNCED` | No external provider | Normal PATCH/POST behavior — treat like any other entity |

**Fields protected on SYNCED accounts (never PATCH from docs):**

`accountNumber`, `name`, `custodianId`, `accountCategory`, `subCategory`, `taxStatus`,
`wrapper`, `totalMarketValue`, `totalCashBalance`, `totalCostBasis`, `holdings`,
`positions`, `valuations`, `providerDetails.*`, `externalIds[].*`

**Fields still safe to update on SYNCED accounts (manual-only metadata):**

`description`, `tags`, `manualNotes` (if present), `ownershipType`, account-level
PATCH-compatible flags that are not part of the sync contract.

**Discrepancy flagging** — when a document value differs from a SYNCED account's Altitude
value, don't PATCH but DO include in the review under a dedicated section:

```markdown
## Addepar / External Sync Discrepancies — Needs Investigation

| Account | Field | Altitude (from Addepar) | Document Value | Source Doc | asOfDate | Likely Cause |
|---------|-------|------------------------|----------------|------------|----------|--------------|
| Trust Brokerage | totalMarketValue | $0.00 | $X | portfolio_YYYY-MM-DD.xlsx | YYYY-MM-DD | Sync not running — lastSyncedAt is null |
| Trust Brokerage | name | "DPG TR BROKERAGE" | "DPG Trust Brokerage Account" | Schwab Account App (draft) | 2024-09-01 | Addepar uses a different display name — cosmetic only |
```

**Zero-value sync alert** — if ANY account has an external provider AND
`totalMarketValue == 0` (or the expected sum from documents is materially nonzero), raise
this as a blocking item in the review:

```markdown
## ⚠ Accounts With Zero Values Despite Active Sync

The following accounts are configured to sync from Addepar but show $0 market value.
This usually means the sync has not run, the external account ID is wrong, or the custodian
connection is broken. Please investigate before proceeding.

- {Account Name} ({account UUID}) — provider: {ADDEPAR}, externalId: {...}, lastSyncedAt: null
```

Do this check **before** Phase 6. The user needs to see this immediately, not buried at the
end of a 200-line review.

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

## Fast-Path Summary (read this first)

A one-line-per-entity executive summary so reviewers can skim before diving into field
tables. Populate as follows:

**Entity state classifications:**
- **SHELL** — Altitude has the entity by name only; all/most PII fields null.
  Example: an advisor created the household + primary Individual ahead of onboarding.
  Implication: nearly everything queued here is a safe FILL, no conflict risk.
- **POPULATED** — Altitude has meaningful data; extraction adds incremental fills / conflicts.
- **NEW** — Entity doesn't exist in Altitude; will be POSTed.
- **SYNCED** — Externally synced (Addepar, Orion, custodian); core fields read-only
  (see "Addepar / External Sync Discrepancies" section below for what the skill will skip).

| Entity | Altitude State | Fills | Conflicts | Stale | Auto-PATCH Safe? |
|--------|----------------|-------|-----------|-------|------------------|
| Client A (Individual) | **SHELL** | 27 | 0 | 0 | ✅ Yes — zero risk |
| Family A Trust (LegalEntity) | NEW | — | — | — | POST |
| DPG Trust Brokerage (Account) | SYNCED | 2 (tags only) | 0 | 0 | Metadata-only PATCH |
| Client A 2020 Restated Trust (LegalEntity) | POPULATED | 4 | 2 | 1 | ⚠ Needs review |
| External Manager (Contact) | NEW | — | — | — | POST |

**"Auto-PATCH Safe"** is `✅` when: all diffs are FILLs (no conflicts, no stale Altitude
values, no immutable-field changes). A `SHELL` entity almost always qualifies. Flag any
entity with conflicts as `⚠ Needs review` and include the full diff below.

**Zero-risk bulk approve**: reviewers should be able to approve all `✅ Yes` rows in one
action without reading the detail tables — the detail tables are for the `⚠` rows only.

## Matched Entities (will update)

### Individual: {Name} (Altitude ID: {id})
**Auto-fill fields** (empty in Altitude → will populate):
| Field | Extracted Value | Source Document |
|-------|----------------|-----------------|
| dateOfBirth | 1985-06-01 | The Whole Shebang.docx |
| ssn | 000-XX-0000 | Driver's License |

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
| Family B (Household) | Client B (Individual) | OWNERSHIP | Primary | 50% |
| Family B (Household) | Spouse B (Individual) | OWNERSHIP | | 50% |
| Client B (Individual) | Operating LLC X1 (LegalEntity) | OWNERSHIP | Managing Member | 50% |
| Operating LLC X1 (LegalEntity) | External Attorney (Contact) | ATTORNEY | Estate Planning | - |
| Operating LLC X1 (LegalEntity) | Registered Agent (Contact) | ATTORNEY | Corporate | - |

## Document Uploads
| Document | Will Associate With | Entity Type | Entity Name | documentSubType |
|----------|-------------------|-------------|------------|-----------------|
| Drivers License.png | Individual | Individual | Client B | DRIVERS_LICENSE |
| Operating Agreement.pdf | Legal Entity | LegalEntity | Operating LLC X1 | OPERATING_AGREEMENT |
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
| 1 | DL - Client B.png | Individual | Client B | DRIVERS_LICENSE | |
| 2 | Operating Agreement.pdf | LegalEntity | Operating LLC X1 | OPERATING_AGREEMENT | |
| 3 | Trust Agreement.pdf | LegalEntity | Client B Trust | TRUST_AGREEMENT | |
| 4 | Will.pdf | Individual | Client B | OTHER | Estate planning - Will |
| 5 | Living Will.pdf | Individual | Client B | OTHER | Estate planning - Living Will |
| 6 | Healthcare Surrogate.pdf | Individual | Client B | OTHER | Healthcare directive |
| 7 | Durable POA.pdf | Individual | Client B | POWER_OF_ATTORNEY | |
| 8 | W-2.pdf | Individual | Client B | FORM_W2 | |
| 9 | 1099-INT.pdf | Individual | Client B | FORM_1099_INT | |
| 10 | Warranty Deed.pdf | TangibleAsset | 123 Main Street | DEED | |
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
| 1 | Which trust owns the MassMutual life policies? ("Family B Trust" is ambiguous) | Determines OWNERSHIP relationship for insurance policies | Yes — can't create relationship |
| 2 | Is 401 NE Mizner Blvd PH810 owned or rented? | Determines if we create a TangibleAsset | Yes — missing asset |
| 3 | What is Spouse B's business? (Spouse B Inc) | Sets occupation field | No — can leave blank |
| 4 | CFO name for mlund@quinceandcosf.com? | Contact entity is incomplete | No — has email |
| 5 | Correct address: 123 Main Street vs alternate? (warranty deed conflict) | Property address | Yes — data integrity |
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
      { "name": "Client B", "id": "{uuid}", "status": "CREATED" },
      { "name": "Spouse B", "id": "{uuid}", "status": "CREATED" }
    ],
    "legalEntities": [...],
    "contacts": [...],
    "insurancePolicies": [...],
    "liabilities": [...],
    "tangibleAssets": [...],
    "relationships": [
      { "source": "Family B", "target": "Client B", "type": "OWNERSHIP", "id": "{uuid}", "status": "CREATED" }
    ]
  },
  "documents": {
    "uploaded": [
      { "file": "Identification/Drivers Licenses.png", "entityId": "{uuid}", "documentId": "abc123-...", "status": "UPLOADED" },
      { "file": "LLC/OperatingLLC/Operating Agreement.pdf", "entityId": "{uuid}", "documentId": "def456-...", "status": "UPLOADED" }
    ],
    "failed": [
      { "file": "LLC/RCF/4th Amended Note.pdf", "error": "HTTP 500", "status": "FAILED" }
    ],
    "sessionId": "882fea65-..."
  },
  "estatePlanningPatched": ["{uuid}", "{uuid}"],
  "openQuestions": [...]
}
```

**On rerun behavior:**
- Before Phase 1: Check if `run_state.json` exists. If yes, load it and ask the user:
  "Previous run found (dated {runDate}, status={status}). Options:
  **(A) Resume** — skip already-created entities, only create missing ones + retry failed uploads.
  **(B) Force rerun** — re-extract all documents and recreate everything.
  **(C) Upload only** — skip entity creation, just upload remaining documents.
  **(D) Gap analysis** — no destructive actions; re-query Altitude, diff against the last
  `run_state.json`, report any entities that got orphaned / relationships that got deleted /
  fields that got cleared / enum constraints that were added since the last run. Output:
  `altitude_review/rerun_analysis_{YYYY-MM-DD}.md`. No writes until you approve individual
  gap fixes."
- **Resume mode**: For each entity in the state file with status CREATED, skip creation.
  For documents with status UPLOADED, skip upload. For FAILED documents, retry.
- **Force mode**: Delete the state file and start fresh.
- **Upload only**: Skip Phases 1-6, only run Phase 7 using entity IDs from the state file.
- **Gap analysis mode**: Default when `status=COMPLETE`. Performs Phase 1 (re-query) +
  targeted diff against saved state, writes `rerun_analysis_{date}.md` listing fixable
  gaps with per-gap approval.

Update the state file after EVERY successful API call (not just at the end). This way, if the
run is interrupted mid-way, the next run can resume from where it stopped.

### Save Artifacts

All review artifacts go to `{household_folder}/altitude_review/` (the review directory is
ALWAYS created at the root of the household folder — sibling to the source document
subfolders, never buried deeper):

- `review.md` — complete human-readable review (ALL sections above)
- `file_tracker.md` — every file with READ status and extraction summary
- `altitude_universe.json` — initial state from Phase 1
- `create_payloads.json` — POST requests for new entities. **Write in Phase 5b (AFTER user
  approval), NOT in initial Phase 5.** Before approval, the review.md tables are sufficient;
  building concrete payloads prematurely causes churn when Q&A responses change the shape
  (e.g., Q: "create Sean as standalone Individual or include in household?" directly
  determines whether a payload references a `parentHouseholdId`). Pre-approval Phase 5
  only needs the review.md + open_questions.json. Phase 5b runs immediately before Phase 6
  and crystallizes the approved scope into JSON.
- `patch_payloads.json` — PATCH requests for existing entities. **Same Phase 5b timing** as
  create_payloads.json.
- `relationships_to_create.json` — relationship creation plan
- `role_replacements.json` — trustee/advisor/attorney/officer replacements (see Phase 4.7)
- `addepar_discrepancies.json` — doc-vs-sync mismatches for synced accounts (see Phase 4.8)
- `document_uploads.json` — document upload plan (file → entity → subType)
- `supersede_log.json` — **REQUIRED, ALWAYS WRITE** when any latest-date-wins decision was made.
  Audit trail of every field where a later document superseded an earlier one (or overrode an
  existing Altitude value). Format:
  ```json
  [
    {
      "entityType": "Individual",
      "entityName": "Client Z",
      "entityId": "e9f2...",
      "field": "addressLegal",
      "winningValue": "123 Main Street, City, ST 00000",
      "winningSource": "DPG 2022 Trust Amendment (signed 2020-04-16)",
      "winningAsOfDate": "2020-04-16",
      "losingValue": "221 Gold Mine Drive, San Francisco CA 94131",
      "losingSource": "Onboarding Sheet 2018 draft",
      "losingAsOfDate": "2018-06-01",
      "classification": "SUPERSEDE",
      "appliedToAltitude": true,
      "reviewApprovedAt": "2026-04-17T16:40:00Z"
    }
  ]
  ```
  Categories: `FILL` (empty→value), `MATCH` (no change), `SUPERSEDE` (newer wins), `STALE`
  (older, keep Altitude), `HARD_CONFLICT` (immutable fields — never auto-resolve). This file
  is the audit trail for latest-date-wins decisions — auditors and future onboarding sessions
  can inspect to understand why a field has its current value.
- `sensitive_data.json` — **REQUIRED if any sensitive data was found**, see Step 3.4.
- `open_questions.json` — **REQUIRED, ALWAYS WRITE THIS FILE** even if empty. Structured JSON
  for programmatic tracking across families. Format:
  ```json
  [
    {"id": 1, "question": "Does client have a Will?", "category": "estate_planning", "blocking": false, "entity": "Client X", "resolved": false, "resolution": null},
    {"id": 2, "question": "Spouse DOB: 10/02 vs 10/21?", "category": "data_conflict", "blocking": false, "entity": "Spouse X", "resolved": false, "resolution": null}
  ]
  ```
  This file must ALSO be written — embedding questions only in review.md is insufficient.
  Categories: `estate_planning`, `data_conflict`, `missing_data`, `ownership`, `insurance`, `address`, `account`, `other`, `addepar_sync`, `family_status`, `file_access`, `asset_detail`, `entity_detail`, `liability_detail`, `advisor_relationships`, `schema`, `holdings_data`, `account_status`
- `run_state.json` — persistent state for incremental reruns (entity IDs, document upload status, failures)

### Approval Q&A Trail (REQUIRED — separate from altitude_review/)

In ADDITION to the structured `open_questions.json` inside `altitude_review/`, **write a
human-readable Q&A tracking file at the ROOT of the household folder** (sibling to
`altitude_review/`, alongside the source subfolders). This file captures every question
asked during validation/approval, the user's response, and when each was resolved.

**File name**: `altitude_questions_{YYYY-MM-DD}.md` — dated, so multiple onboarding sessions
or revisits produce separate files and the audit trail survives.

**File location**: `{household_folder}/altitude_questions_{YYYY-MM-DD}.md` — the household
root, NOT inside `altitude_review/`. Reason: the Q&A log is user-facing and survives
cleanup/rebuild of the review directory.

**Required template** (populate as the session progresses; update in place when user responds):

```markdown
# Altitude Onboarding — Approval Questions

**Household**: {name}
**Altitude Household ID**: {uuid or "new"}
**Firm**: {firm}
**Session Date**: {YYYY-MM-DD}
**Source folder**: {absolute path}
**Review artifacts**: `./altitude_review/review.md`

## Session Timeline

| When | Phase | Actor | Note |
|---|---|---|---|

## Pre-Approval Blocking Questions

### Q1 — {short title}
**Severity**: Blocking | Non-blocking
**Category**: {one of the categories above}

**Question**: {full question with context}

**Proposed answer** (skill's best guess; user can confirm with "yes" or override):
{the skill's recommended resolution, with rationale}

Example: "Use tax return SSN `000-XX-0000` (authoritative) and overwrite Altitude's
invalid `140965906`. Rationale: SSA issues SSNs in ranges 001-665, 667-699, 750-772;
140-965-906 falls outside all ranges, so it's data entry error. 2022 + 2023 1040 both
confirm 000-XX-0000."

**User Response**: _awaiting_ | {response text — "yes" = accept proposed answer}
**Resolved**: _pending_ | YYYY-MM-DD HH:MM
**Resolution**: _pending_ | {final decision — populated from Proposed answer if user said "yes"}

## Non-Blocking Open Questions (see open_questions.json for full list)

{summary list — full detail lives in open_questions.json}

## Post-Approval Questions (populated during Phase 6/7)

{append each mid-execution question as it arises}

## Approval Record

**Final approval granted at**: _pending_ | YYYY-MM-DD HH:MM
**Approver**: _pending_ | {user name/role}
**Scope approved**:
- [ ] {each proposed change item}

**Any excluded items**: _pending_ | {list}
```

**Update rules**:
- Write the file at Phase 5 completion (presenting the review to the user).
- **Append** additional questions as they arise during Phase 6/7 under "Post-Approval Questions".
- **Update in place** when the user responds — fill the `User Response`, `Resolved`, and
  `Resolution` fields with timestamps.
- **Do NOT overwrite** prior session's file — if running a re-onboarding for the same family,
  use today's date in the filename so both audit trails survive.

### Upload Q&A File to Household as Document

As the final step of Phase 7, upload the `altitude_questions_{YYYY-MM-DD}.md` file to the
primary individual in Altitude (Households don't support direct document upload — see Phase 7
note). Use these parameters:

Before uploading, **rename the `.md` file to `.txt`** (or copy it) — Altitude's
`contentType` enum does NOT include `MARKDOWN`. The only valid values are CSV, DOC, DOCX,
GIF, HTML, JPG, JSON, MP3, MP4, PDF, PNG, PPT, PPTX, TXT, XLS, XLSX, XML, ZIP. Upload as
`TXT` so it renders as plain text in the Altitude UI:

```
POST /api/v1/individual/{primaryIndividualId}/document?sessionId={sessionId}&skipDuplicates=true
createRequest:
  title: "Altitude Onboarding Q&A — {Household Name} — {YYYY-MM-DD}"
  description: "Validation and approval questions from onboarding session on {YYYY-MM-DD}. Source is markdown; rendered as plain text."
  documentSubType: "OTHER"
  contentType: "TXT"
```

After upload, create entity associations so the document appears on both the Individual AND
the Household:

```
POST /api/v1/document/{docId}/associations?entityType=INDIVIDUAL&entityId={primaryIndividualId}&associationType=OWNER&entityDisplayName={name}
POST /api/v1/document/{docId}/associations?entityType=HOUSEHOLD&entityId={householdId}&associationType=SUBJECT&entityDisplayName={householdName}
```

This way future onboarding sessions (and auditors) can reconstruct the decision trail from
within Altitude without needing access to the source document folder.

---

Present the review to the user and wait for approval + conflict resolution.

---

## Phase 5b: Cross-Contamination Detection (Rule 71)

**MANDATORY before Phase 6.** Misplaced files and Verita-style sample templates have
been observed in real household folders (e.g. Liu folder containing Tenet bank docs;
Ramonas folder containing a Levine balance sheet; Lamond folder containing generic
Verita templates). Phase 6 MUST skip any file flagged as contaminated, and the user
MUST see the findings before approving the push. Run all three checks below; do not
short-circuit on the first hit — a single file can fail multiple checks.

### Check 1: Filename / extracted-name vs household-name mismatch

For every file recorded in `extraction_cache.jsonl`, compute the strong identifiers
present:

- last names extracted from the file's entities (Individual.lastName,
  LegalEntity.legalName tokens, account-title surnames)
- last names embedded in the filename itself (`Smith_2024_1040.pdf` → `Smith`)
- trust / LE names referenced in the document body

Compare against the household's allow-list:

- the household's primary surnames (collect from current Altitude universe AND
  `extraction_cache.jsonl` consensus — not just folder name, since folder names are
  sometimes anglicized or abbreviated)
- LE names already attached to the household via OWNERSHIP / TRUSTEE / GRANTOR /
  visibility edges
- known vendor strings (custodian names, advisor firm names — these are NOT
  contamination, they're expected on statements)

A file fails Check 1 when one of its strong identifiers is NOT on the allow-list
AND is NOT a known vendor string. Record `type: filename_mismatch`.

### Check 2: Sample / template artifact

Some folders contain Verita's onboarding sample data — these files have NO real
client information and must NEVER be extracted or uploaded. Scan filenames AND
extracted text for any of:

- `Smith / Jordan D. Smith / Alex Smith / Alpine Ridge` (Verita sample family)
- generic placeholders: `Sample`, `Template`, `Example`, `Lorem`, `John Doe`,
  `Jane Doe`, `Test Family`
- filename suffixes `_template`, `_sample`, `_example`

Any match → `type: template_artifact`, `suggested_action: skip`. Tag as
"TIER 4 generic template — do not extract, do not upload" so the upload phase
silently drops these without re-prompting the user.

### Check 3: Content-vs-folder divergence

For each PDF/DOCX where Phase 3 extracted a household-level identifier — account
holder name on a statement, beneficiary list on a trust, primary-insured on a
policy declaration — verify it agrees with the current household. Disagreement is
recorded as `type: content_divergence`. This is the strongest contamination signal
because it survives filename obfuscation; a `2024_Statement.pdf` whose statement
header reads `Account holder: John Levine` in a Ramonas folder is unambiguous.

### Output: `cross_contamination_findings.json`

Write to `{household_folder}/altitude_review/cross_contamination_findings.json`:

```json
{
  "household": "<name>",
  "household_id": "<uuid>",
  "generated_at": "YYYY-MM-DDTHH:MM:SSZ",
  "checks_run": ["filename_mismatch", "template_artifact", "content_divergence"],
  "findings": [
    {
      "file": "<path relative to household folder>",
      "type": "filename_mismatch | template_artifact | content_divergence",
      "evidence": "<short — e.g. 'filename contains Levine; household allow-list is Ramonas, Ramonas-Trust'>",
      "suggested_action": "skip | move_to_<other_household> | delete",
      "confidence": "high | medium | low"
    }
  ]
}
```

Confidence guide:
- `high` — Check 2 (template) match, OR Check 3 with multiple corroborating
  identifiers (e.g. account number + holder name + address all wrong household)
- `medium` — Check 1 with a clean foreign surname AND no allow-list overlap, OR
  Check 3 with a single identifier
- `low` — ambiguous (e.g. a shared advisor's letterhead happens to mention another
  client's name in passing)

### Fleet-level rollup (separate aggregation step)

The user maintains a fleet-aggregated `Discovery/CROSS_CONTAMINATION_<date>.md` —
the per-household JSON is the primary skill output; the markdown rollup is appended
by a separate cross-household script that reads each family's
`cross_contamination_findings.json`. The skill does NOT write the markdown directly,
but it MUST emit the per-household JSON in the schema above so the rollup parses
cleanly.

### Hand-off into Phase 6

- Surface every `high`-confidence finding inline in the Phase 5 review packet that
  the user is approving. Do not silently swallow.
- Append every finding (any confidence) to the Phase 6 skip-list:
  `run_state.contamination_skip[]` with the file path and reason.
- Phase 6 (entity push) and Phase 7 (document upload) MUST consult this skip-list
  and refuse to upload or attribute any file on it. Skipping means: no document
  POST, no entity-association call, no extraction-derived field write to entities
  the user already owns.
- If the user reviews the JSON and overrides a finding (e.g. "this is actually
  ours, the surname is from a maiden-name account"), they delete the finding from
  the JSON before approving — the skill does not auto-override.

### Rule 71 — Cross-contamination detection is mandatory before Phase 6 push

Every onboarding run MUST emit `cross_contamination_findings.json` and surface
all `high`-confidence findings in the Phase 5 review before Phase 6 begins. Phase 6
and Phase 7 MUST consult `run_state.contamination_skip[]` and silently exclude any
listed file from entity-attribution writes and document uploads. The skill MUST
NOT auto-move or auto-delete contaminated files — those are user decisions logged
as `suggested_action` but executed manually. A run with zero findings still emits
the JSON file (with `findings: []`) so the fleet rollup can confirm the check ran.

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
  "dateOfBirth": "1985-06-01",
  "ssn": "000000000",
  "email": "clientb@example.com",
  "addressLegal": {
    "addressLine1": "123 Main Streetreet",
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

**⚠ DO NOT include `notes` on a PATCH/POST body for Individual, LegalEntity,
TangibleAsset, Liability, InsurancePolicy, AccountFinancial, or Document.** That field
is a `Set<NoteDto>`, not a string — passing a string returns 400 "Cannot deserialize
value of type `HashSet<…NoteDto>`". Notes are created via the separate child endpoint:

```
POST /api/v1/individual/{id}/notes
POST /api/v1/legal-entity/{id}/notes
POST /api/v1/tangible-asset/{id}/notes
POST /api/v1/liability/{id}/notes
POST /api/v1/insurance-policy/{id}/notes
POST /api/v1/account-financial/{id}/notes
POST /api/v1/document/{id}/notes
Content-Type: application/json
X-API-Key: {api_key}

{"noteText": "Free-form note body here"}
```

The DTO's **required field is `noteText`** — **NOT** `note` or `text`. Missing/wrong
field name returns 400 `"noteText: must not be null"`. This was a repeat pitfall on
a recent run — every early POST with `{"note": …}` failed silently.

**⚠ Household and Contact do NOT support `/notes`.** `POST /api/v1/household/{id}/notes`
returns **HTTP 404** (no such endpoint per `api.json` 2026-04-23). Same for Contact. For
household-level metadata that doesn't belong on a member entity, use one of:
- **Supplemental attributes** — `POST /api/v1/household/{id}/attributes` (Household + Contact
  both support `/attributes`). This is the canonical place for household-level facts.
- **Reroute to the primary individual's `/notes`** — prefix the noteText with
  `(Household-level CRM metadata)` or similar so future readers understand the scope.

This was hit on the a recent CRM update: a `/household/{id}/notes` POST returned
404 silently in a script, then succeeded when redirected to the primary individual.

If an API call fails, log it, save state, and ask user to retry or continue with others.

### Step 6.2: Create new entities (POST)

For entities that don't exist in Altitude yet:

```
POST /api/v1/individual
X-API-Key: {api_key}
Content-Type: application/json

{
  "firstName": "Client",
  "lastName": "B",
  "dateOfBirth": "1985-06-01",
  "ssn": "000000000",
  "email": "clientb@example.com",
  "addressLegal": { ... }
}
```

For new legal entities (trusts, LLCs, corporations):

```
POST /api/v1/legal-entity
X-API-Key: {api_key}
Content-Type: application/json

{
  "legalName": "Operating LLC X1",
  "entityType": "LLC",
  "formationDate": "2015-03-20",
  "jurisdiction": "FL",
  "incorporationState": "FL",
  "incorporationCountry": "UNITED_STATES",
  "taxId": "00-0000000",
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

For new tangible assets (use SUBTYPE-SPECIFIC endpoints — NOT the base `/tangible-asset`).

**⚠ `valuationSource` is an ENUM, not a freeform string.** Accepted values only:
`PROFESSIONAL_APPRAISAL`, `AUCTION_ESTIMATE`, `INSURANCE_APPRAISAL`, `DEALER_ESTIMATE`,
`COMPARABLE_SALES`, `TAX_ASSESSMENT`, `PURCHASE_PRICE`, `REPLACEMENT_COST`,
`OWNER_ESTIMATE`. Sending a human-readable label like `"BDT Balance Sheet 2025"` returns
400. Mapping cheatsheet:

| Document source | Use this enum |
|---|---|
| Client balance sheet / family-office spreadsheet | `OWNER_ESTIMATE` |
| Appraisal report (Gurr Johns, Sothebys, etc.) | `PROFESSIONAL_APPRAISAL` |
| Insurance schedule / Chubb Collections | `INSURANCE_APPRAISAL` |
| Auction house sale estimate | `AUCTION_ESTIMATE` |
| Local dealer/broker pricing (NetJets FMV quote, vehicle dealer) | `DEALER_ESTIMATE` |
| Recent local comps (Zillow, Redfin, BPO) | `COMPARABLE_SALES` |
| County tax assessor | `TAX_ASSESSMENT` |
| Closing statement / purchase receipt | `PURCHASE_PRICE` |
| Insurance replacement-cost endorsement | `REPLACEMENT_COST` |

```
POST /api/v1/tangible-asset/real-property
X-API-Key: {api_key}
Content-Type: application/json

{
  "name": "123 Main Street, City, ST 00000",
  "category": "REAL_PROPERTY",
  "assetType": "PRIMARY_RESIDENCE",
  "description": "6833 sq ft, concrete block, built 1996",
  "serialOrIdentifier": "06-42-47-04-02-000-0390",
  "location": "Palm Beach County, FL",
  "currentValue": 5674000,
  "valuationDate": "2025-12-31",
  "valuationSource": "OWNER_ESTIMATE",
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
  "valuationSource": "DEALER_ESTIMATE",
  "isInsured": true
}
```

```
POST /api/v1/tangible-asset/luxury
{
  "name": "Audemars Piguet Royal Oak",
  "category": "LUXURY",
  "assetType": "WATCH",
  "serialOrIdentifier": "LH0496U",
  "currentValue": 31928,
  "valuationSource": "INSURANCE_APPRAISAL",
  "isInsured": true,
  "insuredValue": 31928
}
```

Available subtype endpoints: `/real-property`, `/vehicle`, `/luxury`, `/collectible`, `/other`.
After creation, add OWNERSHIP relationships (IND→TA with percentage).

**Scheduled items from insurance policies**: If an insurance summary or collections policy
schedules individual items (watches, jewelry, art, wine) with values, create EACH item as a
separate TangibleAsset via the `/luxury` or `/collectible` endpoint. Include:
- `name` — item description (e.g., "Audemars Piguet Royal Oak")
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

### Step 6.2.5: Pre-baked enum mapping table

**Altitude's relationship `relationshipType` enum is smaller than what documents typically
describe.** Historical runs discovered these remappings via 400 errors — apply them
automatically before POSTing to avoid wasted round-trips. Preserve the original semantic
via the `role` field.

| Document-described type | Altitude API type | `role` field | Notes |
|---|---|---|---|
| TRUST_PROTECTOR | TRUSTEE | "Trust Protector" | Trust agreements use this term for oversight role separate from day-to-day trustee |
| SUCCESSOR_TRUST_PROTECTOR | TRUSTEE | "Successor Trust Protector #N" | Include priority |
| INVESTMENT_ADVISOR (directed trust) | TRUSTEE | "Investment Advisor (directed trust)" | Delaware/SD/NV directed trusts split investment and distribution roles from admin trustee. Grantor often serves initially. |
| SUCCESSOR_INVESTMENT_ADVISOR | TRUSTEE | "Successor Investment Advisor #N" | Include priority |
| DISTRIBUTION_ADVISOR (directed trust) | TRUSTEE | "Distribution Advisor" | Separate from Trust Protector in some directed-trust designs |
| ADMINISTRATIVE_TRUSTEE / DELAWARE_TRUSTEE / DIRECTED_TRUSTEE | TRUSTEE | "Administrative Trustee" / "Delaware Trustee" | Corporate trustee whose role is limited to holding the trust's legal situs and ministerial duties. Use this `role` string so downstream queries can distinguish from decision-making trustees. |
| REMOVER (directed trust) | TRUSTEE | "Remover (non-fiduciary)" | Person with power to remove/replace fiduciaries; typically non-fiduciary. |
| SUCCESSOR_REMOVER | TRUSTEE | "Successor Remover #N" | |
| INVESTMENT_COMMITTEE_MEMBER | ADVISOR | "Investment Committee" | |
| POWER_OF_APPOINTMENT_COMMITTEE_MEMBER | ADVISOR | "Power of Appointment Committee" | |
| DISTRIBUTION_COMMITTEE_MEMBER | ADVISOR | "Distribution Committee" | |
| CRUMMEY_POWER_HOLDER | BENEFICIARY | "Crummey Power Holder" | |
| EMPLOYMENT | EMPLOYEE | (firm name + title) | The IND→LE direction requires EMPLOYEE |
| EMPLOYER | EMPLOYEE | (flip source/target first) | Normalize to IND→LE EMPLOYEE |
| FAMILY | SIBLING | "Brother" / "Sister" / "Cousin" | FAMILY is a category, SIBLING is the concrete enum |
| IN_LAWS | FAMILY | "In-law (parent/sibling)" | No direct enum — use FAMILY subtype |
| DONOR | MEMBER | "Donor" | For charitable/DAF contributions |
| FOUNDER | MEMBER | "Founder" | For foundation/LLC formation role |
| MANAGER | OFFICER | "Manager" | LLC managers map to OFFICER type |
| MANAGING_MEMBER | OFFICER | "Managing Member" + pct | Also create MEMBER relationship with pct |
| REGISTERED_AGENT | ATTORNEY | "Registered Agent" | Non-litigation legal role |
| NAMED_INSURED | INSURED | — | Direct mapping |
| INSURED_DRIVER | INSURED | "Driver" | Auto policies list multiple drivers |
| TREASURER | OFFICER | "Treasurer" | |
| SECRETARY | OFFICER | "Secretary" | |
| PRESIDENT | OFFICER | "President" | |
| VICE_PRESIDENT | OFFICER | "Vice President" | |
| CHAIRMAN | OFFICER | "Chairman" | |
| CEO | OFFICER | "Chief Executive Officer" | |
| CFO | OFFICER | "Chief Financial Officer" | |
| COO | OFFICER | "Chief Operating Officer" | |

**Entertainment-industry relationship remaps** (new first-class enums shipped
2026-04-23; on pre-PR environments, fall back to the legacy mapping). These are
distinct from the generic ADVISOR / ACCOUNTANT / ATTORNEY roles — a music
business manager is NOT a CPA, a personal manager is NOT a generic advisor, and
treating them as such loses industry-specific commission structures and
fiduciary-duty differences.

| Document-described type | Altitude API (preferred) | Legacy fallback | `role` field example | Notes |
|---|---|---|---|---|
| Talent agent / booking agent (CAA / WME / UTA) | `TALENT_AGENT` | `ADVISOR` | "Talent Agent — {agency}" | 10% music, 10% film commission |
| Personal manager (Management Firm X) | `PERSONAL_MANAGER` | `ADVISOR` | "Personal Manager — {firm}" | 10-20% commission |
| Business manager (NKSB / Provident / WG&S) | `BUSINESS_MANAGER` | `ACCOUNTANT` | "Business Manager — {firm}" | **NOT a CPA** — handles bill-pay, bookkeeping, insurance, budget |
| Tour manager | `TOUR_MANAGER` | `ADVISOR` | "Tour Manager" | Logistics / road operations |
| Publicist (PMK·BNC / ID / Slate) | `PUBLICIST` | `ADVISOR` | "Publicist — {firm}" | Flat retainer |
| Record-label A&R / label services contact | `RECORD_LABEL_CONTACT` | `ADVISOR` | "A&R — {label}" | Single point of contact at label |
| Producer / collaborator | `PRODUCER_COLLABORATOR` | `ADVISOR` | "Producer — {project}" | Creative, not fiduciary |
| Band member / group partner | `BAND_MEMBER` | `PARTNER` | "Band Member — {band}" | Link Individual→LE(Touring LLC) |
| Co-writer / co-composer | `CO_WRITER` | `PARTNER` | "Co-Writer — {song/catalog}" | Usually per-song splits |
| Sync licensing agent | `SYNC_LICENSING_AGENT` | `ADVISOR` | "Sync Agent — {firm}" | Film/TV/ad licensing |

**Entertainment-industry LegalEntityType remaps** (new first-class enums shipped
2026-04-23 in same PR; pre-PR environments fall back to `CORPORATION` / `LLC` /
`PARTNERSHIP` + description).

| Document-described entity | Altitude API (preferred) | Legacy fallback | Notes |
|---|---|---|---|
| Loan-out corporation ("Client A Loan-Out Corp", "Touring, Inc.") | `LOAN_OUT_CORPORATION` | `CORPORATION` | Detect by 1120/1120S + W-2 to the Individual; standard actor/musician tax structure |
| Talent agency (CAA, WME, UTA, Gersh, ICM) | `TALENT_AGENCY` | `CORPORATION` | |
| Management company (Management Firm X, Y, Z) | `MANAGEMENT_COMPANY` | `CORPORATION` / `LLC` | |
| Record label (UMG, Sony, Warner, Atlantic, Interscope) | `RECORD_LABEL` | `CORPORATION` | |
| Music/book publishing company (Sony/ATV, UMPG, Warner Chappell) | `PUBLISHING_COMPANY` | `CORPORATION` | |
| Production company (Plan B, Happy Madison, Bad Robot; personal LLCs) | `PRODUCTION_COMPANY` | `LLC` / `CORPORATION` | |
| Touring LLC / LP (holds ticketing, crew payroll, tour gear) | `TOURING_LLC` | `LLC` / `LIMITED_PARTNERSHIP` | |
| Merchandise company (brand licensing, D2C merch) | `MERCH_COMPANY` | `LLC` / `CORPORATION` | |

**Fallback strategy**: If your target environment is on a pre-2026-04-23 build,
sending the new enum value returns HTTP 400. Wrap POSTs with a try/fallback:

```python
def post_with_enum_fallback(url, body, preferred_enum_field, preferred_val, legacy_val, role_note):
    body[preferred_enum_field] = preferred_val
    resp = requests.post(url, json=body, headers=headers())
    if resp.status_code == 400 and preferred_val in resp.text:
        body[preferred_enum_field] = legacy_val
        # Preserve the intended role in description/role/notes
        if "role" in body: body["role"] = f"{role_note} (new enum pending deploy)"
        else: body.setdefault("description", "") + f"\n[ONBOARDING] Preferred: {preferred_val}"
        resp = requests.post(url, json=body, headers=headers())
    return resp
```

Record each fallback in `run_state.enum_mappings` so the RM can do a one-shot
post-deploy PATCH to promote legacy-mapped entities to the new enum.

**Account `subCategory` remaps** (account POSTs with document-described values that Altitude rejects):

| Document-described | Altitude API | Notes |
|---|---|---|
| "Private Investment Fund" | LIMITED_LIABILITY_COMPANY | LLC structure |
| "Statutory/Business Trust" | IRREVOCABLE_TRUST | Trust with business purpose |
| "Donor-Advised Fund" | OTHER | DAF not a first-class type; use DAF in name/description |
| "Private Foundation" | OTHER | Use charitableDetails fields |
| "Carried Interest" | OTHER | Include "Carry" in name |
| "CARRY" | OTHER | Same |

**Liability `liabilityType` remaps**:

| Document-described | Altitude API | Notes |
|---|---|---|
| INTRAFAMILY_LOAN | PRIVATE_LOAN | |
| INTERCOMPANY_LOAN | PRIVATE_LOAN | |
| REVOLVING_CREDIT | CREDIT_LINE | |
| HELOC | HOME_EQUITY_LOC | |

**LegalEntity `entityType` remaps**:

| Document-described | Altitude API | Notes |
|---|---|---|
| DONOR_ADVISED_FUND | OTHER | Use charitableDetails |
| PRIVATE_FOUNDATION | FOUNDATION | Verify enum exists; else OTHER |
| DISREGARDED_LLC | LLC | Use `taxClassification=INDIVIDUAL_SOLE_PROPRIETOR_OR_SINGLE_MEMBER_LLC` (there is no `DISREGARDED_ENTITY` enum value — see taxClassification table below) |
| SERIES_LLC | LLC | Note series in description |

**LegalEntity `taxClassification` remaps**:

The only accepted enum values are: `INDIVIDUAL_SOLE_PROPRIETOR_OR_SINGLE_MEMBER_LLC`,
`C_CORPORATION`, `S_CORPORATION`, `PARTNERSHIP`, `TRUST_ESTATE`, `LLC`,
`LLC_C_CORPORATION`, `LLC_S_CORPORATION`, `LLC_PARTNERSHIP`, `RETIREMENT_PLAN`, `OTHER`.
**`GRANTOR_TRUST` and `DISREGARDED_ENTITY` are NOT valid** — they were produced by the
server as 400 errors on the recent run. Apply this table before sending:

| Document-described | Altitude API | Notes |
|---|---|---|
| "Partnership (Form 1065)" | `PARTNERSHIP` | |
| "Disregarded Entity" / "Disregarded LLC" | `INDIVIDUAL_SOLE_PROPRIETOR_OR_SINGLE_MEMBER_LLC` | For single-member LLCs treated as disregarded for tax purposes |
| "C Corporation" / "C-Corp" | `C_CORPORATION` | NOT `C_CORP` |
| "S Corporation" / "S-Corp" | `S_CORPORATION` | NOT `S_CORP` |
| "Grantor Trust" / "Revocable Living Trust" / "IDGT" | `TRUST_ESTATE` | Grantor-trust status lives on `trust.isGrantor`, NOT here |
| "Simple Trust" / "Complex Trust" / "Non-Grantor Trust" | `TRUST_ESTATE` | |
| "Irrevocable Trust" (any flavor) | `TRUST_ESTATE` | |
| "LLC taxed as partnership" | `LLC_PARTNERSHIP` | |
| "LLC taxed as S-Corp" | `LLC_S_CORPORATION` | |
| "LLC taxed as C-Corp" | `LLC_C_CORPORATION` | |
| "IRA" / "401(k)" / "Pension" / "Profit-Sharing Plan" | `RETIREMENT_PLAN` | |

**Apply these proactively.** When building POST payloads, run the values through these
maps before sending. On any unknown enum value that the server rejects with 400, fall
back to `OTHER` (or the closest match above) and record the remap in
`run_state.enum_mappings[<original>]`.

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

- **ALL members get percentage = 100**. The household "owns" 100% of each member. This is
  what drives the valuation rollup — each member's account values roll up fully to the
  household. Do NOT use 50/50 for couples or 0 for children.
- **isPrimary**: Set to true for the first G1 member only.
- Use generational roles (G1/G2/G3) in the `role` field for display purposes only.

> **⚠ Why 100% each (not split shares) — READ THIS, the rule is counterintuitive.**
>
> First-time readers consistently flag "100% per member" as a bug: surely two spouses
> at 100% each is 200% ownership? In every *other* Altitude relationship (IND→LE,
> IND→ACCT), `percentage` on OWNERSHIP means **fractional economic interest** and must
> sum to ≤ 100% across owners. Household-Individual OWNERSHIP is the **one exception**
> where `percentage` encodes **attribution weight** instead.
>
> The rollup engine computes `Household.netWorth = Σ (member.netWorth × memberPercentage / 100)`.
> - If you set each spouse to 50%, the household shows half the family's true net worth.
> - If you set children to 0% (intuitive, since they're not economic owners), their
>   UTMA / custodial / beneficiary-interest accounts never roll up and the household
>   dashboard underreports.
> - Setting every member to 100% makes the sum equal the **full family** wealth — which
>   is what the household view is supposed to display.
>
> Think of it as "which members contribute fully to the household rollup?" not "what
> fraction of the member's net worth does the household own?". For cases where a
> member should NOT contribute fully (e.g. an adult child living at home whose own
> holdings shouldn't inflate the parents' household dashboard), create them as a
> separate household rather than fractional membership.
>
> Future readers scanning this code for the first time ALWAYS mistake this for a bug.
> Do not "fix" it to 50/50.

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

### Step 7.0: Create an upload session FIRST (REQUIRED)

**You MUST create an upload session before any file uploads.** Generating a random UUID and
passing it as `sessionId` fails with HTTP 404 `Document upload session not found`.

```bash
curl -s -X POST "${BASE}/document-upload-session" \
  -H "X-API-Key: ${API_KEY}" -H "X-Firm-Id: ${FIRM_ID}" \
  -H "Content-Type: application/json" \
  -d '{"sessionName": "the household onboarding upload"}'
```

Returns:
```json
{"id": "<uuid>", "status": "In Progress", "autoCompleteAfterHours": 24, ...}
```

Use the returned `id` as the `sessionId` query parameter in every upload call that follows.
The session auto-completes after 24 hours if not explicitly closed. Endpoint is **singular**
(`/document-upload-session`), not plural.

**Explicitly close the session after uploads finish** (not required — auto-closes at 24h —
but cleaner for audit):

```bash
# ⚠ Close is POST, NOT PATCH. PATCHing returns 405 "Method Not Allowed".
curl -s -X POST "${BASE}/document-upload-session/${SESSION_ID}/complete" \
  -H "X-API-Key: ${API_KEY}"
```

Other useful session verbs (per api.json 2026-04-22):
- `GET /document-upload-session/{id}` — retrieve session details
- `GET /document-upload-session/{id}/status` — status only
- `GET /document-upload-session/{id}/documents` — all documents uploaded in this session
- `POST /document-upload-session/{id}/complete` — close session
- `DELETE /document-upload-session/{id}` — cancel session
- `PATCH /document-upload-session/{id}` — update sessionName/metadata only (NOT complete)

### Large-file split recipe (nginx 10 MB upload ceiling)

Uploads of roughly **≥10 MB** are rejected by nginx with `413 Request Entity Too Large`
(empirically: 11.9 MB and 14.2 MB both failed; 9.1 MB and 7.4 MB both succeeded). For any
file larger than ~9 MB, split it first and upload each part separately with a
`Part N of M` suffix in the title:

```bash
# Count pages
python3 -c "from pypdf import PdfReader; print(len(PdfReader('big.pdf').pages))"

# Split in half (or thirds if still too big)
qpdf big.pdf --pages big.pdf 1-30 -- /tmp/big_part1of2.pdf
qpdf big.pdf --pages big.pdf 31-60 -- /tmp/big_part2of2.pdf
ls -la /tmp/big_part*.pdf   # verify each <10MB
```

If a single page contains most of the weight (e.g. a high-res scanned image), compress it:
```bash
pdftocairo -jpeg -r 100 -jpegopt quality=60 big.pdf /tmp/out
# then rebuild PDF from the JPGs
```

Record split parts in the upload plan with titles like `<Original Title> — Part 1 of 2`.

### contentType enum (EXACT values accepted by API — use precisely)

Altitude's `DocumentContentType` enum accepts exactly these 18 values — nothing else:

```
CSV, DOC, DOCX, GIF, HTML, JPG, JSON, MP3, MP4,
PDF, PNG, PPT, PPTX, TXT, XLS, XLSX, XML, ZIP
```

**NOT supported** (must be converted before upload): `EML`, `MD`, `MSG`, `RTF`, `HEIC`, `TIF/TIFF`, `WEBP`.

**File-extension → contentType mapping** (use this exactly — NEVER pass `OTHER`, `EML`, or `MARKDOWN`):

| Extension | contentType | Notes |
|---|---|---|
| `.pdf` | `PDF` | |
| `.docx` | `DOCX` | |
| `.doc` | `DOC` | |
| `.xlsx` | `XLSX` | |
| `.xls` | `XLS` | |
| `.pptx` | `PPTX` | |
| `.ppt` | `PPT` | |
| `.jpg`, `.jpeg` | `JPG` | |
| `.png` | `PNG` | |
| `.gif` | `GIF` | |
| `.csv` | `CSV` | |
| `.txt` | `TXT` | |
| `.json` | `JSON` | |
| `.xml` | `XML` | |
| `.html`, `.htm` | `HTML` | |
| `.mp3` | `MP3` | |
| `.mp4`, `.mov` (convert) | `MP4` | |
| `.zip` | `ZIP` | |
| `.md` | **convert to `.txt`** then upload as `TXT` | Rename extension + upload |
| `.eml` | **convert to `.txt`** (parse headers+body with Python `email` module) then `TXT` | |
| `.msg` | **convert to `.eml`→`.txt`** or skip | Outlook proprietary; extract-msg library |
| `.rtf` | **convert to `.txt`** via `textutil -convert txt` | |
| `.heic` | **convert to `.jpg`** via `sips -s format jpeg` (macOS) or `heif-convert` | |
| `.tif`, `.tiff` | **convert to `.jpg`** via `sips -s format jpeg -Z 1800 src.tiff --out dst.jpg` (macOS) or `magick src.tiff -resize 1800x1800\> dst.jpg` (cross-platform). Upload as `JPG`. **NEVER convert to PDF** — scanner output is often 50-100MB, and `tiff2pdf` preserves the original size inside a PDF wrapper, still unreadable via Claude Read (hits the 2000px dimension limit) and still rejected by the nginx 10MB upload ceiling. Resize to ≤1800px long-side so Claude can see the image AND the upload fits. | |

**.eml conversion helper** (apply before upload):

```python
# eml_to_txt.py
import email, sys, pathlib
p = pathlib.Path(sys.argv[1])
with open(p, 'rb') as f:
    msg = email.message_from_binary_file(f)
out = [f"From: {msg['From']}", f"To: {msg['To']}", f"Date: {msg['Date']}", f"Subject: {msg['Subject']}", ""]
for part in msg.walk():
    if part.get_content_type() == 'text/plain':
        body = part.get_payload(decode=True)
        if body: out.append(body.decode(errors='replace'))
out_path = p.with_suffix('.txt')
out_path.write_text('\n'.join(out))
print(out_path)
```

Then upload with `contentType=TXT` and `documentSubType=CORRESPONDENCE` only if the
target entity type is `ACCOUNT_FINANCIAL`, `TANGIBLE_ASSET`, `INSURANCE_POLICY`, or
`LIABILITY`. For `INDIVIDUAL` or `LEGAL_ENTITY` targets use `documentSubType=OTHER` —
their enums do NOT include `CORRESPONDENCE` (per api.json 2026-04-22).

## WARNING — Push-agent enum pitfalls (verified on recent production run)

When the push agent processes `document_uploads.json`, it MUST use the EXACT
enum values per the tables in this section. Common mistakes observed on the
recent production run (7 documents required post-push PATCHes):

| Wrong value used | Error | Correct value |
|---|---|---|
| `GOVERNMENT_ID` | 400 | `DRIVERS_LICENSE` / `PASSPORT` / `NATIONAL_ID` / `STATE_ID` — pick the specific type |
| `TAX_RETURN_1040` | 400 | `FORM_1040` |
| `ACCOUNT_STATEMENT` on `/individual/` | 400 (not in IndividualDocumentSubType) | `BANK_STATEMENT` / `INVESTMENT_STATEMENT` — OR route the upload to `/account-financial/{id}/document` instead |
| `ACCOUNT_STATEMENT` on `/account-financial/` | 400 (not in AccountFinancialDocumentSubType) | `BROKERAGE_STATEMENT` / `CUSTODIAL_STATEMENT` / `BANK_STATEMENT` — pick by custodian type |
| `INVESTMENT_STATEMENT` on `/account-financial/` | 400 (not in AccountFinancialDocumentSubType) | `BROKERAGE_STATEMENT` (for brokerage / investment account statements) or `CUSTODIAL_STATEMENT` (for trust-custodied accounts). `INVESTMENT_STATEMENT` is **Individual / LegalEntity-only** — do NOT use it for AccountFinancial uploads. Liu Family Wave 1 hit 10 × HTTP 400 on Schwab statements before remapping. |
| `CORRESPONDENCE` on `/individual/` or `/legal-entity/` | 400 (legitimately not in enum) | Fall back to `OTHER` |
| `ENGAGEMENT_LETTER` (anywhere) | 400 (no such enum exists) | `OTHER` |
| Trust agreements left as `OTHER` | silent (accepted) | `TRUST_AGREEMENT` / `TRUST_AMENDMENTS` / `REVOCABLE_TRUST_DOCUMENT` — always classify trust docs |

Before falling back to `OTHER`, consult the per-entity enum table below — on
the recent run, ~70% of `OTHER` usage was for document types that DID have a
specific enum, but under a different name. Always pick the most specific valid
value from the target entity's enum; only use `OTHER` after confirming no
option fits.

> ⚠ **Per-entity-type `documentSubType` enums diverge** — verify against the
> api.json schema for the specific entity before assigning. Generic-sounding
> enum names like `INVESTMENT_STATEMENT`, `ACCOUNT_STATEMENT`, `CORRESPONDENCE`,
> and `GOVERNMENT_ID` are NOT universally valid across all entity types. Each
> entity's `*DocumentCreateRequestDto.documentSubType` enum is independent;
> a value valid on Individual may 400 on AccountFinancial and vice-versa.
> See the per-entity enum lists below — and the classifier in this section
> remaps where needed (e.g. `INVESTMENT_STATEMENT` → `BROKERAGE_STATEMENT`
> when the target is `ACCOUNT_FINANCIAL`).

### documentSubType — intelligent selection (NEVER default to OTHER)

Each entity type has its own `documentSubType` enum with rich taxonomies. Classify every
document by filename pattern + content, matching to the most specific valid value. Fall back
to `OTHER` ONLY when nothing fits — and log the unmatched pattern in a `documentSubType_unmatched.json`
artifact so future runs can improve the mapping.

**Per-entity enums** (full lists — discoverable via `Grep "documentSubType" api.json`):

#### IndividualDocumentCreateRequestDto.documentSubType (62 values)

Identity: `PASSPORT`, `DRIVERS_LICENSE`, `ENHANCED_DRIVERS_LICENSE`, `NATIONAL_ID`, `STATE_ID`,
`BIRTH_CERTIFICATE`, `SOCIAL_SECURITY_CARD`, `CITIZENSHIP_CERTIFICATE`, `CERTIFICATE_OF_NATURALIZATION`,
`PERMANENT_RESIDENT_CARD`, `MILITARY_ID`, `GLOBAL_ENTRY_CARD`, `TRIBAL_ID`, `CONSULAR_ID`,
`FOREIGN_VOTER_CARD`, `REFUGEE_TRAVEL_DOCUMENT`, `DIPLOMATIC_ID`

Tax: `FORM_1040`, `FORM_W2`, `FORM_W9`, `FORM_1099_DIV`, `FORM_1099_INT`, `FORM_1099_B`,
`FORM_1099_MISC`, `FORM_1099_R`, `FORM_K1_1065`, `FORM_K1_1120S`, `FORM_W8BEN`, `STATE_TAX_RETURN`,
`PROPERTY_TAX_DOCUMENTS`

Compliance: `ACCREDITED_INVESTOR_VERIFICATION`, `QUALIFIED_PURCHASER_VERIFICATION`,
`AML_QUESTIONNAIRE`, `KYC_DOCUMENTATION`, `FATCA_CERTIFICATION`, `CRS_SELF_CERTIFICATION`,
`OFAC_SCREENING`, `PEP_DISCLOSURE`

Financial: `BANK_STATEMENT`, `INVESTMENT_STATEMENT`, `NET_WORTH_STATEMENT`, `CREDIT_REPORT`,
`EMPLOYMENT_VERIFICATION`, `INCOME_VERIFICATION`, `FINANCIAL_STATEMENT`, `UTILITY_BILL`,
`LEASE_AGREEMENT`, `PROPERTY_DEED`, `MORTGAGE_STATEMENT`

Estate/Legal: `POWER_OF_ATTORNEY`, `NAME_CHANGE_DOCUMENT`, `MARRIAGE_CERTIFICATE`, `DIVORCE_DECREE`,
`COURT_ORDER`, `LIVING_WILL`, `LAST_WILL_AND_TESTAMENT`, `HEALTHCARE_SURROGATE`

Investment: `SUBSCRIPTION_AGREEMENT`, `INVESTMENT_POLICY_STATEMENT`, `INVESTMENT_QUESTIONNAIRE`,
`INVESTOR_ACCREDITATION`

Fallback: `OTHER`

#### LegalEntityDocumentCreateRequestDto.documentSubType (84 values)

Trust: `TRUST_AGREEMENT`, `TRUST_CERTIFICATION`, `TRUST_AMENDMENTS`, `REVOCABLE_TRUST_DOCUMENT`,
`IRREVOCABLE_TRUST_DOCUMENT`, `TRUSTEE_CERTIFICATION`, `BENEFICIARY_DESIGNATION`,
`TRUST_ASSET_SCHEDULE`

Corporate: `ARTICLES_OF_INCORPORATION`, `CERTIFICATE_OF_INCORPORATION`, `CORPORATE_BYLAWS`,
`CORPORATE_RESOLUTION`, `BOARD_MINUTES`, `SHAREHOLDER_MINUTES`, `STOCK_CERTIFICATE`,
`STOCK_LEDGER`, `SHAREHOLDER_AGREEMENT`, `CERTIFICATE_OF_GOOD_STANDING`, `ANNUAL_REPORT`

LLC: `ARTICLES_OF_ORGANIZATION`, `OPERATING_AGREEMENT`, `CERTIFICATE_OF_FORMATION`,
`MEMBER_RESOLUTION`, `MEMBERSHIP_SCHEDULE`, `MANAGER_AUTHORIZATION`

Partnership: `PARTNERSHIP_AGREEMENT`, `CERTIFICATE_OF_LIMITED_PARTNERSHIP`, `GENERAL_PARTNER_AUTHORIZATION`,
`LIMITED_PARTNER_AGREEMENT`, `PARTNERSHIP_INTEREST_SCHEDULE`

Foundation: `FOUNDATION_CHARTER`, `FOUNDATION_BYLAWS`, `BOARD_OF_DIRECTORS_ROSTER`, `GRANT_POLICY`,
`FORM_990`, `FORM_990_PF`, `CHARITABLE_REGISTRATION`, `SOLICITATION_LICENSE`, `TAX_EXEMPT_DETERMINATION`

Registration/Tax: `TAX_IDENTIFICATION`, `BUSINESS_LICENSE`, `BUSINESS_REGISTRATION`, `EIN_CONFIRMATION`,
`DBA_CERTIFICATE`, `PROFESSIONAL_LICENSE`

Entity tax: `FORM_1065`, `FORM_1120`, `FORM_1120S`, `FORM_1041`, `FORM_K1_1065`, `FORM_K1_1120S`,
`FORM_K1_1041`, `FORM_W9`, `FORM_W8BEN_E`, `STATE_TAX_RETURN`, `PROPERTY_TAX_DOCUMENTS`

Compliance: `AML_CERTIFICATION`, `KYC_DOCUMENTATION`, `BENEFICIAL_OWNERSHIP_CERTIFICATION`,
`FATCA_CERTIFICATION`, `CRS_ENTITY_CERTIFICATION`, `OFAC_SCREENING`, `ACCREDITED_INVESTOR_VERIFICATION`,
`QUALIFIED_PURCHASER_VERIFICATION`

Financial: `AUDITED_FINANCIALS`, `BALANCE_SHEET`, `INCOME_STATEMENT`, `CASH_FLOW_STATEMENT`,
`BANK_STATEMENT`, `INVESTMENT_STATEMENT`, `BUSINESS_CREDIT_REPORT`

Other legal: `POWER_OF_ATTORNEY`, `AUTHORIZED_SIGNER_DOCUMENTATION`, `LEGAL_OPINION`,
`INCUMBENCY_CERTIFICATE`, `CORPORATE_SEAL`, `AMENDMENT`, `PROMISSORY_NOTE`, `PERSONAL_GUARANTY`,
`SUBSCRIPTION_AGREEMENT`, `INVESTMENT_POLICY_STATEMENT`, `INVESTOR_QUESTIONNAIRE`, `PPM_ACKNOWLEDGMENT`

Fallback: `OTHER`

#### AccountFinancialDocumentCreateRequestDto.documentSubType (92 values)

Account: `ACCOUNT_AGREEMENT`, `ACCOUNT_APPLICATION`, `TRANSFER_FORM`, `BENEFICIARY_DESIGNATION`,
`CUSTODIAL_STATEMENT`, `CUSTODY_AGREEMENT`, `FEE_SCHEDULE`, `BROKERAGE_STATEMENT`, `MARGIN_AGREEMENT`,
`OPTIONS_AGREEMENT`, `TRADE_CONFIRMATION`, `BANK_STATEMENT`, `VOIDED_CHECK`, `DIRECT_DEPOSIT_FORM`,
`WIRE_INSTRUCTIONS`, `ACH_AUTHORIZATION`

Tax (same extensive list as Individual)

Retirement: `IRA_ADOPTION_AGREEMENT`, `PLAN_DOCUMENT_401K`, `RMD_NOTICE`, `ROLLOVER_CERTIFICATION`

Authorizations + identity (same as Individual) — use CUSTODIAL_STATEMENT / BROKERAGE_STATEMENT /
BANK_STATEMENT / TRADE_CONFIRMATION before OTHER.

> ⚠ `INVESTMENT_STATEMENT` is **NOT** in `AccountFinancialDocumentSubType`. It only
> exists in the Individual and LegalEntity enums. For AccountFinancial-anchored
> brokerage / investment-account statements (Schwab, Fidelity, Morgan Stanley, etc.)
> use `BROKERAGE_STATEMENT`. For trust-custodied accounts use `CUSTODIAL_STATEMENT`.
> Bank checking/savings on an AccountFinancial use `BANK_STATEMENT`. Liu Family Wave 1
> rerun hit HTTP 400 on 10 Schwab statement uploads before this divergence was
> remapped — formalizing the rule here so subsequent fleet runs do not repeat it.

#### TangibleAssetDocumentCreateRequestDto.documentSubType (96 values)

Ownership: `TITLE`, `DEED`, `REGISTRATION`, `BILL_OF_SALE`, `PURCHASE_RECEIPT`, `CERTIFICATE_OF_OWNERSHIP`,
`TRANSFER_DOCUMENT`, `LIEN`, `LIEN_RELEASE`

Valuation: `APPRAISAL`, `VALUATION_REPORT`, `TAX_ASSESSMENT`, `COMPARABLE_ANALYSIS`,
`BROKER_PRICE_OPINION`, `FMV_DETERMINATION`

Insurance: `INSURANCE_POLICY`, `INSURANCE_CLAIM`, `COVERAGE_CERTIFICATE`, `INSURANCE_RIDER`,
`INSURANCE_DECLARATION`, `INSURANCE_BINDER`, `PROOF_OF_INSURANCE`, `INSURANCE_RENEWAL`,
`INSURANCE_CANCELLATION`

Maintenance: `SERVICE_RECORD`, `INSPECTION_REPORT`, `WARRANTY`, `EXTENDED_WARRANTY`,
`REPAIR_INVOICE`, `REPAIR_ESTIMATE`, `MAINTENANCE_LOG`, `RESTORATION_DOCUMENT`, `CONSERVATION_REPORT`

Vehicle-specific: `VEHICLE_HISTORY_REPORT`, `EMISSIONS_CERTIFICATE`, `SAFETY_INSPECTION`,
`AIRWORTHINESS_CERTIFICATE`, `AIRCRAFT_LOGS`, `MARINE_SURVEY`, `COAST_GUARD_DOCUMENTATION`

Real-property: `SURVEY`, `TITLE_INSURANCE`, `HOME_INSPECTION`, `PEST_INSPECTION`,
`ENVIRONMENTAL_ASSESSMENT`, `HOA_DOCUMENTS`, `ZONING_DOCUMENT`, `BUILDING_PERMIT`,
`CERTIFICATE_OF_OCCUPANCY`, `FLOOR_PLANS`

Collectibles: `CERTIFICATE_OF_AUTHENTICITY`, `CERTIFICATE_OF_ORIGIN`, `AUTHENTICATION_REPORT`,
`PROVENANCE_HISTORY`, `AUCTION_DOCUMENTATION`, `CONDITION_REPORT`, `CATALOGUE_RAISONNE`,
`EXHIBITION_HISTORY`, `LITERATURE_REFERENCE`, `EXPERT_OPINION`, `GRADING_CERTIFICATE`,
`ENCAPSULATION_CERTIFICATE`, `CELLAR_INVENTORY`, `STORAGE_RECORDS`, `WINE_PROVENANCE`

Photos: `PRIMARY_PHOTO`, `DETAIL_PHOTO`, `CONDITION_PHOTO`, `RESTORATION_PHOTO`, `DAMAGE_PHOTO`, `PHOTO`

Legal/tax: `LEGAL_AGREEMENT`, `POWER_OF_ATTORNEY`, `TRUST_DOCUMENT`, `LOAN_AGREEMENT`, `MORTGAGE`,
`LEASE_AGREEMENT`, `RENTAL_AGREEMENT`, `BILL_OF_LADING`, `CUSTOMS_DECLARATION`, `IMPORT_EXPORT_DOCUMENT`,
`PROPERTY_TAX`, `DEPRECIATION_SCHEDULE`, `TAX_BASIS`, `EXCHANGE_1031`, `GIFT_TAX_DOCUMENT`,
`ESTATE_TAX_DOCUMENT`, `CHARITABLE_DONATION_RECEIPT`, `ESTATE_APPRAISAL`

Other: `BENEFICIARY_DESIGNATION`, `WILL_EXCERPT`, `DONATION_INTENT`, `RECEIPT`, `CORRESPONDENCE`,
`NOTES`, `OTHER`

#### LiabilityDocumentCreateRequestDto.documentSubType (13 values — small)

`LOAN_AGREEMENT`, `PROMISSORY_NOTE`, `MORTGAGE_DEED`, `COLLATERAL_AGREEMENT`,
`LINE_OF_CREDIT_AGREEMENT`, `REFINANCE_DOCUMENTS`, `AMORTIZATION_SCHEDULE`, `PAYOFF_STATEMENT`,
`ACCOUNT_STATEMENT`, `FORM_1098`, `INSURANCE_CERTIFICATE`, `CORRESPONDENCE`, `OTHER`

#### InsurancePolicyDocumentCreateRequestDto.documentSubType (26 values)

Policy: `POLICY_DECLARATION`, `POLICY_CONTRACT`, `POLICY_AMENDMENT`, `POLICY_RENEWAL`,
`POLICY_SCHEDULE`, `APPLICATION`, `UNDERWRITING_REPORT`

Medical: `MEDICAL_EXAM`, `MEDICAL_RECORDS`

Claims: `CLAIM_FORM`, `CLAIM_CORRESPONDENCE`, `CLAIM_SETTLEMENT`

Billing: `PREMIUM_NOTICE`, `PAYMENT_RECEIPT`, `BILLING_STATEMENT`, `ANNUAL_STATEMENT`,
`ILLUSTRATION`, `IN_FORCE_LEDGER`

Beneficiary: `BENEFICIARY_DESIGNATION`, `BENEFICIARY_CHANGE`, `POWER_OF_ATTORNEY`,
`TRUST_ASSIGNMENT`, `IRREVOCABLE_ASSIGNMENT`, `OWNERSHIP_CHANGE`

Other: `CORRESPONDENCE`, `OTHER`

### Filename → documentSubType classifier (ALWAYS apply before upload)

Use this regex-based classifier; it catches the majority of documents. When a filename
matches multiple patterns, prefer the MORE SPECIFIC one:

```python
# filename_to_subtype.py
import re
def classify(filename: str, entity_type: str) -> str:
    """Return best-guess documentSubType. Never returns OTHER unless truly no match."""
    f = filename.lower()
    # Identity
    if re.search(r'\bdl\b|driver.?s? lic|driver.?s.?license|drivers.?licen', f): return 'DRIVERS_LICENSE'
    if 'passport' in f: return 'PASSPORT'
    if re.search(r'state.?id|national.?id', f): return 'STATE_ID'
    if 'birth.?certif' in f: return 'BIRTH_CERTIFICATE'
    # Tax forms (specific first)
    if re.search(r'\bw-?2\b|\bw2\b', f): return 'FORM_W2'
    if re.search(r'\bw-?9\b|\bw9\b', f): return 'FORM_W9'
    if re.search(r'w-?8ben-?e\b', f): return 'FORM_W8BEN_E' if entity_type == 'LEGAL_ENTITY' else 'FORM_W8BEN'
    if re.search(r'w-?8ben\b', f): return 'FORM_W8BEN'
    if re.search(r'k-?1.*1065|1065.*k-?1', f): return 'FORM_K1_1065'
    if re.search(r'k-?1.*1120s|1120s.*k-?1', f): return 'FORM_K1_1120S'
    if re.search(r'k-?1.*1041|1041.*k-?1', f): return 'FORM_K1_1041'
    if re.search(r'\bk-?1\b', f): return 'FORM_K1_1065'  # default partnership
    if '1099-div' in f: return 'FORM_1099_DIV'
    if '1099-int' in f: return 'FORM_1099_INT'
    if '1099-b' in f: return 'FORM_1099_B'
    if '1099-r' in f: return 'FORM_1099_R'
    if '1099-misc' in f or '1099-nec' in f: return 'FORM_1099_MISC'
    if re.search(r'\b1098\b|mortgage.?interest', f): return 'FORM_1098'
    if re.search(r'\b5498\b', f): return 'FORM_5498'
    if re.search(r'\b1040\b|personal.?tax.?return', f): return 'FORM_1040'
    if re.search(r'\b1065\b|partnership.?return', f): return 'FORM_1065'
    if re.search(r'\b1120s\b|s-?corp.?return', f): return 'FORM_1120S'
    if re.search(r'\b1120\b', f): return 'FORM_1120'
    if re.search(r'\b1041\b|trust.?return|estate.?return', f): return 'FORM_1041'
    if re.search(r'\b990-?pf\b', f): return 'FORM_990_PF'
    if re.search(r'\b990\b', f): return 'FORM_990'
    if re.search(r'\b8949\b', f): return 'FORM_8949'
    # Trust / estate
    if re.search(r'trust.?agreement|trust.?agt\b', f): return 'TRUST_AGREEMENT'
    if re.search(r'trust.?amend|amendment.?and.?restate|restatement', f): return 'TRUST_AMENDMENTS'
    if re.search(r'trust.?certif', f): return 'TRUST_CERTIFICATION'
    if re.search(r'certificate.?of.?trust', f): return 'TRUST_CERTIFICATION'
    if re.search(r'irrevocable', f) and 'trust' in f: return 'IRREVOCABLE_TRUST_DOCUMENT'
    if re.search(r'revocable', f) and 'trust' in f: return 'REVOCABLE_TRUST_DOCUMENT'
    if re.search(r'benefic.*designation|designation.*benefic', f): return 'BENEFICIARY_DESIGNATION'
    # Corporate / LLC / LP
    if re.search(r'articles.?of.?incorp', f): return 'ARTICLES_OF_INCORPORATION'
    if re.search(r'articles.?of.?organ', f): return 'ARTICLES_OF_ORGANIZATION'
    if re.search(r'operating.?agreement', f): return 'OPERATING_AGREEMENT'
    if re.search(r'partnership.?agreement', f): return 'PARTNERSHIP_AGREEMENT'
    if re.search(r'certificate.?of.?formation', f): return 'CERTIFICATE_OF_FORMATION'
    if re.search(r'certificate.?of.?incorp', f): return 'CERTIFICATE_OF_INCORPORATION'
    if re.search(r'certificate.?of.?good.?standing', f): return 'CERTIFICATE_OF_GOOD_STANDING'
    if re.search(r'bylaws', f): return 'CORPORATE_BYLAWS' if entity_type == 'LEGAL_ENTITY' else 'BYLAWS'
    if re.search(r'\bein\b.?letter|ein.?confirm', f): return 'EIN_CONFIRMATION'
    if re.search(r'business.?license', f): return 'BUSINESS_LICENSE'
    if re.search(r'business.?reg|state.?filing|sunbiz', f): return 'BUSINESS_REGISTRATION'
    # Accounts / statements
    if re.search(r'\bstatement\b', f) and ('bank' in f or 'chequing' in f or 'checking' in f or 'savings' in f):
        return 'BANK_STATEMENT'
    if re.search(r'brokerage.?statement|broker.?stmt', f): return 'BROKERAGE_STATEMENT'
    if re.search(r'cap.?acct|capital.?account.?summary', f):
        # INVESTMENT_STATEMENT exists in Individual / LegalEntity enums only.
        # AccountFinancial wants BROKERAGE_STATEMENT — do NOT return INVESTMENT_STATEMENT
        # for that target or the upload returns HTTP 400. (Liu Family Wave 1 — 10 × 400.)
        return 'BROKERAGE_STATEMENT' if entity_type == 'ACCOUNT_FINANCIAL' else 'INVESTMENT_STATEMENT'
    # Generic "investment statement" filename → same divergence applies
    if re.search(r'investment.?statement|inv.?stmt', f):
        return 'BROKERAGE_STATEMENT' if entity_type == 'ACCOUNT_FINANCIAL' else 'INVESTMENT_STATEMENT'
    if re.search(r'trade.?confirm|confirmation', f) and 'account' not in f: return 'TRADE_CONFIRMATION'
    if re.search(r'account.?agreement|acct.?agreement', f): return 'ACCOUNT_AGREEMENT'
    if re.search(r'account.?application|acct.?app|new.?account', f): return 'ACCOUNT_APPLICATION'
    if re.search(r'wire.?instr|dtc.?instr', f): return 'WIRE_INSTRUCTIONS'
    if re.search(r'fee.?schedule', f): return 'FEE_SCHEDULE'
    if re.search(r'margin.?agreement', f): return 'MARGIN_AGREEMENT'
    # Tangible asset
    if re.search(r'\bdeed\b', f): return 'DEED'
    if re.search(r'\btitle\b', f) and 'insurance' not in f: return 'TITLE'
    if re.search(r'title.?insurance', f): return 'TITLE_INSURANCE'
    if re.search(r'bill.?of.?sale', f): return 'BILL_OF_SALE'
    if re.search(r'\bregistration\b.*\b(vehicle|reg)', f) or re.search(r'\breg.?application', f):
        return 'REGISTRATION'
    if re.search(r'appraisal', f): return 'APPRAISAL'
    if re.search(r'valuation|val.?report', f): return 'VALUATION_REPORT'
    if re.search(r'authentic|authenticity|coa\b', f): return 'CERTIFICATE_OF_AUTHENTICITY'
    if re.search(r'provenance', f): return 'PROVENANCE_HISTORY'
    if re.search(r'emissions', f): return 'EMISSIONS_CERTIFICATE'
    if re.search(r'warranty', f): return 'WARRANTY'
    # Insurance
    if re.search(r'policy.?decl|declaration.*polic|declarations.?page', f): return 'POLICY_DECLARATION'
    if re.search(r'policy.?contract|insurance.?contract', f): return 'POLICY_CONTRACT'
    if re.search(r'policy.?amend', f): return 'POLICY_AMENDMENT'
    if re.search(r'policy.?renewal', f): return 'POLICY_RENEWAL'
    if re.search(r'policy.?schedule|schedule.?of.?values', f): return 'POLICY_SCHEDULE'
    if re.search(r'claim.?form', f): return 'CLAIM_FORM'
    if re.search(r'premium.?notice', f): return 'PREMIUM_NOTICE'
    # Liability
    if re.search(r'loan.?agreement', f): return 'LOAN_AGREEMENT'
    if re.search(r'promissory.?note', f): return 'PROMISSORY_NOTE'
    if re.search(r'mortgage.?deed', f): return 'MORTGAGE_DEED'
    if re.search(r'payoff.?stmt|payoff.?statement', f): return 'PAYOFF_STATEMENT'
    if re.search(r'amortization', f): return 'AMORTIZATION_SCHEDULE'
    # Estate planning docs
    if re.search(r'\bwill\b|last.?will', f): return 'LAST_WILL_AND_TESTAMENT'
    if re.search(r'living.?will', f): return 'LIVING_WILL'
    if re.search(r'healthcare.?surrogate|healthcare.?directive|advance.?directive', f): return 'HEALTHCARE_SURROGATE'
    if re.search(r'power.?of.?attorney|\bpoa\b', f): return 'POWER_OF_ATTORNEY'
    if re.search(r'marriage.?certif', f): return 'MARRIAGE_CERTIFICATE'
    if re.search(r'divorce', f): return 'DIVORCE_DECREE'
    if re.search(r'court.?order', f): return 'COURT_ORDER'
    # Compliance
    if re.search(r'\bkyc\b', f): return 'KYC_DOCUMENTATION'
    if re.search(r'\baml\b', f): return 'AML_CERTIFICATION' if entity_type == 'LEGAL_ENTITY' else 'AML_QUESTIONNAIRE'
    if re.search(r'fatca', f): return 'FATCA_CERTIFICATION'
    if re.search(r'\bcrs\b', f): return 'CRS_ENTITY_CERTIFICATION' if entity_type == 'LEGAL_ENTITY' else 'CRS_SELF_CERTIFICATION'
    if re.search(r'ofac', f): return 'OFAC_SCREENING'
    if re.search(r'accredited', f): return 'ACCREDITED_INVESTOR_VERIFICATION'
    # Financial
    if re.search(r'balance.?sheet', f): return 'BALANCE_SHEET'
    if re.search(r'income.?statement', f): return 'INCOME_STATEMENT'
    if re.search(r'cash.?flow', f): return 'CASH_FLOW_STATEMENT'
    if re.search(r'audited.?financ', f): return 'AUDITED_FINANCIALS'
    if re.search(r'financial.?stat', f): return 'FINANCIAL_STATEMENT'
    if re.search(r'net.?worth', f): return 'NET_WORTH_STATEMENT'
    if re.search(r'credit.?report', f): return 'CREDIT_REPORT'
    # Investment / subscription
    if re.search(r'subscription', f): return 'SUBSCRIPTION_AGREEMENT'
    if re.search(r'ppm|offering.?memorand', f): return 'PPM_ACKNOWLEDGMENT'
    if re.search(r'ips\b|investment.?policy', f): return 'INVESTMENT_POLICY_STATEMENT'
    if re.search(r'investor.?question', f): return 'INVESTOR_QUESTIONNAIRE'
    # Correspondence — NOT in IndividualDocumentSubType or LegalEntityDocumentSubType enums.
    # Per api.json (2026-04-22): only AccountFinancial / TangibleAsset / InsurancePolicy /
    # Liability accept CORRESPONDENCE. For Individual / LegalEntity / Fund / Order / Account,
    # fall back to OTHER — sending CORRESPONDENCE returns HTTP 400.
    # This broke 24/62 uploads on the a recent run before being rewritten.
    _CORR_ALLOWED = {'ACCOUNT_FINANCIAL', 'TANGIBLE_ASSET', 'INSURANCE_POLICY', 'LIABILITY'}
    if re.search(r'email|correspondence|letter\b|meeting.?notes', f):
        return 'CORRESPONDENCE' if entity_type in _CORR_ALLOWED else 'OTHER'
    # Receipt
    if re.search(r'receipt|invoice', f):
        if entity_type == 'TANGIBLE_ASSET': return 'RECEIPT'
        return 'CORRESPONDENCE' if entity_type in _CORR_ALLOWED else 'OTHER'
    # Unmatched → record + return OTHER
    return 'OTHER'
```

**When `OTHER` is returned**, append the (filename, entityType) pair to
`altitude_review/documentSubType_unmatched.json` for follow-up improvements. The goal
is to drive this list to zero over time.

### Backend enum gap logging (Rule 72)

The `documentSubType_unmatched.json` pattern above is the original instance of a
broader requirement: any time the skill extracts a real-world value that doesn't
fit an existing backend enum, log it as a candidate enum addition for the backend
team rather than silently coercing or fabricating a value.

#### Common enum-bound fields the skill writes to

Discover the authoritative enum values via `Grep` against
`plugins/m62-altitude-onboarding/skills/m62-altitude-onboarding/api-docs/api.json`
under `#/components/schemas/` — the schemas of record for every enum below.
Non-exhaustive list of fields the skill commonly writes:

- `DocumentContentType` (the 18-value file-format enum on every upload)
- per-entity `documentSubType` enums (`IndividualDocumentCreateRequestDto`,
  `LegalEntityDocumentCreateRequestDto`,
  `AccountFinancialDocumentCreateRequestDto`,
  `TangibleAssetDocumentCreateRequestDto`,
  `LiabilityDocumentCreateRequestDto`,
  `InsurancePolicyDocumentCreateRequestDto`)
- `Individual.gender`
- `LegalEntity.entityType`
- `AccountFinancial.accountType` / `accountCategory` / `subCategory`
- `Liability.liabilityType` / `liabilityStatus`
- `InsurancePolicy.policyType` / `policyCategory` / `policyStatus`
- `EntityRelationshipType` (MEMBER, OWNERSHIP, TRUSTEE, BENEFICIARY, GRANTOR,
  ADVISOR, …)
- `BillingFeeStructure` and the fee-arrangement enums
- `TangibleAsset.category` / `assetType`
- `Contact.role` / `jobTitle` taxonomy where enum-typed

This list is not exhaustive — the canonical source is api.json. Any field whose
schema declares an `enum` array applies.

#### When a value doesn't fit

If the extracted value cannot be mapped to any existing enum option without losing
semantic meaning:

1. Pick the closest existing enum option and use it for the actual API write —
   the run does NOT block on enum gaps.
2. Append a structured entry to
   `{household_folder}/altitude_review/backend_enum_gaps.json`:

```json
{
  "household": "<name>",
  "household_id": "<uuid>",
  "generated_at": "YYYY-MM-DDTHH:MM:SSZ",
  "gaps": [
    {
      "field_path": "AccountFinancial.accountType",
      "extracted_value": "Donor Advised Fund",
      "best_existing_match": "BROKERAGE",
      "evidence_file": "Schwab_Statement_2024-12.pdf",
      "frequency": 3,
      "suggested_enum_addition": "DONOR_ADVISED_FUND",
      "rationale": "DAFs have distinct tax treatment and beneficiary structure — coercing to BROKERAGE loses semantics for tax-loss-harvesting + grant tracking"
    }
  ]
}
```

3. The fleet aggregator (separate tooling, not part of this skill) collates
   per-household `backend_enum_gaps.json` files into a fleet-level
   `BACKEND_ENUM_GAPS_<date>.md` for the backend team.

#### Hard prohibitions

- The skill MUST NEVER silently use the literal fallback string when an enum is
  involved without ALSO logging the gap. Specifically: every write of
  `documentSubType` that resolves to the fallback enum value MUST trigger a
  `documentSubType_unmatched.json` append AND, if the underlying real-world
  document type isn't covered by any per-entity enum across the six DTOs, a
  `backend_enum_gaps.json` entry as well.
- The skill MUST NEVER invent or fabricate an enum value (e.g., POSTing
  `accountType: "DONOR_ADVISED_FUND"` when the enum doesn't include it). Coercion
  ALWAYS picks an existing valid value; the gap goes in the JSON.
- Use `best_existing_match` for the actual API write so the run completes.

#### Rule 72 — Log unsupported enum values for backend extension

Any time onboarding extracts a value that does not fit an existing backend enum,
the skill MUST (a) coerce to the closest existing enum option for the API write,
and (b) append a structured entry to
`{household_folder}/altitude_review/backend_enum_gaps.json` capturing
`field_path`, `extracted_value`, `best_existing_match`, `evidence_file`,
`frequency`, `suggested_enum_addition`, and `rationale`. Silent coercion without
logging is forbidden; fabricating or POSTing a non-enum value is forbidden. The
run continues — gap-logging is non-blocking. The fleet aggregator (separate from
this skill) collates per-household JSON into a fleet-level dated markdown report
for the backend team. A run with zero gaps still emits the JSON file
(with `gaps: []`) so the rollup can confirm the check ran.

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
    "title": "Client B - Driver's License",
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
- `entityDisplayName` — human-readable name (e.g., "Client B", "Operating LLC X1")

**Example (shell-agnostic — pseudo-variables in braces, not `${…}` or `%…%`):**
```
# Upload returns {"id": "abc123", ...}
# Then call the association endpoint:
POST {baseUrl}/api/v1/document/abc123/associations
     ?entityType=INDIVIDUAL
     &entityId={individualId}
     &associationType=OWNER
     &entityDisplayName=Client%20B
Headers:
  X-API-Key: {apiKey}
  X-Firm-Id: {firmId}
```

Prefer Python `requests` or `urllib` over shell `curl` — it avoids all cross-shell quoting
issues (bash `${VAR}`, cmd `%VAR%`, PowerShell `$env:VAR`, `--data-binary` quirks) and
works identically on macOS/Linux/Windows:

```python
# post_association.py
import os, sys, requests
base, api_key, firm_id, doc_id, entity_type, entity_id, name = sys.argv[1:8]
r = requests.post(
    f"{base}/api/v1/document/{doc_id}/associations",
    params={"entityType": entity_type, "entityId": entity_id,
            "associationType": "OWNER", "entityDisplayName": name},
    headers={"X-API-Key": api_key, "X-Firm-Id": firm_id},
    timeout=30,
)
r.raise_for_status()
print(r.json())
```

This is idempotent — calling it twice for the same document+entity+type returns the existing
association. Do this for EVERY uploaded document, not just cross-entity ones.

For documents that relate to multiple entities (e.g., a trust agreement that names trustees
and beneficiaries), create additional associations with `associationType=SUBJECT`:
```
POST /api/v1/document/{trustAgreementDocId}/associations?entityType=INDIVIDUAL&entityId={trusteeId}&associationType=SUBJECT&entityDisplayName={trusteeName}
```

### Step 7.9: Post-upload download verification (Rule 70)

**Required after every successful document upload (HTTP 200/201 with a new document
`id`).** A recently-fixed backend bug class returned 200 from the upload but stored a
metadata-only shell with no actual S3 bytes — the document looked uploaded in the
response payload AND in the document-list endpoint, but its content was empty. The
skill MUST catch this by immediately downloading the file back and checking the byte
count.

#### Endpoint

Use the **polymorphic content endpoint** — `GET /api/v1/document/{id}/content`. Per
api.json, this streams the document bytes through the backend (S3 → backend → client
passthrough; no wrappers added) with `Content-Disposition` and the S3-reported
`Content-Type` set on the response. Tenant/firm scope is enforced. This is the right
endpoint for size verification because it exercises the full S3-roundtrip path —
catching cases where `fileSize` on the document row was set correctly but the S3
object itself is empty or truncated.

> An alternative `GET /api/v1/document/{id}/download-url` exists — it returns a
> proxied URL pointing to `/document/{id}/content`. Use the URL form ONLY for very
> large documents (>100 MB) where direct streaming through the verification call
> would exceed memory; the verification path the skill prescribes is `/content`
> directly.

> Note: per-entity download paths (`/api/v1/individual/{individualId}/document/{documentId}/download-url`,
> etc.) and `/api/v1/{entity}/{entityId}/document/{documentId}/download-link` are
> **deprecated** per the api.json refresh in commit 5b439e9 — they will return 410
> Gone after the Sunset date. Use only the polymorphic `/api/v1/document/{id}/content`
> path here.

#### Verification recipe (curl, copy-pasteable)

```bash
# Inputs: DOC_ID (returned id from upload), SOURCE_PATH (file on disk that was uploaded),
#         EXPECTED_CONTENT_TYPE (the contentType enum value used in the upload — PDF, JPG, etc.)
SOURCE_BYTES=$(wc -c < "${SOURCE_PATH}" | tr -d ' ')
SRC_SHA=$(shasum -a 256 "${SOURCE_PATH}" | awk '{print $1}')
VERIFY_OUT=/tmp/verify_${DOC_ID}.bin
HEADERS_OUT=/tmp/verify_${DOC_ID}.headers

curl -s -o "${VERIFY_OUT}" \
  -D "${HEADERS_OUT}" \
  --write-out 'HTTP_CODE=%{http_code}\nSIZE_DOWNLOAD=%{size_download}\nCONTENT_TYPE=%{content_type}\n' \
  -H "X-API-Key: ${API_KEY}" -H "X-Firm-Id: ${FIRM_ID}" \
  "${BASE}/api/v1/document/${DOC_ID}/content"

# Compare body byte count AND content hash to source
DOWNLOAD_BYTES=$(wc -c < "${VERIFY_OUT}" | tr -d ' ')
DL_SHA=$(shasum -a 256 "${VERIFY_OUT}" | awk '{print $1}')
echo "source=${SOURCE_BYTES} downloaded=${DOWNLOAD_BYTES}"
echo "src_sha=${SRC_SHA} dl_sha=${DL_SHA}"
[[ "${SRC_SHA}" == "${DL_SHA}" ]] || { echo "SHA mismatch — content corruption"; }
```

Use `%{size_download}` and `%{http_code}` (curl's write-out variables) so the script
captures byte count and status without dumping bytes to the console; `-D` writes the
response headers to a file for the `Content-Type` and `Content-Length` parse.
SHA256 is computed on the on-disk source and on the downloaded body and compared —
this catches a class of bug that byte-count + content-type cannot: a response with
the correct size and MIME but the wrong bytes (e.g. backend serves a different
document due to S3 key collision, race condition during write, or a content swap).

#### PASS criteria (ALL must hold)

- `HTTP_CODE` is `200`
- `SIZE_DOWNLOAD` > 0
- `SIZE_DOWNLOAD` equals `SOURCE_BYTES` exactly. The `/content` endpoint is a
  passthrough and does not add wrappers, so byte-exact match is the expected
  default. Allow ±256 bytes ONLY if a future api.json revision documents server-side
  re-wrapping; until then, treat any drift as a FAIL.
- response `Content-Type` (from the headers file or curl's `%{content_type}`)
  matches the `contentType` enum value used in the upload (e.g. uploaded as `PDF` →
  response `Content-Type` is `application/pdf`; uploaded as `JPG` → `image/jpeg`;
  uploaded as `TXT` → `text/plain` or `text/plain; charset=...`).
- SHA256 of the GET response body equals SHA256 of the source file on disk
  (`SRC_SHA == DL_SHA`). This is mandatory — size + content-type alone do not
  guarantee the bytes are the file the skill intended to upload.

#### FAIL criteria (ANY triggers FAIL)

- `HTTP_CODE` is 4xx or 5xx
- `SIZE_DOWNLOAD` is 0 (metadata-shell smoking gun)
- `SIZE_DOWNLOAD` < 50% of `SOURCE_BYTES` (likely truncated S3 object)
- `SIZE_DOWNLOAD` differs from `SOURCE_BYTES` by more than the tolerance above
- response `Content-Type` does not correspond to the upload's `contentType` enum
- `SRC_SHA != DL_SHA` (content-corruption case — bytes returned are NOT the bytes
  uploaded, even when size and Content-Type happen to match)

#### On FAIL — log, do not retry

Append a structured entry to
`{household_folder}/altitude_review/phase7_verification_failures.jsonl` (one JSON
object per line):

```json
{"document_id": "<uuid>", "source_path": "<path>", "uploaded_content_type": "PDF", "expected_bytes": 184320, "downloaded_bytes": 0, "src_sha256": "<hex>", "downloaded_sha256": "<hex>", "http_code": 200, "response_content_type": "application/json", "failure_reason": "metadata_shell_zero_bytes | size_mismatch | content_type_mismatch | sha256_mismatch", "occurred_at": "YYYY-MM-DDTHH:MM:SSZ"}
```

Mark the document `verification_status: NOT_VERIFIED` in `run_state.documents[]`.

**Do NOT auto-re-upload on FAIL** — a re-upload risks creating a duplicate document
record without resolving the underlying backend bug. Surface the failure in the
Phase 5 review-style approval flow (or, if Phase 5 has already closed, append to
Phase 8's open-items packet) so the user can decide between (a) manual deletion of
the failing document_id followed by a single re-upload, or (b) escalation to the
backend team.

#### When to verify

Verify EVERY document with a fresh upload response — no sampling, no skipping for
"trusted" content types. This is cheap relative to the cost of shipping a 24-family
fleet rerun where N% of documents are silent shells. Verification adds one
proxied-stream GET per upload; for a 50-document household the bandwidth cost is the
sum of the source files (which already crossed the wire on upload).

#### Rule 70 — Document upload integrity — verify by download

After every successful document upload (HTTP 200/201 with a new `id`), the skill
MUST `GET /api/v1/document/{id}/content` and confirm that the returned body is
(a) non-empty, (b) byte-exact (or within ±256 bytes if and only if a future
api.json documents server-side wrapping), (c) has a response `Content-Type`
consistent with the upload's `contentType` enum, AND (d) has a SHA256 hash equal
to SHA256 of the source file on disk. The SHA256 check is a 2026-04-28
augmentation — observed during Lamond Family Wave 1 verification — and catches
content-corruption cases (S3 key collision, write-race, content swap) where size
and MIME are correct but the bytes returned are from a different document.
Failures are logged to `phase7_verification_failures.jsonl` with both source and
downloaded SHA256, the document is marked `NOT_VERIFIED` in
`run_state.documents[]`, and the failure is surfaced in the user-facing review.
The skill MUST NOT auto-re-upload on FAIL — duplicate-document risk outweighs the
benefit. A run with zero documents uploaded still ends Phase 7 with a (possibly
empty) `phase7_verification_failures.jsonl` so downstream tooling can rely on the
file's presence.

---

## Phase 8: Advisor Open-Items Packet (REQUIRED final output)

After Phase 7 completes, produce a single `.docx` handoff for the Relationship Manager
listing what's still needed to complete the onboarding. This is the primary artifact the
RM uses to close the loop with the client. Without it, the onboarding is not done.

### Output file
Path: `{household_folder}/{Household Name} - RM Open Items {YYYY-MM-DD}.docx`

(Same folder as the source documents — the RM already has it open.)

### Required sections (in this order)

**1. Header block** (plain paragraphs)
- Title: `{Household Name} — Open Items for Relationship Manager`
- `Household: {name}   Date: {Month DD, YYYY}   Firm: {firm name}   Prepared by: Altitude Onboarding System`

**2. "Data Needed to Complete Entity Records" — table**
One row per entity created in Altitude with missing required/important fields that the
client or an external source still has to provide. Columns:
`# | Item | Entity in Altitude | What's Missing | Priority`

Priority is **High / Medium / Low**:
- **High** = blocks a compliance/regulatory milestone (CIP/KYC, expiring ID, missing SSN for a beneficiary, insurance with no policy number but $10M+ death benefit, tax filing deadline)
- **Medium** = blocks valuation accuracy or a planned transaction (account balance missing on a 7-figure account, mortgage terms missing)
- **Low** = nice-to-have (granular details that don't change planning — minor holdings, LLC membership breakdown for a small partnership)

Generate rows directly from the placeholder values / nulls on created entities. Every
field you left blank during Phase 6 because the source docs didn't have it → row here.

**3. "Questions Requiring Client/Advisor Input" — table**
Free-text questions that aren't just missing fields. Columns:
`# | Question | Why It Matters`

Populate from `altitude_review/open_questions.json` (Phase 5 output). Plus any ambiguity
or conflict flagged during Phase 4 (e.g. two different birth dates across documents for
the same person, unclear ownership structure).

**4. "No Action Required (FYI)" — bullet list**
Things the RM should KNOW but doesn't need to act on. Examples:
- Construction / renovation in progress (dollar amounts)
- Leased vs owned signals (e.g. vehicle is leased)
- Marriage / death / move-date facts
- Minor doc exceptions (expired passport card not used as primary ID, etc.)
- Cross-references ("This household shares a joint account with the {other} household")

**5. "Onboarding Completion Summary" — table**
Columns: `Category | Count | Details`. Rows:
- Documents read — total count + "All files in discovery folder processed (zero skipped)" or explicit skip count with reason
- Documents uploaded — created in Altitude (minus duplicates/ref-only)
- Individuals — count + names (new + updated)
- Legal Entities — count + names
- Accounts — count + names
- Contacts — count + breakdown (e.g. "12 professionals + 11 extended family")
- Tangible Assets — count + names
- Liabilities — count + names
- Insurance Policies — count + status
- Relationships — total count (can be approximate — "70+")

### Generation recipe

Use python-docx:
```python
from docx import Document
from docx.shared import Pt
doc = Document()
# title, header paragraphs, then tables with .add_table(rows=1, cols=N)
# table.style = 'Table Grid'
# Iterate over altitude_review/open_items.json (new file) to populate tables
doc.save(f"{household_folder}/{household_name} - RM Open Items {today}.docx")
```

Source `open_items.json` from: `altitude_review/run_state.json` (what got created, with
what fields blank) + `altitude_review/open_questions.json` (free-text asks) + the
extraction cache (cross-reference any "flagged" notes).

### Rules for the packet

1. **Never include PII in the filename** beyond the household name (no SSNs, DOBs, addresses).
2. **Write in the RM's voice**: terse, action-oriented, no "I" or "the agent" references.
   The RM will forward this to other firm team members or even to the client.
3. **Group by priority in the Data Needed table** — Highs at the top, Lows at the bottom.
   Within the same priority, group by entity type for scannability.
4. **Every row in "Data Needed" must reference an entity that EXISTS in Altitude** — link
   it by entity name, not UUID. If the entity was never created (e.g. deferred account),
   surface it in "Questions" instead.
5. **Never fabricate**: if a field is truly unknown AND there's no open-ended question to
   ask, omit the row. Don't pad the packet.

### Example

See `<household-folder>/Family - RM Open Items YYYY-MM-DD.docx`
for a reference example (RM handoff format).

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

   **Protective Order / confidential materials**: If the folder contains a court-issued
   protective order (e.g. `Stipulation re Protective Order`, `12 . Stip re Protective Order
   [F.01.29.26].pdf`), STOP and flag it to the user BEFORE uploading any documents. Ask:
   (a) which files (if any) are subject to the order, (b) whether they can be stored in
   Altitude at all, (c) if yes, whether they need restricted access via supplemental
   attribute or a flag. Do not assume uploads are permitted just because the documents
   are in the folder.

10. **Auth: OAuth for humans, API key for automation.** The skill supports three auth modes
    (see Step 0). For interactive use by a human advisor, prefer OAuth — Altitude hosts its
    own login page, we never see the password, and refresh tokens give a smooth long session.
    For CI, scripts, or unattended automation, API keys are simpler (no browser, no refresh).
    Direct JWT paste is a fallback when neither option is available. The skill's helper
    (`altitude_auth.headers()`) emits the correct `Authorization: Bearer` or `X-API-Key`
    header based on `config.authMode` — examples in this skill show `X-API-Key` for brevity
    but the helper substitutes correctly.

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
    use the appropriate hard-delete endpoint for error correction.

    **Hard-delete patterns are INCONSISTENT across entity types — verify before use:**

    | Entity type | Hard-delete pattern | Notes |
    |---|---|---|
    | LegalEntity | `DELETE /api/v1/legal-entity/{id}?force=true&scope=ALL_TENANTS` | Query params, NO `/hard` path. Without `scope=ALL_TENANTS` returns 404 if entity is already soft-deleted. |
    | Entity-relationship | `DELETE /api/v1/entity-relationship/{id}/hard` | Path suffix. No query params. |
    | Individual / Account / Contact / TA / Liability / Insurance | (verify per-entity; no documented hard-delete for most — soft-delete only) | When in doubt: `GET /api/v1/{entity}/{id}?scope=ALL_TENANTS` to confirm exists, then try one form, fall back to the other. |

    **ALL hard-deletes require ROLE_ADMIN super-admin** (system tenant token via
    `POST /api/v1/authenticate` with `admin@localhost`/`admin`). Firm-admin API keys
    (`ak_live_*`) get **403** on every hard-delete endpoint. If your push agent is
    running with a firm-admin key, fall back to soft-delete and log the FULL UUID
    (see Rule 66) so a subsequent admin pass can clean up.

    **Soft-deleted entity discovery (verification before hard-delete):**
    - `GET /api/v1/legal-entity/{id}` → `404` if soft-deleted (default behavior)
    - `GET /api/v1/legal-entity/{id}?scope=ALL_TENANTS` → `200` with full entity, including
      soft-deleted ones — use this to verify a UUID before hard-delete.
    - `GET /api/v1/entity-relationship/to/{TYPE}/{id}?scope=ALL_TENANTS` and `/from/...`
      **still filter `deleted=true` even with the scope param** — `?scope=ALL_TENANTS`
      crosses tenants but does NOT include soft-deleted rows.
    - **`?includeDeleted=true` DOES surface soft-deleted edges** on the firm-admin `/to/`
      endpoint (verified 2026-04-26 production). This is the recovery path for
      soft-deleted edges blocking re-POST:
      ```
      GET /api/v1/entity-relationship/to/LEGAL_ENTITY/{le_id}?includeDeleted=true
      ```
      Returns active edges PLUS rows with `deleted: true`. Filter for the
      `(source, target, type)` you're trying to re-POST, capture the soft-deleted
      UUID, then `DELETE /api/v1/entity-relationship/{id}/hard` (admin JWT).
      `?includeDeleted=true` does NOT chain with `?scope=ALL_TENANTS` — pick one based
      on whether you need cross-tenant or just deleted-row visibility. **Always log
      full UUIDs when soft-deleting** (Rule 66) so this lookup isn't even necessary.

22. **Identity documents use `OTHER` subtype.** `DRIVERS_LICENSE` and `PASSPORT` subtypes are
    for IdentificationDocument entities, NOT IndividualDocument. When uploading DLs or passports
    via `/api/v1/individual/{id}/document`, use `documentSubType: "OTHER"` with a descriptive
    title like "Client B - Florida Driver's License".

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

    **Why 100% per member is NOT a bug** — this is the single most misread rule in the
    skill. Household-Individual OWNERSHIP `percentage` encodes **attribution weight**
    into the rollup, NOT fractional economic ownership (unlike every OTHER OWNERSHIP
    edge). The rollup is `Household.netWorth = Σ (member.netWorth × memberPct/100)`.
    Setting spouses to 50/50 halves the household's visible wealth; setting children
    to 0 hides their custodial/UTMA holdings entirely. 100% each = the full family
    rolls up. For cases where a member shouldn't fully contribute (adult child
    living at home), use a separate household, not fractional membership. Full
    rationale lives inline in Phase 6.3's OWNERSHIP section — read it once and the
    rule stops looking like a bug.

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
    the SOURCE, and the Contact is the TARGET. Example: `Operating LLC X1 → Registered Agent (ATTORNEY)`,
    NOT `Registered Agent → Operating LLC X1`. The API accepts both directions, but outgoing from the
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
    `biography` noting their relationship ("Client B's father. Named as successor trustee and
    guardian."). Create `ADVISOR` relationship from Household → Contact with role "Family Member".

38. **WINDSTORM is a valid InsurancePolicyCategory.** Use `WINDSTORM` (not `OTHER` or `HOMEOWNERS`)
    for wind/hurricane policies that are separate from base homeowners coverage. This is common
    in Florida and coastal areas where wind is carved out of the homeowners policy.

39. **Files with special characters in filenames break curl.** Filenames containing commas,
    parentheses with periods (e.g., `(LastName, B.).pdf`), or dollar signs cause curl error 26.
    Copy these files to the system temp directory (use Python `tempfile.gettempdir()`) with
    clean names before uploading, then delete the temp copies after upload completes.

40. **Latest-date-wins for field merging.** When the same entity field appears in multiple
    documents (or in Altitude vs documents) with different values, the value from the most
    recent source wins — determined by the document's `asOfDate` (explicit "as of" date,
    execution/signing date, statement period end, filing date, filename-embedded date, or
    file mtime as last resort). See Phase 3.5 Step 0 for the full rule. Exceptions:
    immutable fields (SSN, DOB, EIN, formationDate, taxId) must agree and are flagged as
    hard conflicts on disagreement; historical fields (originalBalance, purchasePrice) keep
    their first confirmed value. For trust restatements, LLC amendments, and policy
    endorsements, the amending document supersedes the original for all mutable fields.

41. **Role replacements retire the old relationship.** When an amendment, restatement, or
    new engagement names a DIFFERENT person in a role previously held by someone else
    (trustee, managing member, advisor, attorney, accountant, officer, named insured): PATCH
    `effectiveTo` on the old relationship to the replacement date, then POST a new
    relationship with `effectiveFrom` = replacement date. Never delete — the historical
    record must survive, and soft-deletes still enforce uniqueness (see rule #21). See
    Phase 4.7 for the full workflow and review table format. If the document is ambiguous
    (e.g., could be an additional co-trustee rather than a replacement), leave the old
    relationship intact and flag in Open Questions.

43. **Approval Q&A trail goes at the root of the household folder, not inside `altitude_review/`.**
    Create `altitude_questions_{YYYY-MM-DD}.md` at `{household_folder}/` (sibling to the
    source subfolders like `Onboarding/`, `Trust & Estate/`, etc., and sibling to
    `altitude_review/`). Populate at Phase 5 with every pre-approval question + severity +
    category. Update in place when the user responds (fill User Response, Resolved, Resolution
    fields). Append new questions under "Post-Approval Questions" as they arise during
    Phase 6/7. Never overwrite prior sessions — the date in the filename gives each session
    its own audit trail. As the final step of Phase 7, upload the Q&A file to the primary
    individual with entity associations to both the Individual and the Household, so the
    decision trail lives inside Altitude too. See Phase 5 → "Approval Q&A Trail" for the
    full template.

42. **Externally-synced accounts (Addepar, Orion, custodian) are READ-ONLY from documents.**
    When an AccountFinancial has an `externalIds[]` entry with a provider or a
    `providerDetails.sourceSystemName` set, the external sync is the source of truth for
    account fields (`accountNumber`, `name`, `custodianId`, `totalMarketValue`,
    `totalCostBasis`, holdings, positions, valuations, etc.). Do NOT PATCH these from
    documents — the next sync will either overwrite the change or produce conflicts. DO
    update non-synced metadata (description, tags, manual notes, ownershipType). When a
    document contains a materially different value for a synced field, include it in the
    "Addepar / External Sync Discrepancies" section of the review (Phase 4.8) so the user
    can investigate the sync rather than overriding it by hand. If a synced account has
    `totalMarketValue == 0` or `lastSyncedAt == null`, raise a blocking alert in the
    review — the sync is probably broken.

44. **SSN vs EIN format — always cross-check before writing.** SSN is 9 digits displayed as
    `XXX-XX-XXXX`; EIN is 9 digits displayed as `XX-XXXXXXX`. When a grantor trust uses the
    grantor's SSN as its tax ID, an onboarding spreadsheet may accidentally copy the EIN into
    the individual's SSN field (or vice versa). Before writing `individual.ssn`, check: does
    this 9-digit value match the EIN of any LegalEntity in the same folder? If yes, flag as
    probable conflation and leave SSN blank until the user confirms.

45. **Resolve name collisions within a family.** Two "Dan"s (father Dan A. Emmett and son
    Daniel W. Emmett), two "John"s (grandfather + grandson), or two "Mary"s are common.
    Never match on first+last name alone within the same household. Require a
    disambiguator: middle initial, DOB, SSN, or explicit role-in-document (grantor vs
    beneficiary, father vs son, trustee vs successor trustee).

46. **Flag expired identification documents.** When extracting DLs, passports, or other IDs,
    record the expiration date. If expired as of the run date, add an OPEN_QUESTION:
    "Client [X]'s [DL/passport] expired on [date]. Verify renewal or request updated
    documentation." Do NOT block entity creation — the individual still exists.

47. **Skip generic templates (Tier 4).** LLM prompt worksheets, generic Addepar schema
    references, blank intake forms, or templates with no populated instance values should
    be classified SKIP with reason "generic template — no family data". Detection heuristic:
    if a doc has > 100 lines of field labels ("Full Name:", "DOB:") with fewer than 10%
    having non-empty values after the delimiter, and no family proper nouns appear, skip.
    See `references/document_type_patterns.md` Generic-Template Detection.

48. **Populate Household.billing from the engagement agreement.** The fee structure maps
    directly. **Use the EXACT enum values per `api.json`**:
    `feeStructure ∈ {FLAT_FEE, AUM_BASED, TIERED, PERFORMANCE_BASED, HOURLY, HYBRID, NONE}`,
    `billingFrequency ∈ {MONTHLY, QUARTERLY, SEMI_ANNUALLY, ANNUALLY}`,
    `billingMethod ∈ {IN_ADVANCE, IN_ARREARS}`. Common patterns:
    - Flat annual fee: `{"feeStructure": "FLAT_FEE", "flatFee": 400000, "billingFrequency": "QUARTERLY", "billingMethod": "IN_ARREARS", "agreementDate": "2025-07-08", "effectiveDate": "2025-07-08"}`
    - Single-rate AUM (% basis): `{"feeStructure": "AUM_BASED", "feePercent": 0.0075, "minimumFee": 25000, "billingFrequency": "QUARTERLY", "billingMethod": "IN_ARREARS"}` — `feePercent` is a DECIMAL (0.0075 = 75 bps).
    - True tiered (multi-bracket): `{"feeStructure": "TIERED", "feeScheduleId": "<uuid>", "billingFrequency": "QUARTERLY", "billingMethod": "IN_ARREARS"}` — requires a separate FeeSchedule entity.
    Always record `agreementDate` (execution) and `effectiveDate` (first billing period
    start) — they may differ.

    **⚠ `feePercent` is silently dropped when `feeStructure=TIERED`.** The PATCH returns
    200, but inspecting the entity afterwards shows `feePercent: null`. The server expects
    tiered structures to carry their rates inside a FeeSchedule (referenced via
    `feeScheduleId`), not inline. If you have a "tiered with minimum + flat first-tier rate"
    description (e.g. "$150k minimum; 65bps for first $100M") and don't yet have a
    FeeSchedule to attach, **store as `AUM_BASED` with `feePercent` + `minimumFee`** and
    add a `notes` line: "Should migrate to TIERED with a fee schedule when one is created".
    This was hit on the a recent CRM update — TIERED looked correct but quietly
    lost the 65bps figure.

    **PATCH-merge gotcha**: `billing` is a nested object. PATCHing `billing` REPLACES the
    whole object — fields you don't include come back as null. If you previously set
    `notes` and now PATCH `billing` with `{feePercent: ..., minimumFee: ...}` only, the
    earlier `notes` are wiped. Either include all desired fields in every PATCH, or read
    the current `billing` first and merge in your changes before sending.

49. **Blank onboarding sheets are not failures.** If `Client Onboarding Information.docx`
    exists but contains only field labels with no filled values, don't abort. Cross-document
    inference from tax returns, account statements, trust agreements, IDs, and insurance
    summaries substitutes. Note in review: "Onboarding sheet was blank — data sourced from
    [list of contributing documents]".

50. **File-cache skip + force bypass.** Before reading a file, consult
    `altitude_review/file_cache.json`. Skip files whose path + (sha256 OR mtime+size) match
    the cached entry unchanged. Log as SKIPPED (cache hit). A user can bypass with
    `force=true` (all files), `force=<glob>` (matching paths), or `no-cache=true`. Always
    re-read when the skill version has changed or the extraction logic has been updated.
    See Phase 2.05 for the orchestrator snippet.

51. **Leased items are tangible assets — CREATE them, don't ask.** When a lease agreement,
    lease schedule, or insurance policy lists a leased vehicle, leased aircraft, leased
    watercraft, or any leased tangible item, create a TangibleAsset for it. Do NOT ask the
    user "is this leased?" as if that's a disqualifier. Leased assets belong to the client's
    effective holdings. Set `acquisitionType: "LEASE"` on the TangibleAsset (merged in PR
    #199 on 2026-04-22) and prefix `name` with `"(Leased) "` so the lease status is
    obvious in every UI. Record lessor, monthly payment, lease term, expiration, and
    mileage allowance in `description`. Create a companion Liability with
    `liabilityType: "AUTO_LOAN"` (for vehicles), `"AIRCRAFT_LOAN"`, `"BOAT_LOAN"`, or
    `"PERSONAL_LOAN"` so the obligation rolls up correctly.

52. **TangibleAsset POST must set `individualId` or `legalEntityId` FK.** The
    `entity_relationship` OWNERSHIP row alone is NOT sufficient for
    `/tangible-asset/by-household/{id}` and `/by-individual/{id}` query endpoints — they
    read the FK column, not the relationship graph. Assets created without the FK become
    invisible in the household detail UI and Household.totalTangibleAssetValue stays null.

    Always pick the primary owner (single IND or LE) and set it on the POST:
    ```
    POST /api/v1/tangible-asset/real-property
    {"name": "...", "category": "REAL_PROPERTY", "assetType": "PRIMARY_RESIDENCE",
     "currentValue": 5000000, "individualId": "<primary owner UUID>"}
    ```
    - Joint spousal ownership → FK = primary G1 spouse, relationship = other spouse at 50%
    - Single-member LLC-owned property → FK = legalEntityId of the LLC
    - Trust-owned → FK = legalEntityId of the trust
    - If you already need `/by-owner/{TYPE}/{id}` results (relationship-traversing
      endpoint, more complete), use that form instead of `/by-individual/` or
      `/by-household/`. See Phase 1.3 note.

53. **LegalEntity = family-controlled ONLY. Everything else is a Contact (or not
    created at all).** Before POSTing a LegalEntity, answer this one question:

    > "Does the household own this, control this, serve as grantor of this, or hold a
    > direct beneficial interest in this as a controlled entity?"

    If YES → LegalEntity. If NO → Contact (if there's a real relationship edge) or skip
    entirely. Drafting attorneys, **corporate trustees**, **trust companies**, schools,
    universities, churches, receiving charities, hospitals, employers, vendors,
    agencies, publishers, clubs — **none of these are LegalEntities**, even when they
    appear prominently in legal instruments.

    **Why this rule exists**: past onboarding runs created LLCs for trust companies
    (Trust Company X, Trust Company Y, Bank Trust Z), schools, receiving
    charities, law firms (Law Firm X, Y, Z), management firms, talent agencies,
    and publishers. None of those institutions are family-owned — putting them in
    LegalEntity pollutes the ownership hierarchy, shows them up in household rollups
    where they have no place, and confuses the valuation graph. The previous version of
    this rule actually instructed the skill to create LegalEntities for trust companies
    on pattern-match ("fiduciary firms are LegalEntities — NOT Contacts") — that was
    wrong and has been reversed per the recent review.

    **Decision table** (run BEFORE deciding LegalEntity vs Contact vs skip):

    | Entity type in documents | Create as | Why |
    |---|---|---|
    | **Client-established** trust (grantor IS the client) | **LegalEntity** | Client is grantor — they control it |
    | **Client-owned** LLC / corp / LP / partnership | **LegalEntity** | Direct ownership edge |
    | **Client-established** private foundation (client funded and governs) | **LegalEntity** (FOUNDATION) | Controlled by family |
    | **Investment vehicle** client invests in (fund, LP, LLC, hedge fund) — captured individually | **LegalEntity** | Ownership edge target + K-1 origin |
    | **Corporate trustee** named on a client's trust (Trust Company X, Trust Company Y, Bank Trust Z) | **Contact** — NOT LegalEntity | Household does not own them. Model the TRUSTEE relationship as CONTACT→LE. Put firm name in Contact's `lastName` field (Contact has no companyName column) and role/address in `biography`. |
    | **Drafting law firm** that WROTE a trust/will (Law Firm X, Y, Z) | **Contact** for the individual drafting attorney; firm name in biography. If no individual known → single Contact with the firm name as `lastName` + `jobTitle="Drafting attorney"` | No ownership |
    | **Charity / non-profit** named as beneficiary of a client's trust/will (Red Cross, Stanford, Cedars-Sinai) | **Contact** — NOT LegalEntity | Household does not control the charity. Model BENEFICIARY as CONTACT→LE with role="Charitable Beneficiary" |
    | **School / university** the family donates to or attends | **Contact** (or supplemental attribute on the student Individual) — NEVER LegalEntity | Not a family asset |
    | **Receiving church / religious org** | **Contact** | Not family-controlled |
    | **Hospital / healthcare provider** | **NEVER create** unless client's foundation grants to them, in which case a **Contact** on the grant record | Vendor, not family asset |
    | **Business management firm** (Business Manager Firm X, Y, Z) | **Contact(s)** for each specific BM/manager there; firm name in biography | Service provider |
    | **Talent agency** (CAA, WME, UTA) | **Contact** for the specific agent; firm in biography | Service provider |
    | **Record label / Publisher** (Interscope, UMPG, Sony) | **Contact** for the specific A&R / label contact — NOT LegalEntity unless the client has ownership economics via a distinct deal entity (rare) | Service/commercial counterparty |
    | **Insurance carrier** (MassMutual, Hagerty, Allstate, Cincinnati) | **NEVER an LE — NEVER a Contact either.** Use `InsurancePolicy.carrierName` field | That field exists exactly for this |
    | **Insurance brokerage** (Brokerage X, Y, Z) | **Contact** for the specific broker/agent; firm name in biography | Service provider |
    | **Country club / private school / golf club / yacht club** | **NEVER create** — put membership in client's supplemental attributes or biography | Vendor relationship |
    | **Employer** (unless the client owns it via client-owned LE) | **NEVER create** — use `Individual.employerName` field | Employer is not a family-owned entity |
    | **Payroll processor** (Paychex, Gusto, ADP) | **NEVER** — vendor processing infra | Use Schedule H employer-EIN on the client's profile instead |
    | **Aviation vendor** (NetJets, Flexjet, XOJet) | **NEVER** unless client has fractional ownership of a specific tail — then LegalEntity for the fractional-share LLC itself, NOT the vendor | Service provider |
    | **Security / household service** (ASC, landscapers, cleaning) | **NEVER** — vendor | |
    | **Custodian** (Schwab, Fidelity, CNB Securities) | **Custodian entity** (`/api/v1/custodian`), NOT LegalEntity. Existing custodians are shared-reference; look up first | Account.custodianId field |

    **Corporate-as-Contact workaround**: Contact DTO has no `companyName` column (per
    skill's Standard Document Extraction note). For an institution stored as Contact:
    - `firstName = ""` (empty)
    - `lastName = "<full firm legal name>"` (e.g., `"Trust Company X"`)
    - `biography = "<role> — <address if known> — <any additional context>"`
    - `jobTitle = "<concrete role>"` (e.g., `"Corporate Trustee"`, `"Drafting Attorney"`, `"Charitable Beneficiary"`)

    The Contact-with-firm-name-in-lastName looks unusual but is the correct model given
    DTO constraints. Adding a `companyName` / `organizationName` field to Contact is a
    future API improvement.

    **Relationship modeling for Contact trustees**: the relationship matrix lists
    TRUSTEE as IND→LE, but CONTACT→LE TRUSTEE is accepted by the API in practice. If
    the POST is rejected, fall back to (a) listing the corporate trustee in the trust
    entity's `description` or supplemental attribute, OR (b) attaching the shell
    Contact via the trust entity's Contact list — do NOT create a LegalEntity for the
    trust company.

    **Relationship modeling for Contact charities-as-beneficiary**: use CONTACT→LE
    BENEFICIARY with role="Charitable Beneficiary" and `percentage` set to the
    devise/remainder share.

    **Pre-POST checklist for every LegalEntity**:
    1. Is this household the grantor / owner / controlling party of this entity? (If no → STOP, it's a Contact)
    2. Will this entity have at least one active relationship edge pointing to / from the household's graph? (If no → skip entirely)
    3. Can this be captured more accurately via a field (`carrierName`, `employerName`, `custodianId`) instead of an entity? (If yes → use the field)

    Only if all three resolve toward "yes LegalEntity" do you POST the LegalEntity.

    **Corporate-pattern regex for DETECTION only** — useful as a first-pass trigger to
    identify non-natural-person names, which then MUST run through the decision table
    above (they do NOT automatically become LegalEntity — that was the old wrong rule):
    ```python
    CORP_PATTERN = re.compile(
        r"\b(LLC|LLP|LP|Inc|Corporation|Corp|Company|Co\.|Trust Company|Trust Co"
        r"|Bank|N\.A\.|FSB|Services|Group|Holdings|Partners|Associates"
        r"|Capital|Management|Advisors|Fiduciary|Agents?)\b", re.IGNORECASE)
    ```

    **Orphan-LE cleanup heuristic** — periodically sweep a household's LEs for orphans
    (LEs with zero active relationships — typically created under the old wrong rule
    and never wired up):
    ```python
    for le in household_les:
        rels_to = get(f"/entity-relationship/to/LEGAL_ENTITY/{le.id}")
        rels_from = get(f"/entity-relationship/from/LEGAL_ENTITY/{le.id}")
        active = [r for r in rels_to + rels_from if not r.effectiveTo]
        if not active:
            print(f"ORPHAN CANDIDATE: {le.legalName} — candidate for soft-delete")
    ```

    **Real-world example from a recent run**: 15 external-firm LEs (clubs, schools,
    payroll processors, aviation vendors, insurance brokers, management firms, labels,
    drafting law firms) were auto-created under the old pattern-match rule. Zero
    relationships attached. All had to be retroactively soft-deleted. The new
    family-controlled-only test + orphan-LE sweep would have prevented all 15.

54. **Every TRUST LegalEntity needs these detail fields (commonly missed).** Parallel to
    Rule 33 for LLCs.

    **Top-level fields** — PATCH via `/api/v1/legal-entity/{id}`:
    - `jurisdiction` — full state name (e.g., `"Delaware"`) — NOT the same as
      `incorporationState` (which is the 2-letter code)
    - `addressPrincipal` — trust situs, typically the corporate trustee's address
    - `registrationNumber` — drafting-firm document reference; commonly embedded in
      filename as `(243129930.1)` or in the trust cover page

    **Trust governance fields** — nested under `trust.*` but the regular `/legal-entity/{id}`
    PATCH does NOT propagate them (null-safe merge only runs on the dedicated endpoint).
    **Use the trust-governance endpoint**: `PATCH /api/v1/legal-entity/{id}/trust` with
    merge-patch JSON:
    ```
    PATCH /api/v1/legal-entity/{id}/trust
    Content-Type: application/merge-patch+json
    {
      "isGrantor": true,          // grantor trust for income tax purposes (§671-679)
      "isRevocable": false,       // most irrevocable trusts after formation
      "isRestatement": false,
      "governingLaw": "Delaware", // state whose law governs
      "situs": "Delaware",        // where the trust is administered (may differ)
      "hasSpendthriftProvision": true,
      "gstExemptionStatus": "ALLOCATED" | "NOT_ALLOCATED" | "PARTIAL",
      "trustPurpose": "...",
      "perpetuitiesPeriod": "..."
    }
    ```

    **DO NOT use `taxClassification`** on the trust to record grantor-trust status —
    that field is a W-9-style classification enum (`[OTHER, LLC, PARTNERSHIP, S_CORPORATION,
    C_CORPORATION, RETIREMENT_PLAN, TRUST_ESTATE, INDIVIDUAL_SOLE_PROPRIETOR_OR_SINGLE_MEMBER_LLC,
    LLC_PARTNERSHIP, LLC_C_CORPORATION, LLC_S_CORPORATION]`) and does not contain
    `GRANTOR_TRUST`. Use `trust.isGrantor: true` instead.

    **Grantor-trust detection heuristics** (from the trust memo or agreement):
    - "grantor trust for income tax purposes" → `isGrantor: true`
    - §671-679 references, IDGT, "intentionally defective grantor trust" → `isGrantor: true`
    - "non-grantor trust", §678 → `isGrantor: false`
    - GST-exempt dynasty trust alone does NOT imply grantor status — orthogonal

55. **DRAFT vs EXECUTED legal documents — default to "wait, don't create".** Before
    creating a LegalEntity from a trust agreement, operating agreement, articles of
    incorporation, or partnership agreement, check these DRAFT signals:
    - Signature blocks are blank / no countersigned copies present
    - `formationDate` / execution date is blank or "______________, {year}"
    - Filename contains any of: `Draft`, `DRAFT`, `Working`, `Redline`, `Blackline`,
      `v1`, `v2`, `WIP`, `For Review`, `Pending`
    - Cover email says "hoping to finalize…", "sending for your review", "final version
      will follow"

    If ANY signal is present → mark the extracted entity `formationStatus: DRAFT` in the
    extraction cache. In Phase 5, list under a dedicated "Draft Instruments — Creation
    Pending" section asking the user to (a) confirm execution and provide a signed copy,
    or (b) explicitly authorize pre-staging with `formationDate: null` and a `[DRAFT]`
    description prefix.

    Default recommendation: DO NOT create LegalEntity for draft instruments; wait for the
    executed version. Pre-staging is allowed ONLY with explicit user authorization — the
    tradeoff is that once-signed-then-changed drafts produce stale entities, stale
    relationships, and post-hoc correction work.

    Same logic applies to engagement letters / client agreements for `Household.billing` —
    do NOT populate billing fields until the agreement is executed. Extracted fee schedule
    can still be shown in the review as "pending signed agreement."

56. **Non-client family-fiduciary-beneficiary MUST be Individual, not Contact.** Examples
    list "successor trustees" as Contacts and "family members" as Contacts, but the
    relationship matrix requires `BENEFICIARY` to be `IND→LE` (not `CONTACT→LE`). A
    non-client family member who is BOTH a fiduciary on a household LegalEntity AND a
    beneficiary of that LegalEntity therefore cannot be a Contact — they must be an
    Individual.

    Use `parentHouseholdId: null` to keep them outside the household's rollup so their
    unknown/separate wealth is not falsely attributed to the client household. If the
    non-client is purely a fiduciary (e.g., "attorney-in-fact on Client X's POA") with no
    beneficial interest in any household entity, Contact remains the right type.

    Common examples of this pattern:
    - Client's sibling is a beneficiary AND successor trustee of the client's trust →
      Individual (standalone, `parentHouseholdId: null`)
    - Client's parent is a beneficiary of client's trust + named as guardian for minors →
      Individual (standalone)
    - Outside attorney drafts the trust but is not a beneficiary → Contact (ATTORNEY role)
    - Corporate trustee (e.g., Trust Company X) → Contact (TRUSTEE role, with
      firm biography; the corporate trustee relationship is by institution, not by
      individual human)

57. **Class-of-people references without names → Open Questions, not silent drops.**
    Trust agreements, estate plans, and beneficiary clauses routinely reference *classes*
    of real people without listing names — "your parents", "your brother's wife", "any
    child of SEAN's", "all spouses of your descendants", "surviving spouses". Rule #15
    ("Every named person is an entity") only fires on NAMED people, so these unnamed
    class references get silently dropped — losing real family structure that belongs
    in Altitude.

    During Phase 3 extraction, scan every legal instrument for these class phrases and
    emit each as an Open Question:

    | Phrase in document | Inferred entity | Open Question to raise |
    |---|---|---|
    | "your parents" / "the survivor of them" | 2 Individuals (Client X's mom + dad) | Names of Client X's parents. Both living? |
    | "your brother" / "your sister" (named elsewhere) | Confirm as Individual | (already captured via name) |
    | "your brother's wife" / "his spouse" | 1 Individual (sibling's spouse) | Name of [sibling]'s spouse. firm client? |
    | "any child of [Name]'s" / "[Name]'s descendants" | N Individuals | Does [Name] have children? Names, ages, DOBs? |
    | "your future descendants" (contrasted with "any living child of yours") | Signal Client X has NO current children | Confirm Client X has no children today. |
    | "your children" / "your descendants" (without "future") | ≥1 Individual (Client X's kids) | Names, ages, DOBs of Client X's children. |
    | "your spouse" / "your surviving spouse" | 1 Individual (Client X's spouse) | Name, DOB, is she/he a firm client? |
    | "all spouses of your descendants" | Flag for future | Mark class — create as descendants are added |
    | "any issue" / "lineal descendants" | Signal descendants treated as a class | Confirm class membership list at time of drafting |

    **How to detect**: regex for these phrasing patterns in trust/estate instruments.
    Lawyers use these phrases precisely because the class is well-defined in the document
    but needs the list populated by the client. When you see the phrase, the client
    already knows the answer — the skill just needs to ask.

    **What NOT to do**: do NOT guess names, do NOT create placeholder Individuals with
    "Unknown" names, do NOT drop the reference silently. The Open Question is the
    correct artifact — it surfaces the gap to the RM who can fill it during review.

    **Phase 3.7 self-audit addition**: for every trust instrument in the extraction
    cache, verify that the open_questions.json has at least one entry per unnamed-class
    phrase in the document. If the trust mentions "your parents" but there's no
    parent-related question, that's a silent drop — add the question.

    Spousal-status inference rule: if a trust's fiduciary-exclusion clause explicitly
    names the GRANTOR'S SPOUSE alongside other classes ("your spouse, your descendants'
    spouses, your brother's wife"), treat as weak positive signal that the grantor is
    married. If the clause excludes others' spouses but NOT the grantor's own spouse,
    treat as weak negative signal (grantor likely unmarried at drafting time). Always
    surface as an Open Question — never auto-create a SPOUSE relationship on inference
    alone.

58. **EVERY Liability + InsurancePolicy POST needs a paired OWNERSHIP relationship POST.**
    (Companion to Rule 52 for TangibleAsset.) Creating a Liability or InsurancePolicy
    entity without an OWNERSHIP edge to an owner means the record is invisible to
    `/by-household/{id}`, `/by-individual/{id}`, and `/by-owner/{type}/{id}` queries.
    Rule 52 covers the TangibleAsset FK column (`individualId` / `legalEntityId`); this
    rule covers Liability and InsurancePolicy which do NOT have an equivalent FK — they
    rely ENTIRELY on relationship-graph traversal.

    **On the recent production run**, 9 of 12 liabilities and 10 of 11
    insurance policies were created as orphans. Required post-cleanup: **9 OWNERSHIP
    edges for liabilities + 14 edges for insurance policies (10 OWNERSHIP + 4 INSURED) =
    23 relationship POSTs** to make the records visible. by-household count went
    2→11 (liabilities) and 0→5 (insurance) after the cleanup.

    **Mandatory rule**: For every Liability/InsurancePolicy in `create_payloads.json`,
    ALSO add an entry to `relationships_to_create.json`:

    ```json
    {
      "sourceEntityType": "INDIVIDUAL" | "LEGAL_ENTITY",
      "sourceEntityId": "<owner UUID>",
      "targetEntityType": "LIABILITY" | "INSURANCE_POLICY",
      "targetEntityId": "<entity UUID>",
      "relationshipType": "OWNERSHIP",
      "percentage": 100
    }
    ```

    **Owner-selection heuristics** (verified on recent run):
    - Mortgage / home insurance (homeowners, flood) → owner = trust that holds the home
      (e.g. Client A Living Trust) OR the primary individual if no trust ownership
    - Auto loan / auto insurance → owner = individual whose name is on the title
    - Personal credit cards → owner = individual
    - Business credit cards (Amex Centurion corporate) → owner = the touring/loan-out LE
    - Life insurance → OWNERSHIP = ILIT trust (if policy is trust-owned) or individual;
      ALSO add INSURED relationship from the insured individual to the policy
    - Disability insurance → OWNERSHIP + INSURED both from the insured individual
    - Commercial / E&O / umbrella for a business → owner = the business LegalEntity

    For InsurancePolicy, the INSURED edge is separate from OWNERSHIP. When the owner
    and insured are different (e.g. ILIT-owned life insurance on the grantor), create
    BOTH edges — the OWNERSHIP edge drives rollup visibility, the INSURED edge drives
    "policies on this person" queries.

    **Self-audit before Phase 6 execution**: for every Liability/InsurancePolicy slug
    in `create_payloads.json`, grep `relationships_to_create.json` for a matching
    target-slug OWNERSHIP entry. If missing, FAIL the push and add the edge before
    retrying.
60. **⛔ REVOCABLE TRUST → grantor MUST also get an OWNERSHIP 100% edge, not just GRANTOR.**

    Altitude's household/valuation rollup traversals walk **only OWNERSHIP edges**.
    GRANTOR/TRUSTEE/BENEFICIARY edges are NOT considered ownership. If a revocable
    trust is created with only GRANTOR/TRUSTEE/BENEFICIARY edges from the grantor
    Individual, the trust LegalEntity becomes an **orphan from the household's
    perspective** — `parentHouseholdId` never propagates, `/by-owner/HOUSEHOLD/{id}`
    excludes the trust and everything it holds, and the household net-worth rollup
    silently under-reports by the value of the trust's holdings.

    This is economically correct: a grantor of a revocable trust has **full economic
    ownership** under IRC §671 (the trust is disregarded for income tax; grantor is
    taxed as if owning the trust assets directly). Modeling as OWNERSHIP 100% matches
    the IRS view.

    **The rule** — for every revocable trust created during onboarding, emit **TWO
    edges** from each grantor Individual: GRANTOR (estate-planning semantic) AND
    OWNERSHIP 100% (economic rollup semantic):

    ```json
    // GRANTOR — who established the trust
    {
      "sourceEntityType": "INDIVIDUAL", "sourceEntityId": "<grantor>",
      "targetEntityType": "LEGAL_ENTITY", "targetEntityId": "<revocable trust>",
      "relationshipType": "GRANTOR",
      "effectiveFrom": "<trust execution date>"
    }
    // OWNERSHIP — economic rollup edge (REQUIRED for revocable trusts)
    {
      "sourceEntityType": "INDIVIDUAL", "sourceEntityId": "<grantor>",
      "targetEntityType": "LEGAL_ENTITY", "targetEntityId": "<revocable trust>",
      "relationshipType": "OWNERSHIP",
      "percentage": 100,
      "isPrimary": true,
      "role": "Grantor (revocable trust — equivalent economic ownership per IRC §671)",
      "effectiveFrom": "<trust execution date>"
    }
    ```

    ### Decision matrix — when to emit OWNERSHIP alongside GRANTOR

    **Two kinds of OWNERSHIP edges exist — economic vs. visibility.** Altitude's rollup
    traversal walks OWNERSHIP edges only. If an irrevocable trust has no OWNERSHIP edge
    from anything in the household, `/by-owner/HOUSEHOLD/{id}` cannot reach the trust,
    its beneficiaries, or any assets it holds — the trust + everything inside it is
    invisible from the household page even though the family's advisor is clearly
    tracking it.

    To resolve this without misstating estate inclusion:

    | Edge type | Source → Target | Percentage | Means |
    |---|---|---|---|
    | **Economic OWNERSHIP** | Individual → Trust | **100%** (or per-contribution split) | Grantor retains IRC §671 ownership; trust value rolls into grantor's net worth |
    | **Visibility OWNERSHIP** | **HOUSEHOLD** → Trust | **0%** | Trust is reachable from `/by-owner/HOUSEHOLD/{id}` but value does NOT roll into household net worth (`0 × value = 0`). `role` field documents: "Visibility only — irrevocable trust, outside household estate" |

    The HOUSEHOLD (not the grantor Individual) is the source of the visibility edge,
    which makes the semantic clean: the *household's advisor* administers the trust;
    the *grantor* does not economically own it.

    **Updated matrix** — every trust connected to the household gets at least a
    visibility OWNERSHIP edge from HOUSEHOLD; revocable trusts get BOTH the visibility
    edge AND an economic edge from the grantor Individual:

    | Trust type | Individual → trust GRANTOR | Individual → trust OWNERSHIP (economic) | HOUSEHOLD → trust OWNERSHIP (visibility) | Rationale |
    |---|---|---|---|---|
    | Revocable living trust (X Living Trust) | ✅ | ✅ 100% | ✅ 0% | Grantor retains control + IRC §671. Visibility edge for graph traversal; economic edge for rollup. Double-count guard: rollup should prefer the Individual→trust 100% edge over HOUSEHOLD→trust 0% — value rolls up through the Individual's household membership. |
    | Joint revocable trust | ✅ each | ✅ each (50/50 or per contrib) | ✅ 0% | Same pattern, per-grantor split |
    | Revocable sub-trusts during grantor's life | ✅ | ✅ 100% | ✅ 0% | Same |
    | GRAT (Grantor Retained Annuity Trust) | ✅ | ⚠️ annuity interest % | ✅ 0% | Economic edge percentage reflects retained annuity share; visibility edge ensures post-annuity remainder is still trackable |
    | IDGT (Intentionally Defective Grantor Trust) | ✅ | ❌ NO | ✅ **0%** | Completed gift. Visibility-only — NOT in grantor's estate. `role: "Visibility only — IDGT, completed gift"` |
    | ILIT (Irrevocable Life Insurance Trust) | ✅ | ❌ NO | ✅ **0%** | Completed gift. Visibility-only. `role: "Visibility only — ILIT, outside estate"` |
    | GST / Dynasty / Perpetual Trust | ✅ | ❌ NO | ✅ **0%** | Completed gift, multi-gen. Visibility-only. `role: "Visibility only — GST/Dynasty trust"` |
    | Irrevocable Exempt / Nonexempt sub-trusts | ✅ | ❌ NO | ✅ **0%** | Completed gifts at funding. Visibility-only. |
    | QPRT (Qualified Personal Residence Trust) | ✅ | ⚠️ term-interest % | ✅ 0% | Economic edge with retained-term percentage; visibility edge ensures post-term residence is still trackable |
    | CRT / CRAT / CRUT / CLT | ✅ | ⚠️ income-interest % | ✅ 0% | Economic edge for income share; visibility edge for charity-remainder tracking |
    | Grantor DECEASED (formerly revocable) | historical | retire Individual→trust OWNERSHIP at death | ✅ 0% retained | Revocable becomes irrevocable at death; visibility edge still applies until the trust is fully administered |

    **This REVERSES the earlier "several irrevocable trusts in the firm should remain
    unlinked" guidance**: multiple irrevocable trusts all need
    HOUSEHOLD → LegalEntity OWNERSHIP 0% visibility edges. They remain outside estate
    rollup (0% × trust value = 0) but become reachable from the household page.

    **Detection heuristics** during extraction (unchanged, plus visibility rule):
    - `trust.isRevocable == true` → definitive. Emit Individual→trust OWNERSHIP 100% + HOUSEHOLD→trust OWNERSHIP 0%.
    - `trust.isRevocable == false` → definitive. GRANTOR only on Individual edge; HOUSEHOLD→trust OWNERSHIP 0% for visibility.
    - `isRevocable == null` AND filename/name contains "Revocable" / "Living Trust" → assume revocable; emit both economic + visibility; flag confirmation.
    - `isRevocable == null` AND name contains "Irrevocable" / "GST" / "ILIT" / "Exempt" / "Dynasty" / "Defective" / "GRAT" / "QPRT" / "CRT" / "CRUT" / "CLAT" / "CRAT" / "Descendants Trust" → assume irrevocable; HOUSEHOLD→trust OWNERSHIP 0% visibility only; flag confirmation.
    - Document text with "revocable by grantor at any time" / "power of revocation" → revocable.
    - Document text with "irrevocable" + "no power of revocation" → irrevocable.
    - Ambiguous → GRANTOR only on Individual edge + HOUSEHOLD→trust OWNERSHIP 0% + Open Question.

    **Visibility edge POST example** (apply in addition to any Individual-source edges):

    ```json
    // HOUSEHOLD → irrevocable trust — visibility only, not in estate
    {
      "sourceEntityType": "HOUSEHOLD",
      "sourceEntityId": "<household UUID>",
      "targetEntityType": "LEGAL_ENTITY",
      "targetEntityId": "<irrevocable trust UUID>",
      "relationshipType": "OWNERSHIP",
      "percentage": 0,
      "isPrimary": false,
      "role": "Visibility only — irrevocable trust, outside household estate",
      "effectiveFrom": "<trust execution or funding date>"
    }
    ```

    **Individuals inside irrevocable trusts** (beneficiaries, trust protectors, trustees
    who are not otherwise household members) need the same treatment if they should be
    reachable from the household: `HOUSEHOLD → INDIVIDUAL OWNERSHIP 0%` with
    `role: "Visibility only — trust beneficiary (not household member)"`. Do NOT use
    100% — that would (a) claim economic ownership of another human being, and
    (b) incorrectly roll their assets into this household if they have their own.

    ### Also applies to client-owned operating LLCs

    Every client-owned LLC / corporation / LP needs an OWNERSHIP edge from its
    member(s)/shareholder(s), not just MEMBER / MANAGING_MEMBER / PARTNER / OFFICER.
    Without OWNERSHIP, the household rollup can't see the LLC's assets. MEMBER
    captures governance; OWNERSHIP captures economic rollup. Both edges coexist.

    On the a recent review, these operating LLCs were created without
    IND→LE OWNERSHIP edges and thus orphaned: **Operating LLC X1, X2, X3, X4, X5, X6, X7, X8**. All need
    retrofit OWNERSHIP edges.

    ### Third-party / shared entities — still no OWNERSHIP

    The visibility-only rule applies to entities the HOUSEHOLD'S advisor tracks.
    Entities outside that scope still get no OWNERSHIP edge (neither economic nor
    visibility):
    - Entities genuinely held by multiple unrelated client households with no single primary advisor (truly shared co-invest vehicles across multiple firms)
    - External corporate fiduciaries serving many clients' trusts (Trust Company X, Trust Company Y, Trust Company Z) — model as Contact per Rule 53
    - Investment funds clients subscribe to (Generic Fund I/II) — client owns their LP interest edge, fund itself has no single household owner
    - Charitable beneficiary entities (Teen Impact Fund at Children's Hospital) — model as Contact per Rule 53

    In those cases ownership is expressed only through the LP-interest / subscription
    edge, never via parentHouseholdId.

    **Distinction**: "irrevocable trust the grantor established" (visibility edge applies)
    vs. "investment fund many people subscribe to" (no edge). The former is administered
    under this household's engagement; the latter isn't.

    ### API quirks verified on the a recent cleanup run

    Three non-obvious backend behaviors that change how you must call the API:

    **1. POST entity-relationship `percentage: 0` may STILL be normalized to 100
    even on environments where PR #211 is deployed.**

    PR #211 was meant to make `percentage: 0` persist on POST. Verified on a recent
    push: POST with `percentage: 0` was stored as 100 anyway, but PATCH with the
    same value succeeded — suggesting PR #211 fixed only the PATCH path, not the
    POST path. Until this is fully resolved on the backend, ALWAYS use this
    verify-and-patch pattern when posting any OWNERSHIP edge with `percentage: 0`
    (typically Rule 60 visibility edges from HOUSEHOLD → irrevocable trust):

    ```python
    # post_visibility_edge.py
    resp = api.post("/api/v1/entity-relationship", json={
        "sourceEntityType": "HOUSEHOLD", "sourceEntityId": hh_id,
        "targetEntityType": "LEGAL_ENTITY", "targetEntityId": le_id,
        "relationshipType": "OWNERSHIP",
        "percentage": 0,
        "role": "Visibility only — irrevocable trust outside household estate",
    })
    rel_id = resp["id"]

    # MANDATORY verify-and-patch: GET back, check, PATCH if coerced.
    edge = api.get(f"/api/v1/entity-relationship/{rel_id}")
    if float(edge.get("percentage") or 0) != 0.0:
        log.warning(f"POST coerced percentage to {edge['percentage']} — patching back to 0")
        api.patch(f"/api/v1/entity-relationship/{rel_id}", json={"percentage": 0})
        # Re-verify
        edge = api.get(f"/api/v1/entity-relationship/{rel_id}")
        assert float(edge["percentage"]) == 0.0, f"Still {edge['percentage']} after patch"
    ```

    Apply this pattern in Phase 6 to every Rule 60 visibility edge POST. Once the
    backend POST path is confirmed fixed (test: POST percentage:0 and GET returns
    0.0 without PATCH), the patch step can be skipped — but until then, leave it
    in to prevent silent rollup contamination.

    **2. `parentHouseholdId` on Individual is NOT directly PATCHable.**
    PATCH `/api/v1/individual/{id}` with `{"parentHouseholdId": "..."}` returns 200 OK
    but silently no-ops. The field is derived from traversing HOUSEHOLD→INDIVIDUAL
    OWNERSHIP edges, not writable.

    **To parent an Individual to a household**, POST the OWNERSHIP edge:
    ```json
    POST /api/v1/entity-relationship
    {
      "sourceEntityType": "HOUSEHOLD", "sourceEntityId": "<household UUID>",
      "targetEntityType": "INDIVIDUAL", "targetEntityId": "<individual UUID>",
      "relationshipType": "OWNERSHIP",
      "percentage": 100,
      "role": "G1/G2 family member"
    }
    ```

    `propagateParentHousehold` fires inside `save()` and updates the target's
    `parentHouseholdId` column automatically. Verify by re-fetching the Individual —
    `parentHouseholdId` and `owners[]` are now populated.

    The same rule applies to LegalEntity's `parentHouseholdId` — derived from an inbound
    OWNERSHIP edge, not directly PATCHable.

    **3. Soft-deleting an entity with active relationship edges is BLOCKED (409).**
    `DELETE /api/v1/legal-entity/{id}` (soft) returns `409 Entity In Use` if ANY
    non-deleted entity_relationship row references it, even if the referenced entities
    are themselves deleted. The deletion guard counts relationships, not entities.

    Cleanup sequence for blocked soft-deletes:
    1. Query ALL inbound AND outbound relationships via
       `/entity-relationship/to/{TYPE}/{id}` + `/entity-relationship/from/{TYPE}/{id}`
    2. For each relationship ID returned, call `DELETE /entity-relationship/{relId}`
       (soft-delete the edges one at a time — this is allowed without ROLE_ADMIN)
    3. Retry the original `DELETE /api/v1/{entity-type}/{id}` — now unblocked

    `DELETE /entity-relationship/{id}/hard` requires `ROLE_ADMIN` (super-admin), NOT
    firm-admin. API keys (`ak_live_*`) have firm-admin only, so the hard-delete path
    returns 403. Use the soft-delete cascade above instead.

    **Uniqueness caveat (Rule 21)**: soft-deleted relationships still enforce
    `(source, target, type)` uniqueness. If you soft-delete X→Y OWNERSHIP and then POST
    a new X→Y OWNERSHIP, you get 409. For cleanup deletes this isn't a problem (you
    don't recreate what you deleted), but be aware if you're fixing mistaken edges.

    ### Phase 3.7 self-audit addition

    For every LegalEntity in `extraction_cache`, verify:

    1. **Economic-ownership coverage** — if the decision matrix says "Individual→trust
       OWNERSHIP YES" (revocable trusts + client-owned LLCs), both a GRANTOR/MEMBER
       edge AND an OWNERSHIP edge from the same source Individual exist in
       `relationships_to_create.json`. If only GRANTOR/MEMBER exists → FAIL.

    2. **Visibility coverage** — every trust/LE connected to the household (through any
       relationship: GRANTOR, MEMBER, TRUSTEE, BENEFICIARY, etc.) has either an
       economic OWNERSHIP edge OR a HOUSEHOLD→LE OWNERSHIP 0% visibility edge in
       `relationships_to_create.json`. If the LE has only non-OWNERSHIP edges AND no
       household visibility edge → the LE will be invisible from `/by-owner/HOUSEHOLD`
       after push. FAIL.

    This is the bug class that produced orphan trusts on multiple recent runs — some from missing economic ownership, others from
    missing visibility edges on irrevocable trusts.

    ### Retrofit sweep for pre-Rule 60 onboarded households

    For households onboarded before this rule shipped, run a one-shot retrofit.
    Two classes of edges to add:

    (1) **Economic OWNERSHIP** — Individual→trust 100% for revocable trusts and
        Individual→LE 100% for client-owned operating LLCs (rollup correctness).
    (2) **Visibility OWNERSHIP** — HOUSEHOLD→trust 0% for irrevocable trusts
        administered under this household's engagement (graph reachability).

    ```python
    # orphan_ownership_retrofit.py
    #
    # IMPORTANT: This script must be SCOPED TO THE CURRENT HOUSEHOLD ONLY.
    # The earlier firm-wide form `for le in list_legal_entities(firmId,
    # parentHouseholdId=null)` is BANNED — it caused mass cross-household
    # contamination on a prior run when `resolve_household_for_le()` defaulted
    # orphan LEs to the currently-onboarding household, mass-attributing
    # 9 operating LLCs from another family. See "Orphan-LE triage" below for
    # the separate, human-gated pass that handles `parentHouseholdId=null` LEs.
    current_household_id = "<the household being onboarded>"

    # For every LegalEntity already tied to the current household via
    # parentHouseholdId, check if it needs Rule 60 economic + visibility edges.
    for le in list_legal_entities(parentHouseholdId=current_household_id):
        rels = get_to_legal_entity_relationships(le.id)
        household_id = current_household_id  # SCOPED — never default elsewhere

        grantor = find_first(rels, type="GRANTOR", source_type="INDIVIDUAL")
        member  = find_first(rels, type="MEMBER",  source_type="INDIVIDUAL") \
               or find_first(rels, type="MANAGING_MEMBER", source_type="INDIVIDUAL")
        source = grantor or member
        classification = classify_entity(le, source)

        if classification in ("REVOCABLE_TRUST", "OPERATING_LLC_CLIENT_OWNED") and source:
            # Economic edge: Individual → LE 100%
            emit_ownership_edge(
                source_type="INDIVIDUAL", source_id=source.id,
                target_type="LEGAL_ENTITY", target_id=le.id,
                pct=100,
                role=("Grantor (revocable trust — IRC §671)" if grantor else "Member (LLC)"),
            )
            # Visibility edge also, so household page surfaces it consistently
            emit_ownership_edge(
                source_type="HOUSEHOLD", source_id=household_id,
                target_type="LEGAL_ENTITY", target_id=le.id,
                pct=0,
                role="Visibility — revocable/operating entity (rollup via Individual edge above)",
            )
        elif classification in ("IRREVOCABLE_TRUST", "IDGT", "ILIT", "GST", "DYNASTY",
                                "IRREVOCABLE_EXEMPT", "IRREVOCABLE_NONEXEMPT"):
            # Visibility-only — no economic ownership (completed gift)
            emit_ownership_edge(
                source_type="HOUSEHOLD", source_id=household_id,
                target_type="LEGAL_ENTITY", target_id=le.id,
                pct=0,
                role=f"Visibility only — {classification.lower().replace('_', ' ')}, outside household estate",
            )
        elif classification in ("GRAT", "QPRT", "CRT", "CRUT", "CRAT", "CLAT"):
            # Partial economic + visibility. Flag for human confirmation of pct.
            emit_open_question(
                question=f"{le.legalName} ({classification}) — what is the grantor's "
                         "retained economic percentage? Defaulting to HOUSEHOLD→LE 0% "
                         "visibility only pending confirmation.",
            )
            emit_ownership_edge(
                source_type="HOUSEHOLD", source_id=household_id,
                target_type="LEGAL_ENTITY", target_id=le.id,
                pct=0,
                role=f"Visibility only — {classification}, retained-interest % pending confirmation",
            )
    ```

    Operator confirms each candidate. Auto-approve heuristics:
    - Names containing "Revocable" / "Living Trust" → emit BOTH economic 100% + visibility 0%
    - Names containing "Irrevocable" / "Dynasty" / "GST" / "ILIT" / "IDGT" / "Exempt" →
      emit visibility 0% only
    - Names containing "GRAT" / "QPRT" / "CRT" / "CRUT" / "CRAT" / "CLAT" →
      emit visibility 0% + Open Question on retained-interest percentage
    - Third-party / shared / external-fiduciary / subscribed-fund / charitable-recipient
      → no edge (Rule 53 applies — they're Contacts, not LegalEntities)

    ### Orphan-LE triage (SEPARATE pass, NEVER auto-emit edges)

    For LEs with `parentHouseholdId=null`, run a SEPARATE pass that does NOT
    auto-emit any edges:

    ```python
    # orphan_le_triage.py — never auto-attribute orphan LEs
    for le in list_legal_entities(parentHouseholdId=None):
        rels = get_to_legal_entity_relationships(le.id)
        # Find any IND→LE GRANTOR/MEMBER/TRUSTEE/BENEFICIARY edges and check
        # the source individual's parentHouseholdId.
        candidate_households = set()
        for r in rels:
            if r.sourceEntityType == "INDIVIDUAL" and r.relationshipType in (
                "GRANTOR", "MEMBER", "MANAGING_MEMBER", "TRUSTEE", "BENEFICIARY"
            ):
                ind = api_get(f"/individual/{r.sourceEntityId}")
                if ind.get("parentHouseholdId"):
                    candidate_households.add(ind["parentHouseholdId"])

        if len(candidate_households) == 0:
            emit_open_question(
                question=f"LegalEntity '{le.legalName}' is orphan in firm with NO "
                         "individual-owner edges. Is this a leftover from a prior "
                         "mis-onboarding, or does it belong to a household? Manual "
                         "decision required — do NOT auto-attribute.",
            )
        elif len(candidate_households) == 1:
            target_hh = next(iter(candidate_households))
            emit_open_question(
                question=f"LegalEntity '{le.legalName}' looks like it belongs to "
                         f"household {target_hh} (via grantor/member individual edge). "
                         "Confirm before emitting OWNERSHIP edges.",
            )
        else:
            emit_open_question(
                question=f"LegalEntity '{le.legalName}' has individual-owner edges "
                         f"pointing to MULTIPLE households {candidate_households}. "
                         "Manual review required.",
            )
    ```

    **Hard rule**: orphan LE triage NEVER emits edges automatically. Every orphan
    requires human review. Defaulting to "currently-onboarding household" is what
    caused the prior cross-contamination — never repeat that pattern.

    **Special-case "shared investment vehicles"** (per Rule 53 / 60): funds, club
    deals, syndicated investments where multiple unrelated households co-invest.
    These should NEVER get a direct HH→LE edge from any single household — the
    investment is held through individual ownership only. Examples: "Avenue Sports
    Opportunities Fund", "Leadout Capital LP", multi-family-office subscribed
    funds.

63. **Identity documents (DL, passport, NATIONAL_ID, BIRTH_CERTIFICATE, SOCIAL_SECURITY_CARD,
    STATE_ID) are REJECTED on `/individual/{id}/document`.** Backend hard-fails them with:
    *"Identity document types ... cannot be used with IndividualDocument. For identity
    documents, use IdentificationDocument instead."*

    Until a documented `POST` for `IdentificationDocument` is exposed, route DLs / passports
    through one of:

    a) **Upload as `documentSubType: OTHER`** to `/individual/{id}/document` with a
       generic title (e.g. "California Driver License"). **DO NOT put DL number, dates,
       or any structured PII in the `description` field** (Rule 9 violation — sensitive
       data must stay out of freeform text). The structured DL fields (number, expiration,
       state) live on the Individual entity itself, not the document.

    b) When the IdentificationDocument POST endpoint becomes available, MIGRATE these
       docs by re-uploading and DELETE the OTHER-tagged duplicate.

    Tracking: in `run_state.json`, mark identity-document uploads as
    `subTypeWorkaround: "OTHER (identity-doc, awaiting IdentificationDocument endpoint)"`
    so a future migration job can target them.

64. **`PATCH /api/v1/document/{id}` silently DROPS `documentSubType` updates — use
    `PATCH /api/v1/document/{id}/metadata` instead.**

    The generic Document PATCH endpoint returns HTTP 200 + the document body but does
    NOT change `documentSubType`. Verified on a recent production run: PATCH with
    `{"documentSubType":"FINANCIAL_STATEMENT"}` returned 200 yet the GET still showed
    `OTHER`.

    **Correct endpoint** (per api.json `updateDocumentMetadata_3` operation):
    ```
    PATCH /api/v1/document/{id}/metadata
    Content-Type: application/merge-patch+json
    {"documentSubType": "<target>"}
    ```
    Allowed fields on this endpoint: `title`, `description`, `documentType`, `expiresAt`,
    `tags`, `documentSubType`. Null fields are ignored (not cleared).

    This affects **all post-upload re-classification** flows. If your push agent uploads
    everything as `OTHER` and tries to fix it later via the regular PATCH, the fix
    silently fails. Always use `/metadata`.

65. **`FINANCIAL_STATEMENT` is the catch-all for cash-flow / spending / GL / aggregate
    financial analysis docs on Individual.** `IndividualDocumentSubType` doesn't have
    granular enums for "Cash Flow Projection" / "Spending Report" / "General Ledger" /
    "Asset Allocation", but `FINANCIAL_STATEMENT` covers the bucket. Use it for:
    - Cash flow projections (annual / quarterly / monthly)
    - Spending reports / expense detail spreadsheets
    - General Ledger reports (when attached to Individual rather than the Loan-Out LE)
    - Asset Allocation / Net Worth Master spreadsheets (NET_WORTH_STATEMENT also valid
      for net-worth-specific docs)
    - House Expense Comparison
    - Real Estate Investment summaries (when not a deed/title)
    - Credit-card transaction extracts (Amex, Citi, etc.) — **though these would be more
      correctly attached to the corresponding Liability entity; if the Liability
      doc-upload endpoint allows, prefer that over Individual+FINANCIAL_STATEMENT**.

    Documents that should stay `OTHER` because no specific enum applies:
    - Engagement letters / advisory client agreements (no `ENGAGEMENT_LETTER` enum)
    - Estate plan diagrams, internal advisor memos (no `ESTATE_DIAGRAM` enum)
    - Email correspondence (CORRESPONDENCE not in IndividualDocumentSubType — see
      Rule 9-or-document classifier table for the full enum-availability matrix)
    - Meeting notes (no `MEETING_NOTES` enum)
    - Q&A trail / metadata files (no specific enum)

61. **Specific items in standalone documents become their own TangibleAssets — never roll
    into category aggregates.**

    When extraction finds a single watch, ring, painting, sculpture, instrument, or other
    individually-identifiable luxury item in a standalone document (image, certificate of
    authenticity, appraisal, scheduled-items rider), it MUST become its own
    `TangibleAsset` with the most-specific `assetType`. Rolling it into the existing
    category bucket (e.g. "Jewelry Collection" with `assetType=JEWELRY`) loses the
    asset's identity, makes future appraisals impossible to attribute, and prevents the
    image from being correctly associated.

    **Detection signals during Phase 3.5 cross-doc validation**:
    - Single image in folder showing one specific item (watch face, ring close-up,
      painting, vehicle exterior)
    - Certificate of authenticity for a specific named item
    - Appraisal report citing serial number, hallmarks, or specific characteristics
    - Insurance scheduled-items rider listing items individually with values

    **assetType selection** (use the SPECIFIC value, not the category bucket):

    | Detected item | category | assetType (specific) | Wrong (avoid) |
    |---|---|---|---|
    | Wristwatch / pocket watch | LUXURY | `WATCH` | `JEWELRY` |
    | Ring / necklace / bracelet | LUXURY | `JEWELRY` | `LUXURY_OTHER` |
    | Designer handbag (named model) | LUXURY | `HANDBAG` | `JEWELRY` |
    | Painting / sculpture / drawing | COLLECTIBLE | `ART` | `COLLECTIBLE_OTHER` |
    | Wine bottle / case (specific vintage) | COLLECTIBLE | `WINE` | `COLLECTIBLE_OTHER` |
    | Musical instrument (named) | COLLECTIBLE | `MUSICAL_INSTRUMENT` | `OTHER` |
    | Coin / stamp collection sub-item | COLLECTIBLE | `COINS` / `STAMPS` | `COLLECTIBLE_OTHER` |
    | Vehicle (single VIN) | VEHICLE | `CAR` / `MOTORCYCLE` / `BOAT` / `YACHT` / `AIRCRAFT` | `LUXURY_OTHER` |

    **Filename → assetType classifier addition** (extend `filename_to_subtype.py` from
    Phase 7):
    ```python
    # Single-item luxury detection (drives TA creation, not just doc subType)
    if re.search(r'rolex|patek|audemars|cartier|royal.?oak|chronograph|tourbillon|skeleton|perpetual', f, re.I):
        return ('TA_CREATE', 'LUXURY', 'WATCH')
    if re.search(r'hermes|birkin|kelly|chanel|louis.?vuitton', f, re.I):
        return ('TA_CREATE', 'LUXURY', 'HANDBAG')
    if re.search(r'painting|canvas|oil.?on|sculpture|bronze|ed\..?\d+\/\d+', f, re.I):
        return ('TA_CREATE', 'COLLECTIBLE', 'ART')
    ```

    **Document linkage**: the source image becomes the new TA's `PRIMARY_PHOTO`
    document upload (not `OTHER` on the Individual). Order:
    1. Phase 4 creates the TA payload
    2. Phase 6 POSTs the TA + OWNERSHIP edge
    3. Phase 7 uploads the image with `documentSubType=PRIMARY_PHOTO` and association to
       the new TA

    **Surfaced by recent production run**: a single jpeg of a rose-gold skeleton perpetual
    calendar watch was queued as `documentSubType=OTHER` on Individual, with the watch
    rolled into the existing aggregate "Jewelry Collection" TA. Correct: create new
    `WATCH` LUXURY TA, attach image as `PRIMARY_PHOTO`.

62. **Liability-backed asset auto-creation — every secured liability without a linked TA
    must produce a TA creation payload, NOT an Open Question.**

    Rule 29 requires every secured liability to have `linkedTangibleAssetId` set. Rule 30
    requires every vehicle on an auto policy to be a TA. Rule 52 requires the TA to have
    proper FK + OWNERSHIP edge. The recent production run run revealed that Phase 4 was
    deferring this to an Open Question instead of auto-generating the TA — which left
    real assets uncreated and liabilities un-linked.

    **Phase 4 must include a "liability-TA backfill" pass**:

    For every Liability in the universe (existing or extracted) where:
    - `liabilityType` is one of: `MORTGAGE`, `SECOND_MORTGAGE`, `HOME_EQUITY_LOC`,
      `AUTO_LOAN`, `BOAT_LOAN`, `AIRCRAFT_LOAN`, `ART_LOAN`, OR
    - `liabilityName` matches `r'\b(vehicle|auto|car|boat|aircraft|mortgage|loan|lease)\b'`
      AND
    - `linkedTangibleAssetId IS NULL`

    Auto-generate a TA creation payload:

    ```python
    # phase4_liability_ta_backfill.py
    for liab in universe.liabilities:
        if liab.linkedTangibleAssetId: continue
        if liab.liabilityType not in (MORTGAGE, AUTO_LOAN, BOAT_LOAN, AIRCRAFT_LOAN, ART_LOAN, HOME_EQUITY_LOC, SECOND_MORTGAGE):
            continue

        # Inherit owner from liability's existing OWNERSHIP edge
        owner = get_inbound_ownership_source(liab)  # IND or LE

        # Pick TA endpoint by liability type
        endpoint = {
            MORTGAGE: "/tangible-asset/real-property",
            SECOND_MORTGAGE: "/tangible-asset/real-property",
            HOME_EQUITY_LOC: "/tangible-asset/real-property",
            AUTO_LOAN: "/tangible-asset/vehicle",
            BOAT_LOAN: "/tangible-asset/vehicle",
            AIRCRAFT_LOAN: "/tangible-asset/vehicle",
            ART_LOAN: "/tangible-asset/collectible",
        }[liab.liabilityType]

        # Build payload — name from liability name, owner from inheritance
        ta_payload = {
            "name": derive_ta_name(liab.name),  # strip "Loan", "Mortgage", lender prefix
            "category": derive_category(endpoint),
            "assetType": derive_asset_type(liab.liabilityType, liab.name),
            "individualId" if owner.type == "INDIVIDUAL" else "legalEntityId": owner.id,
            "isInsured": True,  # default; verify against insurance schedule
            "valuationSource": "DEALER_ESTIMATE",
            "currentValue": None,  # value pending — open question only for VALUE
        }

        # Liability PATCH to set linkedTangibleAssetId after TA POST
        liability_patch = {
            "endpoint": f"/api/v1/liability/{liab.id}",
            "method": "PATCH",
            "body": {
                "linkedTangibleAssetId": "<TA_UUID_AFTER_POST>",
                "isSecured": True,
                "collateralDescription": ta_payload["name"],
            },
        }

        # Pre-fill OWNERSHIP edge
        ownership_edge = {
            "sourceEntityType": owner.type, "sourceEntityId": owner.id,
            "targetEntityType": "TANGIBLE_ASSET", "targetSlug": ta_payload["slug"],
            "relationshipType": "OWNERSHIP", "percentage": 100,
        }

        emit_create_payload(ta_payload, liability_patch, ownership_edge)
    ```

    **Open Question is allowed** for missing VALUE only, not for whether-to-create. The
    asset's existence is unambiguous — a $300K Porsche loan implies a real Porsche. The
    only thing the user needs to confirm is current market value (and any details
    extraction couldn't determine like VIN).

    **Surfaced by recent production run**: the prior run had 4 vehicle-secured liabilities
    (Porsche 911, Range Rover, Mercedes 300SL, Toyota Sequoia lease) but ZERO
    corresponding TangibleAssets. Phase 4 had deferred this as "OQ #6 — vehicle
    expansion deferred". Per Rule 62, these 4 TAs should have been auto-generated as
    create payloads on first pass.

66. **Always log FULL UUIDs at soft-delete time, not prefixes.**

    Soft-deleted entities and edges are not recoverable by UUID prefix or by walking
    the relationship graph — `/entity-relationship/to/`, `/from/`, and the entity
    `/search` endpoints filter `deleted=true` rows even with `?scope=ALL_TENANTS`. If
    your `run_state.json` records only an 8-character UUID prefix at delete-time, a
    subsequent admin pass cannot rebuild the full UUID to hard-delete the row.

    **When the push agent falls back to soft-delete** (typically because firm-admin
    API keys can't hard-delete per Rule 21), the agent MUST log the FULL UUID in
    `run_state.json`, not just a prefix.

    **Bad** (loses information):
    ```json
    {"action": "soft DELETE Client A→Operating LLC X1 OWNERSHIP dup edge 19bb6ce7", "ts": "..."}
    ```

    **Good** (recoverable later):
    ```json
    {
      "action": "soft DELETE Client A→Operating LLC X1 OWNERSHIP dup edge",
      "fullUuid": "19bb6ce7-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "entityType": "ENTITY_RELATIONSHIP",
      "reason": "duplicate of <other-uuid>",
      "ts": "..."
    }
    ```

    Apply to every soft-delete: entity-relationships, LegalEntities, Individuals,
    Contacts, AccountFinancials, Liabilities, InsurancePolicies, TangibleAssets,
    Documents. Track them under `run_state.softDeletedAwaitingHardDelete[]` so a
    nightly admin sweep can target them by full UUID.

67. **Search & merge endpoints — always pass `parentHouseholdId` AND defense-in-depth
    client-filter.**

    The backend honors `?parentHouseholdId={uuid}` on `/individual`, `/legal-entity`,
    `/account-financial`, `/tangible-asset`, `/liability`, `/insurance-policy`, and
    their `/search?searchFor=X&parentHouseholdId=Y` variants (verified 2026-04-24 PM).
    Phase 4.2 MUST pass it on every search call. Without it, firm-wide search can
    match a same-named entity belonging to a DIFFERENT household and contaminate the
    target household's graph (this happened on a prior run — 9 operating LLCs from
    Family X were mass-attributed to Family Y via a Rule 60 retrofit pass).

    **Required query format on every Phase 4.2 / Phase 4 search:**

    ```
    GET /api/v1/individual/search?searchFor={X}&parentHouseholdId={current_hh_id}
    GET /api/v1/legal-entity/search?searchFor={X}&parentHouseholdId={current_hh_id}
    GET /api/v1/account-financial/search?searchFor={X}&parentHouseholdId={current_hh_id}
    GET /api/v1/tangible-asset/search?searchFor={X}&parentHouseholdId={current_hh_id}
    GET /api/v1/liability/search?searchFor={X}&parentHouseholdId={current_hh_id}
    GET /api/v1/insurance-policy/search?searchFor={X}&parentHouseholdId={current_hh_id}
    ```

    **Defense-in-depth: client-filter every result by `parentHouseholdId`.** Even with
    the backend filter, after every search call, verify each result's
    `parentHouseholdId` equals current household OR is null (orphan). Skip results
    whose `parentHouseholdId` points to a DIFFERENT household:

    ```python
    candidates = api.search(f"/legal-entity/search?searchFor={name}&parentHouseholdId={hh_id}")
    scoped = []
    for c in candidates.get("content", []):
        phh = c.get("parentHouseholdId")
        if phh in (hh_id, None):
            scoped.append(c)
        else:
            log.warning(f"Skipping {c['id']} — belongs to other household {phh}")
    ```

    **Orphan candidates (`parentHouseholdId: null`) need extra scrutiny.** They often
    represent leftover mis-onboarded entities from prior runs. Rather than silently
    claiming them, emit an Open Question: *"LegalEntity X found as orphan in firm —
    is this the current household's entity or leftover from a different onboarding?"*

    **`/contact/search` does NOT support the filter** (Contacts are firm-wide by
    design — external attorneys/CPAs serve multiple households legitimately). After
    the firm-wide Contact search, apply a different test:
    - For each candidate Contact, GET `/entity-relationship/from/HOUSEHOLD/{other_hh}?scope=ALL_TENANTS`
      for any other household whose ID appears in this Contact's relationship graph.
    - Treat as "shared firm-wide Contact" (legitimately reusable) if attached to ≥1
      OTHER active client household — add a new edge from the current household, do
      NOT duplicate.
    - Treat as "this household's exclusive Contact" if attached only to current HH or
      no household at all.
    - Do NOT accidentally claim or PATCH a Contact that's already serving another
      household exclusively without checking ownership intent first.

68. **`GET /household/{id}` rollup counts may be NULL — never trust them as authoritative.**

    `GET /api/v1/household/{id}` may return `primaryIndividualName=None`,
    `totalAccountCount=None`, `totalMarketValue=None`, `totalTangibleAssetValue=None`
    even when the household has dozens of populated entities. The rollup fields are
    computed by a nightly job, not on read; they go stale whenever:
    - The household was just created
    - Entities were created/edited since the last rollup tick
    - The valuation pipeline failed for this firm
    - The HOUSEHOLD→{INDIVIDUAL,LE,ACCOUNT} OWNERSHIP edges aren't yet wired
      (the rollup needs the graph to traverse)

    **Phase 1 must build counts from the per-type list endpoints scoped to
    `parentHouseholdId`**, not from `/household/{id}` rollups:

    ```python
    counts = {
      "individuals":      total(api_get(f"/individual?parentHouseholdId={hh_id}&size=1")),
      "legal_entities":   total(api_get(f"/legal-entity?parentHouseholdId={hh_id}&size=1")),
      "accounts":         total(api_get(f"/account-financial?parentHouseholdId={hh_id}&size=1")),
      "tangible_assets":  total(api_get(f"/tangible-asset?parentHouseholdId={hh_id}&size=1")),
      "liabilities":      total(api_get(f"/liability?parentHouseholdId={hh_id}&size=1")),
      "insurance":        total(api_get(f"/insurance-policy?parentHouseholdId={hh_id}&size=1")),
    }
    ```

    If `/household/{id}` rollups disagree with these counts (e.g., rollup says
    `totalAccountCount=null` but the per-type query returns 15), emit a "rollup
    health check" warning in the Phase 5 review and recommend a manual rollup
    refresh or wait until the nightly job re-runs.

69. **Phase 1.5 — rerun "lookup by prior UUID" pass before re-traversing the graph.**

    When `run_state.json` exists from a prior run, after Phase 1 universe query, do
    a "lookup by prior UUID" pass BEFORE Phase 2:

    For every UUID in prior `run_state.entities.{individuals,legalEntities,accounts,
    tangibleAssets,liabilities,insurancePolicies,contacts,documents}`, GET the entity
    using `?scope=ALL_TENANTS` to include soft-deleted ones.

    Classify each:
    - **Found AND in current universe** → matches as expected, no flag
    - **Found AND NOT in current universe** → entity exists but isn't reachable from
      the household via graph traversal. This is the "orphan since prior run" class
      (entity was created on a prior run, but its inbound OWNERSHIP edge was never
      wired or got deleted). Flag for Phase 6 to wire OWNERSHIP edges.
    - **Soft-deleted** (returned only with `?scope=ALL_TENANTS`) → record in
      `run_state.softDeletedAwaitingHardDelete[]`
    - **404 even with scope=ALL_TENANTS** → entity was hard-deleted; remove from
      `run_state.json`

    This catches the "prior-run-created entities invisible to graph traversal" class
    of bug. On a recent run, 15 TangibleAssets existed in the DB from a prior run but
    were invisible to graph traversal because they had no inbound OWNERSHIP edge —
    Phase 1's standard graph walk missed them entirely. The "lookup by prior UUID"
    pass would have flagged all 15 for Phase 6 OWNERSHIP wiring.

70. **Phase 5 must produce VALIDATED, READY-TO-POST payload bodies — not scope manifests.**

    `create_payloads.json` and `patch_payloads.json` written by Phase 5 must contain
    fully-valid JSON bodies that the push agent can directly POST/PATCH without
    interpretation. They must NOT be high-level "scope manifests" requiring a
    "Phase 5b body generation" step before Phase 6 can run.

    **Bad** (forces Phase 5b body generation):
    ```json
    {"action": "create LE", "name": "Operating LLC X1", "type": "LLC", "owner": "Client A"}
    ```

    **Good** (push agent POSTs directly):
    ```json
    {
      "method": "POST",
      "endpoint": "/api/v1/legal-entity",
      "body": {
        "legalName": "Operating LLC X1",
        "entityType": "LLC",
        "incorporationState": "DE",
        "formationDate": "2022-09-29",
        "taxClassification": "PARTNERSHIP",
        "parentHouseholdId": "<household-uuid>"
      },
      "afterPost": {
        "createOwnership": {
          "sourceEntityType": "INDIVIDUAL",
          "sourceEntityId": "<owner-individual-uuid>",
          "targetEntityType": "LEGAL_ENTITY",
          "targetSlug": "<this-LE-slug-resolved-after-post>",
          "relationshipType": "OWNERSHIP",
          "percentage": 100,
          "role": "Member"
        }
      }
    }
    ```

    The push agent should iterate over `create_payloads.json` and `patch_payloads.json`
    and POST/PATCH each entry directly. If Phase 5 hand-waves the body shape, push
    agents have to re-derive it (and may get it wrong). Surfaced by a recent run where
    Phase 5 emitted scope-only manifests, forcing every household to need a "Phase 5b"
    body generation pass.

71. **Admin JWT and firm-admin API key are NOT interchangeable — entities land in the
    auth's bound tenant.**

    The two auth modes have asymmetric powers AND asymmetric tenant scopes. Picking the
    wrong one for a write creates ghost rows invisible to firm queries.

    | Auth | Read scope | Hard-delete (`/hard`) | POST/PATCH writes | New row's `tenantId` |
    |---|---|---|---|---|
    | **Firm-admin API key** (`X-API-Key: ak_live_...`) | Verita tenant only | **403 forbidden** | OK | Verita's tenant ✓ |
    | **Admin JWT super-admin** (`Authorization: Bearer ...`, `admin@localhost`) | Cross-tenant via `?scope=ALL_TENANTS` | **OK** | OK, but lands in admin's tenant ✗ | Admin's tenant (e.g., `036296f4-...`) |

    **The trap**: POST a new edge with admin JWT → returns 201 → row created with
    `tenantId: <admin tenant>` → invisible to firm-admin `/to/` queries → dashboard shows
    no edge → you POST again with firm-admin → 409 conflict (because row exists in admin
    tenant). Wasted work, plus a ghost row in the wrong tenant.

    **Hybrid auth pattern** (use this for any session that needs hard-delete):
    1. Reads + classification: firm-admin API key
    2. Hard-delete (`/entity-relationship/{id}/hard`): admin JWT
    3. POST/PATCH writes: firm-admin API key (so the new row's tenantId matches)

    **Verification step after admin-JWT writes**: every entity created with admin JWT
    should be GET'd via firm-admin API key. If it returns 404, the row landed in the
    wrong tenant — hard-delete it (admin JWT) and re-POST with firm-admin API key.

    **Practical implications**:
    - Phase B1 / B2 / Phase 6 / Phase 7 should default to firm-admin API key for ALL
      writes. Only Phase B1's clean-up of soft-deleted edges (which is read-then-hard-delete)
      needs admin JWT, and that step never POSTs.
    - When an F1-style "admin sweep" script needs both, structure it as:
      `find_soft_deleted_via_includeDeleted (api_key) → hard_delete (jwt) → re-POST visibility (api_key)`.
    - On the recent Boro-Hamilton recovery, an admin-JWT POST landed the visibility edge
      in `036296f4-...e9b8` (admin tenant), not Verita's `550e8400-...0001`. Firm-admin
      `/to/` showed 0 HH→LE OWNERSHIP edges despite the 201 response. Cleanup: hard-delete
      the wrong-tenant edge, re-POST with API key. Always verify post-write.

---

**Anonymization note**: examples in this skill use placeholder names like 'Client A',
'Family A', 'Firm A', 'Operating LLC X1', 'Trust Company X'. They are NOT real clients.
Any DOBs, SSNs, EINs, addresses, account numbers, or UUIDs shown in examples are
synthetic placeholders, not real data.

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
- Word docs (cross-platform fallback chain):
  1. `textutil -convert txt file.docx` (macOS only)
  2. `pandoc file.docx -t plain` (cross-platform)
  3. Write `docx_read.py` (see SKILL.md → Standard Document Extraction) and run `python docx_read.py "file.docx"` (Python fallback)
- Images: Read tool (Claude has vision)
- Emails: Write `eml_read.py` (see SKILL.md → Standard Document Extraction) and run it
- Spreadsheets: Write `xlsx_read.py` (see SKILL.md → Standard Document Extraction) and run it
- **NEVER use `python -c "..."` with embedded newlines or nested quotes** — it breaks on
  Windows cmd and PowerShell. Always write scripts to a `.py` file first.
- Use `{PYTHON}` from Cross-Platform Setup (`python` on Windows, `python3` elsewhere). Detect with `platform.system()`.

## What to Extract (per file)
For EACH file, append one JSONL line to your cache with:
- file: relative path
- entities.individuals: [{name, dob, ssn, gender, address, email, phone, occupation, employerName, jobTitle}]
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
- `references/altitude_api_endpoints.md` — Detailed search, PATCH, document upload, and relationship endpoints. **Includes the API Response Shape Primer** (paginated wrapper vs bare array).
- `references/document_type_patterns.md` — How to classify documents by filename and content. Includes OCR fallback, Generic-Template SKIP heuristic, and Expired ID detection.
- `references/document_entity_association.md` — Which documents associate with which entity type + documentSubType values
- `references/match_merge_rules.md` — Detailed entity matching and field merge logic. Includes external-ID match priority, SSN/EIN cross-check, same-family name collision rule, and **Structural Corrections** workflow (HARD_DELETE vs MARK_HISTORICAL).
- `references/entity_chains.md` — Multi-generational entity ownership patterns (trust→LLC, GP/LP, holdco manager, ILIT chain) with LE→LE relationship modeling.
