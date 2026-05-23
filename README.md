# GPForum Prompt Architecture

GPForum is a Perl-native, PostgreSQL-centric, distributed forum architecture described through mandatory prompt constitutions.

These prompts are not casual notes. They are the architectural contract for future AI-assisted implementation, review, and long-term project governance.

## Reading Order

Read the prompts in this order:

1. `prompt/1.txt` - foundational architecture constitution
2. `prompt/2.txt` through `prompt/16.txt` - core technical constitutions
3. `prompt/17.txt` - community/product operations
4. `prompt/19.txt` - final cache and Redis decision
5. `prompt/20.txt` through `prompt/27.txt` - implementation bridge, schema, workflows, UX, privacy, operations
6. `prompt/28.txt` through `prompt/39.txt` - bootstrap, environment, communication, admin, policy, import/export, SEO, plugins, testing, contracts, deployment, and prompt governance

`prompt/18.txt` is an architectural exploration memo. It is useful context, but `prompt/19.txt` is the authoritative decision.

## Prompt Categories

Foundational:

* `1.txt`
* `2.txt`
* `3.txt`
* `4.txt`
* `5.txt`
* `6.txt`
* `7.txt`
* `8.txt`
* `9.txt`
* `10.txt`
* `11.txt`
* `12.txt`
* `13.txt`
* `14.txt`
* `15.txt`
* `16.txt`

Product and implementation bridge:

* `17.txt`
* `20.txt`
* `21.txt`
* `22.txt`
* `23.txt`
* `24.txt`
* `25.txt`
* `26.txt`
* `27.txt`

Final architecture decisions:

* `19.txt`

Implementation execution prompts:

* `28.txt`
* `29.txt`
* `30.txt`
* `31.txt`
* `32.txt`
* `33.txt`
* `34.txt`
* `35.txt`
* `36.txt`
* `37.txt`
* `38.txt`
* `39.txt`

## Precedence Rules

When prompts conflict:

1. Security and privacy constraints win.
2. Authoritative final-decision prompts win over exploratory memos.
3. More specific prompts win over general prompts within their domain.
4. Later implementation prompts may refine, but must not silently violate, earlier constitutions.
5. Any intentional architectural change requires an ADR.

Known precedence:

* `19.txt` supersedes any interpretation that makes Redis or KeyDB mandatory for correctness.
* `21.txt` is a starting schema blueprint, not a complete migration history.
* `28.txt` is the canonical first-code bootstrap prompt.

## How To Use With AI

For architecture review, provide the relevant constitution plus this README.

For implementation, provide:

* `1.txt`
* the domain-specific prompt
* `20.txt`
* `21.txt`
* `22.txt`
* `23.txt`
* `24.txt`
* `28.txt`
* `36.txt`

For production readiness, provide:

* `10.txt`
* `11.txt`
* `15.txt`
* `26.txt`
* `27.txt`
* `38.txt`

AI-generated code MUST preserve the constraints in these prompt constitutions.

