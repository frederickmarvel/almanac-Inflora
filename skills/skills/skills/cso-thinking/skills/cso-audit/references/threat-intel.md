# Threat-intelligence enrichment (Phase 4.5)

> Optional phase. Enriches CVE/GHSA-bearing findings with live exploitability signals from **free, unauthenticated public APIs**. Used in Phase 4.5 of `/cso-audit` when the user opts in (or it's auto-on if internet is reachable and `--no-threat-intel` was not passed).

The goal is to answer the question every static scanner leaves open: **is this vulnerability being exploited right now, or is it a paper risk?** A static `osv-scanner` hit tells you "this version is vulnerable." Threat intel tells you "and CISA flagged it as actively exploited 4 months ago — patch deadline already expired."

---

## Sources

All free, all unauthenticated unless noted. Add no paid dependencies.

### 1. OSV.dev — advisory details + curated references
- **Endpoint:** `https://api.osv.dev/v1/vulns/<id>` (e.g. `GHSA-jf85-cpcp-j695`, `CVE-2019-10744`)
- **Returns:** full advisory body, affected versions, fix versions, aliased IDs (CVE↔GHSA cross-reference), and a `references` array — these often include the original Twitter thread, blog post, PoC repo, that the OSV team curated.
- **Rate limit:** none documented. Polite usage (a few req/sec) is fine.
- **Why it matters:** the `references` array IS the "social signal" — pre-digested and curated. You get the high-value links without scraping Twitter.

### 2. EPSS (FIRST.org) — exploit probability
- **Endpoint:** `https://api.first.org/data/v1/epss?cve=CVE-XXXX-YYYY` (or comma-separated for batch).
- **Returns:** `epss` (probability 0.0–1.0 of exploitation in next 30 days) + `percentile` (relative ranking vs all CVEs).
- **Rate limit:** none documented.
- **Why it matters:** EPSS is trained on dark-web mentions, exploit-PoC repo signals, security-Twitter chatter. Score ≥0.95 = top 5%, model-confident this *will* be exploited soon.

### 3. CISA KEV — known-exploited list (the gold standard)
- **Endpoint:** `https://raw.githubusercontent.com/cisagov/kev-data/main/known_exploited_vulnerabilities.json` (official CISA-maintained GitHub mirror; the canonical `cisa.gov` URL returns 403 to non-browser user agents).
- **Returns:** ~1600 CVEs that CISA has *confirmed* are being actively exploited in the wild, with `dateAdded`, `dueDate` (federal patch deadline), `requiredAction`, `notes`, `knownRansomwareCampaignUse`.
- **Rate limit:** none for GitHub raw content. **Cache locally for 24h** — the file is 1.4MB and only updates daily.
- **Cache path:** `~/.cache/cso-audit/kev.json` (or `${XDG_CACHE_HOME}/cso-audit/kev.json`).
- **Why it matters:** if a CVE is in KEV, the U.S. federal government is **legally required** to patch it within ~14 days. That's the strongest "this is actually being exploited" signal that exists, and it's free.

### 4. NVD — official scoring and reference verification
- **Endpoint:** `https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=CVE-XXXX-YYYY`
- **Returns:** official CVSS v3.1 / v4 scores, vendor refs, CWE mapping, affected configurations.
- **Rate limit:** 5 req/30s without API key, 50 req/30s with a free key (request at https://nvd.nist.gov/developers/request-an-api-key). Batch your CVEs and pace requests.
- **Why it matters:** verifies the scanner-reported CVSS against the authoritative source. Sanity-checks severity claims.

### 5. GitHub Security Advisory — GHSA full text
- **Endpoint:** `gh api graphql -f query='query{securityAdvisory(ghsaId:"GHSA-jf85-cpcp-j695"){summary,description,references{url},vulnerabilities(first:10){nodes{package{ecosystem,name},vulnerableVersionRange,firstPatchedVersion{identifier}}}}}'`
- **Auth:** uses the user's existing `gh auth` token. No new credential.
- **Rate limit:** 5000 req/hour with auth — effectively unlimited for an audit run.

### 6. Hacker News (Algolia) — recent discussion search
- **Endpoint:** `https://hn.algolia.com/api/v1/search?query=<term>&tags=story&hitsPerPage=3`
- **Returns:** top 3 HN stories matching the CVE ID, package name, or vulnerability keyword. Each story has URL, title, points, comments count, posted date.
- **Rate limit:** none documented.
- **Why it matters:** HN is where security postmortems, exploit walkthroughs, and "we got pwned" disclosures show up first — long before they hit NVD. Free, no scraping.

---

## When to enrich (lookup budget)

Don't enrich every finding — most audits produce dozens of low-severity hygiene notes that don't need network calls.

| Finding severity | Enrich? |
|------------------|---------|
| Critical | Always |
| High | Always |
| Medium | First 10 only (in order of appearance) |
| Low | Never (unless they have a CVE *and* the user passed `--threat-intel-all`) |
| Info | Never |

Skip enrichment for findings without a CVE/GHSA identifier — there's nothing to look up.

Budget cap: **at most 25 findings enriched per run**. If more would qualify, enrich the highest-severity 25 and add an `info` finding noting the cap.

---

## Caching

Two layers:

1. **KEV catalog** — single JSON, refresh once per 24h. Path: `~/.cache/cso-audit/kev.json`. If cache is older than 24h, refetch; otherwise reuse.
2. **Per-CVE lookups** — cache `osv.dev`, `epss`, `nvd`, `gh` responses for 6h in `~/.cache/cso-audit/cves/<cve-id>.json`. Multi-audit runs on the same machine (e.g., CI on multiple branches) reuse the cache.

The cache is per-machine, not shared. Stale by design — re-runs after 6h hit the network again to pick up new disclosures.

---

## Severity auto-promotion

Some intel signals are strong enough to **override** the scanner's severity assignment. Apply these rules after enrichment and **always log the change**:

| Rule | Promote to | Why |
|------|------------|-----|
| Listed in CISA KEV | At least **High** | CISA only adds confirmed in-the-wild exploitation |
| KEV `knownRansomwareCampaignUse: "Known"` | At least **Critical** | Active ransomware campaigns are catastrophic |
| EPSS percentile ≥ 0.95 (top 5%) | At least **High** | Model-confident exploitation is imminent |
| EPSS percentile ≥ 0.99 (top 1%) AND public PoC referenced in OSV | At least **Critical** | Combined signals = working exploit + extreme likelihood |
| NVD CVSS 4.0/3.1 base ≥ 9.0 AND scanner reported lower | At least **High** | Scanner underestimated; trust the authoritative score |

Demotion is **not** allowed. Threat-intel never lowers a finding's severity — only raises it.

Every promotion adds to the finding's audit trail:

```yaml
severity_changed_by:
  source: threat-intel
  rule: "CISA KEV listed since 2022-03-25; ransomware campaign use known"
  original_severity: medium
  promoted_to: critical
```

---

## The "Recent activity" block

Each enriched finding gets a new sub-section appended in the SECURITY_AUDIT.md:

```markdown
**Recent activity (fetched 2026-05-21T08:42Z):**
- **NVD CVSS:** 9.1 Critical (matches scanner-reported)
- **EPSS:** 0.943 (percentile 99.2%) — top 1%, model expects exploitation
- **CISA KEV:** ✓ listed 2022-03-25, fed patch deadline 2022-04-08 (expired)
- **Ransomware use:** Known (Conti, BlackCat)
- **OSV references:** snyk advisory ([link](https://snyk.io/vuln/SNYK-JS-LODASH-450202)), watchTowr writeup ([link](https://...)), PoC ([link](https://github.com/...))
- **Recent HN:** ["lodash prototype pollution still in the wild" (412 points, 2026-04-12)](https://news.ycombinator.com/item?id=...)
```

If a particular source was unreachable, name it in the block (don't silently omit):

```markdown
**Recent activity (fetched 2026-05-21T08:42Z):**
- **NVD CVSS:** 9.1 Critical
- **EPSS:** unreachable (api.first.org timeout)
- **CISA KEV:** ✓ listed 2022-03-25 (cache hit, 14h old)
- **OSV references:** 3 found (see finding metadata)
- **Recent HN:** no recent stories
```

---

## Graceful degradation

The static-audit guarantee from Phase 4 must hold even when threat-intel is enabled. Rules:

1. **Any per-source failure** (timeout, 5xx, network error) → that source's slot in the Recent-activity block shows `unreachable (<reason>)`. Continue with the next source.
2. **All sources unreachable** for a finding → omit the Recent-activity block, append a single line `_threat-intel: all sources unreachable for this CVE_`.
3. **Catastrophic failure** (no internet, DNS broken) → after the first 3 consecutive failures, abort Phase 4.5 entirely. Emit one `info` finding (source `cso-audit:threat-intel-offline`) listing the symptoms. Proceed to Phase 5 with the un-enriched findings — the audit still produces a valid report.
4. **Severity auto-promotion only applies when the enrichment succeeded** — never promote based on cached/partial data unless the cache is fresh (<6h).

---

## Helper script

The skill bundles a small bash helper to keep the LLM from re-deriving the curl chains each run:

- `scripts/fetch_intel.sh <cve-or-ghsa-id>` — prints a single JSON document with all enrichment fields keyed by source. Returns exit 0 on success, exit 2 if all sources failed.

Usage from inside the skill:

```bash
$ scripts/fetch_intel.sh CVE-2021-44228
{"cve":"CVE-2021-44228","osv":{...},"epss":{...},"kev":{...},"nvd":{...},"hn":{...}}
```

The script handles caching, rate-limit pacing, and graceful per-source failure. The LLM just parses the returned JSON.

---

## What this does NOT do

To be explicit about the boundary:

- **No paid APIs.** Ever. No Tavily, no Perplexity, no Snyk-DB premium, no commercial threat feeds.
- **No Twitter / X scraping.** The OSV `references` array typically includes the link to the relevant tweet; we trust OSV's curation rather than scraping the firehose.
- **No vendor-specific feeds** (Tenable, Rapid7, CrowdStrike, etc.) — those need accounts.
- **No browser automation** — pure JSON APIs only.
- **No exploit code download.** The skill links to PoC repos in the Recent-activity block but never downloads or runs exploit code.

These boundaries keep the skill deterministic and free-to-run forever.

## References

- OSV.dev — https://google.github.io/osv.dev/api/
- EPSS — https://www.first.org/epss/api
- CISA KEV — https://www.cisa.gov/known-exploited-vulnerabilities-catalog (and the GitHub mirror at https://github.com/cisagov/kev-data)
- NVD API — https://nvd.nist.gov/developers/vulnerabilities
- GitHub Security Advisories — https://docs.github.com/en/code-security/security-advisories
- Hacker News Algolia API — https://hn.algolia.com/api
