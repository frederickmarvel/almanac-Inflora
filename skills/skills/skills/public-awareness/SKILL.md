---
name: public-awareness
description: "Maintain artifact integrity — working context (progress notes, process TODOs, uncertainty, session reasoning) must never appear in artifacts intended for external consumption: websites, API specs, technical documentation, database records, design specs, or any product being built for others. Use this skill whenever writing to a website, CMS, API, database, documentation, or any shared artifact. Also use when the AI needs to hold working context across steps — route it to TodoWrite (in-session) or memory (cross-session), not into the artifact. The core question is always: is this content *part of the artifact* or *about how we're building it*? When unclear whether a destination is public or internal, ask before writing."
---

# /public-awareness

Every artifact has a purpose and an audience. Your role is to build the artifact cleanly — placing only content that belongs to its audience inside it. Working context (how you and the prompter are collaborating to build it) is *about* the artifact, not *part of* it.

The artifact's audience wasn't in this work session. They see only the artifact — it should contain only what was built for them.

## The core model

```
Working context (internal)           Artifact (external)
─────────────────────────────────    ─────────────────────────────────
Progress notes                       Website copy / HTML
Uncertainty and "maybe"s             API spec fields and descriptions
Process TODOs                        Database schema + records
Session decisions and reasoning      Technical documentation
Context captured from prompter       Design specifications
"I tried X but switched to Y"        Shared documents
                                     Deployed code and configs
     → conversation, TodoWrite,           → the artifact itself
       memory, local temp files
```

**The channel rule:** Internal context lives in the workspace. Only intentional, finished content goes into the artifact.

## What counts as an artifact

Artifacts are things built for consumption by people outside the current work session — including future teammates who weren't in it:

| Artifact type | Examples |
|--------------|---------|
| **Website / web app** | Pages, copy, HTML, CMS content, landing pages |
| **API specification** | OpenAPI/Swagger docs, endpoint descriptions, field definitions, API guides |
| **Technical documentation** | Architecture docs, runbooks, README files to be shared, onboarding guides |
| **Database** | Schema definitions, records, migration files, seed data |
| **Design specification** | Component specs, wireframe annotations, design system docs |
| **Shared documents** | Notion pages for others, Google Docs, Confluence, client-facing PDFs |
| **Code artifacts** | Deployed / published code, PR descriptions, public repo commits |

### Tool ≠ visibility

Don't assume a tool is automatically public or internal. The question is always about the artifact's **purpose and audience**:

- Notion for external client → treat as public
- Notion as a private scratchpad the prompter owns → internal is fine
- A GitHub issue on a public repo → treat as public
- A local markdown file in the working directory → internal

When the audience isn't obvious, ask: **"Is this [document / page / spec] for internal use, or will others read it?"** Don't guess.

## Recognizing internal context

These are working context. They belong in conversation, TodoWrite, or memory — never in an artifact:

- **Progress**: "I've completed sections 1–3, starting section 4"
- **Uncertainty**: "I'm not sure whether to use approach A or B yet"
- **Process TODOs**: "Need to confirm the pricing copy with the client"
- **Captured decisions**: "User said the layout should be 3 columns"
- **Reasoning traces**: "Tried this approach first, switched because…"
- **Speculation**: "This may need to change if the schema changes"
- **Self-referential notes**: "As discussed earlier in this session…"

If a sentence describes *how the work is going*, it's internal. If it *is* the work, it belongs in the artifact.

## Anti-patterns by artifact type

### Website / CMS
❌ `<!-- TODO: verify pricing copy with legal team -->` inside published HTML  
❌ "Work in progress — hero section not final" in visible page content  
❌ HTML comments that track Claude's own progress or uncertainty  

### API Specification
❌ "Foreign key relationship to users table — to be discussed" inside a field description  
❌ "Not sure about pagination approach yet" in an endpoint's `description` field  
❌ `_internal_note` or `x-todo` fields added to document Claude's uncertainty  

### Technical Documentation
❌ "I've updated the intro, still need to finish the examples" as doc content  
❌ "Based on what the user told me in the last session…" inside the doc body  
❌ Mixing session decisions with the documented content  

### Database / API Calls
❌ `"_note": "still validating this field"` added to a JSON payload  
❌ Migration comments that reflect session uncertainty rather than technical rationale  
❌ Temp fields added to records to track Claude's own state  

### Shared Documents
❌ "Progress: completed steps 1–3 from our conversation" as Notion page content  
❌ Internal action items written into a Notion page that stakeholders will read  
❌ "As agreed in our session today…" written as document content rather than said in conversation  

## Where internal context actually belongs

| What you need to track | Where to put it |
|----------------------|----------------|
| Step progress in this session | `TodoWrite` |
| Question or uncertainty | Say it in conversation to the prompter |
| Context needed later this session | Conversation or a local temp file |
| Context that should survive across sessions | Memory (`~/.claude/projects/.../memory/`) |
| Pending decision | Ask the prompter directly |

If you're building something complex and need to track state, **TodoWrite is your working scratchpad** — not the artifact being built.

## Artifact language rule

The artifact's language is determined by the **project context**, not the prompt language.

- Prompter writes in Indonesian → artifact is an English website → write content in **English**
- Prompter writes in English → app is a Bahasa Indonesia product → write content in **Indonesian**
- Conversation with the prompter → always match the prompter's language
- Code, identifiers, and technical strings → follow the codebase convention (typically English regardless of product language)

The reasoning: the artifact's audience determines its language. The prompter is the builder, not the audience — their language governs conversation, not the artifact.

If the project language is ambiguous, ask once: "What language should this [page / spec / document] be written in?"

## Pre-write checklist

Before writing to any artifact, run this:

1. **Audience** — Who reads this? Were they in this session?
2. **Belonging** — Is this content *part of* the artifact, or *about how it's being built*?
3. **Intentionality** — Did the prompter ask for this to appear here?
4. **Language** — Does this artifact have a defined project language? Use that — not the prompt language.

Any check fails → keep it internal or ask before writing.

## When to ask the prompter

Ask before writing when:
- The artifact's audience isn't clear (internal team vs. client vs. public)
- Content is borderline (a "known issues" section — intentional disclosure or working note?)
- The prompter's instruction mixes product content with process notes

**Template:** "Is the [document / spec / page] for internal use or will [client / users / team] read it? This affects whether I include [X]."
