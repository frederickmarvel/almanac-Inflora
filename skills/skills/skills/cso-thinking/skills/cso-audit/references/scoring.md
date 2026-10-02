# Scoring rubric

> How to compute the security score. Used in Phase 5 of `/cso-audit`. The formula is intentionally simple so the next audit can be compared apples-to-apples.

## Base formula

```
score = 100 − Σ(severity_weight × finding_count)
score = max(0, score)
```

### Severity weights

| Severity | Weight | Examples |
|----------|--------|----------|
| Critical | −15 | Remote unauth RCE, hardcoded prod credential, SQL injection in main code path, auth bypass, exposed admin endpoint |
| High | −7 | Privilege escalation, IDOR on sensitive resource, stored XSS in authenticated area, dependency CVE with active exploit, sensitive data in logs |
| Medium | −3 | Missing security header, weak cipher in non-critical path, dependency CVE without known exploit, IAM policy too broad |
| Low | −1 | Defense-in-depth gap, deprecated API usage, missing rate limit on non-sensitive endpoint, verbose error message |
| Info | 0 | Hygiene / consistency / future hardening (e.g., "consider adopting SBOM generation") |

**Why these weights:** the Critical : Low ratio is 15:1 — a single Critical wipes out 15 Lows. This intentionally prevents grade inflation from finding many trivial issues, and prevents grade deflation from being thorough about minor stuff.

## Letter grade bands

| Score | Grade |
|-------|-------|
| 97–100 | A+ |
| 93–96 | A |
| 90–92 | A− |
| 87–89 | B+ |
| 83–86 | B |
| 80–82 | B− |
| 77–79 | C+ |
| 73–76 | C |
| 70–72 | C− |
| 67–69 | D+ |
| 63–66 | D |
| 60–62 | D− |
| 0–59 | F |

## Hard gate: any Critical caps the grade

> **Rule:** if at least one Critical finding exists, the grade is capped at **C+** regardless of raw score.

A 95/A− with one Critical SQL injection is dishonest — a single attacker action wipes the system. Cap it at C+ to communicate "do not ship until Critical is resolved."

### How the cap interacts with raw score

The cap only **lowers** a grade, never raises it. So:

1. Compute the raw score and look up the raw letter grade in the bands table.
2. If at least one Critical finding exists AND the raw grade is **better than C+**, replace the displayed grade with C+.
3. If the raw grade is already C+ or worse (C, C−, D+, D, D−, F), the cap has no effect — display the raw grade.

Show the reasoning transparently in the output:

```
# Cap applies (raw grade A−, lowered to C+):
Raw score: 95 → A−
Critical findings present → grade capped at C+
Displayed grade: C+

# Cap does not apply (raw already worse than the cap):
Raw score: 8 → F
Critical findings present, but raw grade is already below C+
Displayed grade: F
```

## Scope-size adjustment

A 50-line script and a 500k-LOC platform shouldn't share the same scoring scale. Apply a multiplier to the finding penalty:

| Codebase size (rough LOC across active profiles) | Penalty multiplier |
|--------------------------------------------------|--------------------|
| < 500 LOC | 2.0× (small surface — each finding is more damning) |
| 500 – 5,000 LOC | 1.5× |
| 5,000 – 50,000 LOC | 1.0× (baseline) |
| 50,000 – 500,000 LOC | 0.7× (large surface — some noise is expected) |
| > 500,000 LOC | 0.5× |

LOC estimation can be rough — `cloc` if available, otherwise `find . -name "*.{ext}" | xargs wc -l` for relevant extensions, excluding `node_modules` etc.

Show the multiplier in the output so the formula is auditable:

```
Findings: 2 Critical · 5 High · 8 Medium · 3 Low
Raw penalty: (2×15) + (5×7) + (8×3) + (3×1) = 92
Scope: ~12k LOC → multiplier 1.0×
Adjusted penalty: 92
Raw score: 100 − 92 = 8
Critical present → grade capped at C+ (final grade: F by score, displayed: F — score below D−, cap doesn't help)
Final: 8 / F
```

(In this example the cap doesn't apply because the raw grade is already worse than C+; the cap only kicks in when raw score is high but a Critical exists.)

## Profile coverage adjustment

If `tools_missing[]` contains more than half of the recommended tools for an active profile, add a flag to the score line:

```
Score: 72 / B−  ⚠ degraded coverage (frontend: 2/5 tools available)
```

Do **not** alter the numeric score — just flag it. The user should understand "this could be 72 OR could be much worse, run again with full tools to know."

## Re-audit deltas

When `SECURITY_AUDIT.md` already exists, compute deltas and show them:

```
## Delta from previous audit (2026-05-12 → 2026-05-21)
Score: 65 → 72 (+7)
Critical: 4 → 2 (−2) ✓
High:     8 → 5 (−3) ✓
Medium:   6 → 8 (+2) ✗
Low:      3 → 3 (0)

Resolved (5):
  - F-001 (prev) — SQL injection in /search → fixed
  - F-003 (prev) — Hardcoded AWS key   → rotated + removed
  ...

Regressed (1):
  - F-007 (prev) — CSP allows unsafe-inline → returned (new commit on 2026-05-18)

New (4):
  - F-101 (new) — IDOR in /api/users/:id
  ...
```

Score trending is the headline metric — a steady upward trend matters more than the absolute number in any single audit.

## What NOT to do

- ❌ Don't add bonus points for "looks good" — the only way to gain score is to have fewer findings.
- ❌ Don't change weights to fit the desired grade.
- ❌ Don't hide Criticals to dodge the cap.
- ❌ Don't aggregate Critical+High into one number; severity distribution is the most important signal in the report.
- ❌ Don't grade on a curve relative to "typical projects" — the user wants absolute risk posture, not relative.

## Example score lines

```
Score: 92 / A−  · 0 Critical · 1 High · 2 Medium · 4 Low · 3 Info
Score: 78 / C+  · 0 Critical · 4 High · 5 Medium · 2 Low
Score: 62 / D−  · 0 Critical · 7 High · 4 Medium · 3 Low
Score: 88 / C+ ⚠ (raw 95/A, capped — 1 Critical present)
Score:  0 / F   · 5 Critical · 12 High · 8 Medium · 6 Low — do not ship
```
