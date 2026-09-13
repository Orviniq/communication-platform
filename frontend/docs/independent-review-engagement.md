# Retaining an independent cryptographic reviewer

## Status

**Updated 2026-09-13.** The MLS track this document was prepared for is cancelled: the
server deleted MLS
([server ADR-0001](../../docs/architecture/decisions/0001-pairwise-double-ratchet-group-fan-out.md)),
and the MLS profile and the closed-beta PQ MLS review packet were deleted from this tree.
Every MLS gate, prerequisite, and packet named below is historical and can no longer
open. The pairwise scope is unaffected.

This document prepares the *engagement* that production gate 7 in the MLS profile and
ADR-017 require. **It retains nobody, names nobody as retained, and closes nothing.**

- No reviewer, firm, or individual named below has been approached, contacted, solicited,
  or engaged. Nobody has agreed to anything. Availability, willingness, price, and
  jurisdictional feasibility are unknown for every name in this document and cannot be
  established from inside this repository.
- Gate 7 ("An independent cryptographic review closes all blocking findings") remains
  **open and untouched**. So do gates 1-6. Preparing an engagement is not a review, and a
  perfect qualification bar with no reviewer behind it satisfies no gate, not partially and
  not conditionally.
- The Phase-A preflight row "Qualified independent reviewer available for the final
  implementation" remains **Blocked**. This document does not change its result. It
  supplies the "scope of work" half of what that row says is missing; the "named, retained
  reviewer" and "review schedule" halves are external and stay missing.
- The pairwise track is in the same position: production pairwise messaging stays gated
  until an independent assessor records a disposition for every blocking finding
  ([pairwise packet](pairwise-review-readiness.md)).

The two assembled review packets are the input material for the engagement described here:

- Closed-beta PQ MLS independent-review packet (deleted)
- [Pairwise v1 independent-review packet](pairwise-review-readiness.md)

Everything in sections 1-3 below is complete locally and needs no external party.
Everything in sections 4-6 is a *proposal for evaluation*, not an action taken.

## What the engagement has to satisfy

| Requirement | Where it is written | What it demands |
|---|---|---|
| ADR-017 | [decision register](decisions.md) | Shared reviewed crypto core **and independent assessment**; "a custom, unaudited cryptographic implementation is not production-ready" |
| ADR-026 | [decision register](decisions.md) | Review is one of the mandatory conditions alongside registry assignment, suite identifier, provider support, and Android interoperability. ADR-026 also forbids assigning a production identifier locally, which is why no review outcome can substitute for gate 2 |
| Production gate 7 | MLS profile (deleted) | "An independent cryptographic review closes all blocking findings" |
| Phase-A prerequisite 5 | MLS profile (deleted) | A qualified independent reviewer must be *available and retained*, with a recorded scope of work and schedule |
| Pairwise production gate | [pairwise transport v1](pairwise-transport-v1.md), [pairwise packet](pairwise-review-readiness.md) | An independent assessor records a disposition for every blocking finding, with reviewed source hashes and residual-risk acceptance |
| Threat-model sign-off | [threat model](threat-model.md) | An independent reviewer signs off the protocol, implementation boundary, and Android key handling |

Note what gate 7 does **not** do. Closing it opens nothing on its own: gates 1, 2, and 3
are registry, specification, and upstream-provider conditions that no review can supply,
and the MLS profile records that gates 1-3 "cannot be advanced by any work in this
repository". A completed review moves exactly one gate.

---

## 1. Qualification bar

The bar is stated as evidence a candidate must be able to **show**, not as reputation.
Every item is verifiable by the owner before any money is committed, from public material
or from material the candidate supplies on request. A candidate who cannot evidence a
mandatory item does not meet the bar, regardless of standing.

### 1.1 Mandatory evidence

| # | Requirement | Evidence that satisfies it | Why this implementation needs it |
|---|---|---|---|
| **Q1** | **Demonstrated MLS competence** | Published work on RFC 9420 or its drafts: specification authorship, a machine-checked or hand-written security analysis, or a published assessment of an MLS implementation or an MLS-based deployment | The construction is MLS. A reviewer who learns MLS on this engagement is being paid to acquire the competence the engagement exists to apply |
| **Q2** | **Demonstrated hybrid post-quantum KEM competence** | Published work on ML-KEM/FIPS 203, KEM combiners, hybrid PQ/T constructions, HPKE, or PQ key agreement — specification, analysis, implementation, or assessment | The beta's KEM diverges from `TBD2` in ten recorded ways (rows D1-D10 of the deleted MLS profile) and the pairwise track is hybrid PQXDH. Judging whether a *non-standard* hybrid combiner is sound is the single hardest question in the packet, and it is not answerable from an MLS background alone |
| **Q3** | **Implementation-level review, not design-only** | At least one published engagement that read source and reported source-anchored findings, not solely a design/architecture opinion | The two packets are implementation packets. A design review of the profile documents would leave the entire inventory unread |
| **Q4** | **Rust and FFI boundary competence** | Published work involving Rust cryptographic code, `unsafe` review, memory/secret lifetime, or foreign-function boundaries | The core is Rust with 46 `unsafe` blocks in the shared C ABI and one 1 MiB-bounded `dart:ffi` allocation path; `mls_beta.rs` itself contains no `unsafe` and inherits `lib.rs`'s |
| **Q5** | **Protocol-invention review capability** | Evidence of reviewing bespoke state machines, concurrency, and persistence — not only primitive or parameter checking | The ten project inventions in the packet are the highest-value targets *precisely because* no external specification or vector can validate them: credential binding, control transcript, fork convergence, leave/eviction, queue-gap re-admission, the transactional commit boundary, state sealing, per-recipient re-wrapping, the FFI boundary, and redaction |
| **Q6** | **A published report of the required shape** | At least one publicly readable report containing, per finding: an identifier, a severity, a source location, and a disposition; plus a statement of what was and was not in scope | Section 3 requires exactly this shape. A candidate who has never produced it is being asked to invent their deliverable format on this engagement |
| **Q7** | **Named assessors** | The individuals who will do the work are named, with their own attributable prior work | A firm brand is not evidence that the people assigned to this engagement have Q1-Q5. Reports that name their assessors are the norm in this field, including in the closest comparable engagements |
| **Q8** | **Fix verification, in writing, as part of the engagement** | A prior engagement where the assessor verified remediation and said so, or a written commitment to do so here | D5 (retest confirmation) cannot be produced by the owner. If the candidate will not retest, the gate cannot close |
| **Q9** | **Willingness to work under a stated out-of-scope list and to record residual risk** | Acceptance of the packets' "explicitly out of scope" sections as engagement boundaries, and willingness to record what was *not* assessed | The MLS packet's out-of-scope list is long and deliberate (no sanitizer/Miri/coverage-guided fuzzing on a stable pin, no physical-device crash matrix, no state-format migration fuzzing). A reviewer who silently treats these as covered would produce a report that overstates assurance |

### 1.2 Independence requirements

Independence is a property of the *engagement*, not a compliment paid to the reviewer.

| # | Requirement |
|---|---|
| **I1** | The reviewer did not author, co-author, maintain, or contribute to any code, document, vector, or decision under review, and is not doing so during the engagement |
| **I2** | The reviewer has no ownership, employment, contractor, advisory, or revenue relationship with the project owner beyond this engagement, and none is created by it |
| **I3** | The reviewer discloses, in writing and before the engagement starts, any relationship to the parties whose work this implementation *depends on or criticises*: `mls-rs` and AWS; OpenMLS and Phoenix R&D; the authors of `draft-ietf-mls-pq-ciphersuites`, `draft-ietf-hpke-pq`, `draft-irtf-cfrg-concrete-hybrid-kems`, and `draft-connolly-cfrg-xwing-kem`; and libsodium and mlkem-native. Disclosure is not disqualification — the strongest candidates are close to this work — but an undisclosed relationship is |
| **I4** | The reviewer's fee, scope, and continuation are not contingent on the findings, their severity, or a favourable conclusion. No clause may let the owner suppress a finding, and the reviewer keeps editorial control of the findings text |
| **I5** | The reviewer states positively, in the report, what they did **not** review, and what their conclusions therefore do not cover |

### 1.3 Disqualifying conditions

A candidate is out, regardless of other evidence, if any of these hold:

1. They wrote or maintain part of what they would be reviewing (I1).
2. They will not name the individuals doing the work (Q7).
3. They will not retest fixes (Q8).
4. Their only relevant track record is general application penetration testing with no
   cryptographic or protocol content — a competent app pentest is not a cryptographic
   review and cannot close gate 7.
5. They require that findings be delivered only as a summary or a pass/fail conclusion,
   without a per-finding register.
6. They would treat the project's ten inventions as out of scope, or would scope the
   engagement to "conformance with RFC 9420" only. Conformance is not the risk here; the
   inventions and the recorded divergence are.
7. They offer to review against `TBD2` as a conformance target. The beta is not `TBD2` and
   never has been; such an engagement would produce wrong conclusions by construction (see
   the packet's "The one thing to read first").

### 1.4 How the bar is applied

Q1-Q9 and I1-I5 are all mandatory. There is no scoring, no weighting, and no
"strong overall" path past a missing item. Where a single candidate cannot evidence
everything, the bar is met by a **combination** — for example an implementation-review
practice for Q3/Q4/Q6/Q8 plus a named specialist for Q1/Q2 — provided the combination is
contracted as one engagement with one findings register and one retest, and each named
assessor individually satisfies I1-I5. Two disconnected reviews that never reconcile their
findings do not satisfy the bar, because no single party ever states what was and was not
covered overall.

---

## 2. Scope of work

Bounded to this implementation, at a pinned revision, using the two assembled packets as
the reviewer's entry point.

### 2.1 Source baseline

| | |
|---|---|
| Repository | this repository, `frontend/` and `native/` only |
| Revision under review | to be fixed at engagement start and recorded verbatim in D1 and D2 |
| The packets' current baseline | `4e65eaf4f0e4a017a42b48b49a444570f47cbffb` (branch `frontend`, committed 2026-08-18) |
| Current `HEAD` | `76056597d34987d615d1616cdfa2cc7adb036725` — verified on 2026-08-18 to differ from `4e65eaf` in documentation only (`docs/README.md`, `docs/implementation-checklist.md`, `docs/mls-beta-review-readiness.md`); no source, test, vector, or backend file differs |
| Toolchain | Rust 1.97.1 stable, Flutter 3.44.7, Dart 3.12.2, exactly as pinned and recorded in the MLS packet |
| Backend | **read-only**. `backend/` is not modifiable from this track and is not part of this scope |

The reviewer works from a fixed revision. If the owner lands changes during the
engagement, they become a *second* recorded revision in D2, or they wait.

### 2.2 Work packages

| WP | Subject | Primary material | Deliverable contribution |
|---|---|---|---|
| **WP0** | Scope agreement and threat-model reconciliation. Confirm the claims in scope, confirm the out-of-scope list is understood and accepted, and reconcile against [the threat model](threat-model.md) | Both packets' "Security claims in scope" and "Explicitly out of scope"; [threat model](threat-model.md) | D1 |
| **WP1** | **The ten project inventions.** Credential binding to the Authentication Service; the control transcript and later-member admission (ADR-037); fork convergence (ADR-041); leave and eviction (ADR-039); queue-gap re-admission; the transactional commit boundary; state sealing and versioning; per-recipient envelope re-wrapping (ADR-011); the FFI boundary; redaction and the error surface | MLS packet, "The project's own protocol inventions"; `group_model.dart`, `native_beta_group_mls.dart`, `drift_group_repository.dart`, `mls_beta.rs` | D3 |
| **WP2** | **Suite assembly and the recorded KEM divergence.** Whether rows D1-D10 are complete and correctly characterised; whether the divergence has consequences beyond the loss of `TBD2` interoperability that ADR-040 asserts; whether an unassigned HPKE `kem_id` reaching every key schedule is confined as claimed | MLS profile (deleted) rows D1-D10; `docs/upstream/mls-rs-hybrid-kem-defect-report.md`; `mls_beta.rs`; `beta_kem_vectors.rs` | D3 |
| **WP3** | **Pairwise transport v1.** Hybrid PQXDH composition and transcript, the ratchet state machine, skipped-key bounds, repair, rotation overlap, revocation | [pairwise transport v1](pairwise-transport-v1.md); [pairwise packet](pairwise-review-readiness.md) | D3 |
| **WP4** | **Persistence, concurrency, and the commit boundary.** Compare-and-swap under control revision and hash; crash between commit and fan-out; exact-ciphertext retry; the 20,000-key account bound under concurrent transactions | `drift_group_repository.dart`, `drift_pairwise_transport_store.dart`, `drift_sync_store.dart`, `local_database.dart` (schema 11) | D3 |
| **WP5** | **The boundary.** The single C ABI operation, the 46 `unsafe` blocks in `lib.rs`, the 1 MiB-bounded `dart:ffi` allocation and its zero-and-free path, isolate ownership, typed-response decoding | `lib.rs`, `beta_mls_ffi.dart`, `beta_mls_native_session.dart`, `isolate_crypto_core_worker.dart` | D3 |
| **WP6** | **Isolation and packaging.** That the production release artifact contains no beta code path — not a disabled one, not a dead one — and that the source-only production gate cannot be flipped by accident | `tool/build_rust_android.sh/.ps1`, `android/app/build.gradle.kts`, `group_production_gate.dart`, `unsupported_group_mls.dart`; the 15-vs-16 symbol allowlists | D3 |
| **WP7** | **Evidence adequacy.** Whether the vector split (official primitive vectors vs project-generated regression pins), the 12-target fuzz campaign, and the fault-injection matrix support the claims made — and whether the packets' stated limits are stated *honestly and completely* | `native/crypto_core/vectors/README.md`, `fuzz/README.md`, both packets' validation tables | D3, D7 |
| **WP8** | **Retest.** Re-examine every finding the owner claims to have fixed, at a new recorded revision, and state per finding whether the fix resolves it | the fixes produced under D4 | D5 |

WP1 is the centre of gravity. The packet says so directly, and it is the correct emphasis:
external specifications and vectors cover the primitives, and nothing external covers the
inventions.

### 2.3 Explicitly out of scope

The reviewer must accept and restate these, so the report cannot be read as covering them.

- **Everything the MLS packet lists as out of scope**, including: `TBD2` conformance;
  interoperability with any other MLS implementation; post-quantum *authentication* (the
  signature is Ed25519 throughout — the claim is PQ confidentiality only); sanitizer, Miri,
  and coverage-guided fuzzing (the stable Rust pin forecloses them); the physical-device
  crash matrix; state-format migration fuzzing; Web/Wasm; traffic analysis and fan-out
  metadata; device compromise; and full-database rollback.
- **`backend/`.** Read-only here, governed by its own contract, and not assessable from
  this track.
- **The internals of pinned upstream dependencies**, beyond how this implementation uses
  them. With one deliberate exception: WP2 requires reading the pinned `mls-rs` crypto
  crates far enough to confirm or refute rows D1-D10, because the divergence lives there.
- **Any claim about production readiness of the beta track.** The beta is Private Use
  `0xFE4C` with disposable state. A favourable review does not make it a production
  deployment, and the report must not be worded so that it could be read that way.

One dependency fact belongs in the residual-risk record rather than in scope: the upstream
`mls-rs` project states in its own README that it "has been validated for conformance to
the RFC 9420 specification but has not yet received a full security audit by a 3rd party"
(verified 2026-08-18). This implementation's assurance therefore rests on an unaudited
protocol engine. That is not a defect this engagement can fix, and it is not a reason to
widen scope to auditing `mls-rs`; it is a residual risk the owner must accept explicitly
under D7.

### 2.4 Effort benchmarks

For budgeting only. These are published figures from comparable engagements, not quotes,
and no candidate has been asked what this would cost.

| Comparable engagement | Recorded effort | Source, verified 2026-08-18 |
|---|---|---|
| Discord DAVE protocol **design** review (an MLS-based E2EE deployment protocol) | 4 engineer-weeks, Aug 2024 | Trail of Bits publications index |
| Discord DAVE protocol **code** review | 4 engineer-weeks, Sep 2024 | Trail of Bits publications index |
| Open Quantum Safe `liboqs` security review | 5 engineer-weeks, Apr 2025 | Trail of Bits publications index |
| Ockam cryptographic design review | 11 engineer-weeks, Nov 2023 | Trail of Bits publications index |
| Go cryptographic libraries security review | 12 engineer-weeks, Mar 2025 | Trail of Bits publications index |
| OpenMLS security assurance assessment | 4 named assessors; code reviewed to a commit dated 22 October 2025; report v1.2 dated 11 March 2026; biweekly meetings throughout | SRLabs report, obtained from the OpenMLS blog |

This implementation's reviewable surface is larger than DAVE's: the group feature alone is
22 files and 9,779 lines of Dart, `mls_beta.rs` is 5,363 lines, and WP3 adds the whole
pairwise transport. A DAVE-shaped engagement (design + implementation, 8 engineer-weeks)
is the floor, not the target. **A defensible planning figure for WP0-WP8 across both
packets is 10-16 engineer-weeks, plus a separate retest pass for WP8.** Treat it as an
order of magnitude for deciding whether a funding route is viable at all, not as a number
to negotiate against.

---

## 3. Deliverables required before the review gate can close

All seven are mandatory. Gate 7 closes when all seven exist and D3 shows no open blocking
or high finding — not before, and not partially.

| # | Deliverable | Acceptance criteria |
|---|---|---|
| **D1** | **Agreed scope statement** | Written and signed by both parties *before* work starts. Names the work packages included and excluded; restates the packets' out-of-scope list as engagement boundaries; states the threat model and adversary assumed; states what a "blocking" finding means for this project. Later scope changes are amendments to D1, dated, not silent |
| **D2** | **Exact reviewed source hashes** | The full commit hash of every revision reviewed, plus the hashes or pinned versions of the dependency set (`Cargo.lock`, `pubspec.lock`) and the vendored C sources. If the retest ran against a later revision, both revisions appear. A report that identifies its subject as "the repository" or by branch name does not satisfy D2 |
| **D3** | **Findings register with a disposition for every finding** | One row per finding, with: identifier, title, severity, the exact file and line reviewed, reproduction or argument, recommended action, **and a disposition**. Permitted dispositions: *fixed*, *mitigated*, *risk accepted*, *not a defect*. **Every finding carries one — none may be blank.** *Risk accepted* and *not a defect* each require a written justification, by the owner and the reviewer respectively. Zero findings is a valid register only if the reviewer states positively that they looked and found none in each area |
| **D4** | **Remediation evidence** | For every finding disposed *fixed* or *mitigated*: the commit that changed it, the test or vector that now covers it, and a note where the fix changes a documented behaviour (which then updates the owning document). Fixes without a regression test are incomplete |
| **D5** | **Explicit retest confirmation** | A written statement **by the reviewer**, at a named revision, that they re-examined each fix and whether it resolves the finding — including any fix that does not. This cannot be produced by the owner, and no amount of owner-side testing substitutes for it. Absent D5, gate 7 stays open even if every finding is marked fixed |
| **D6** | **Written independence statement** | Signed by the reviewer, covering I1-I5: no authorship or maintenance of the reviewed material; no relationship to the owner beyond this engagement; disclosure of relationships to `mls-rs`/AWS, OpenMLS/Phoenix R&D, the four draft author sets, and the vendored C dependencies; confirmation that fee and scope were not contingent on findings; and a positive statement of what was not reviewed |
| **D7** | **Recorded owner acceptance of residual risk** | Signed and dated by the owner, itemising each accepted residual risk individually — every *risk accepted* disposition from D3, plus each item on the packets' out-of-scope lists that remains unexercised at release, plus the unaudited-`mls-rs` dependency. A blanket "residual risks accepted" sentence does not satisfy D7; the owner must be able to show they knew what they were accepting, one item at a time |

Where the outputs land: D1, D2, D3, D5, and D6 populate the disposition tables that both
packets already carry, which are currently empty. D4 lands as commits and tests. D7 lands
in this document, as a dated appendix, and is referenced from the MLS profile when — and
only when — the owner actually signs it.

**What these deliverables do not do.** All seven complete, with a clean register, closes
gate 7 alone. Gates 1, 2, and 3 are registry, specification, and upstream-provider
conditions outside this repository; gates 4, 5, and 6 need the packaged Android artifact,
the bucket evidence, and the full multi-device matrix respectively. The MLS packet states
this and it is repeated here so a reader of this document alone cannot mistake a completed
review for a production authorisation.

---

## 4. Candidate evaluation

### 4.1 Method and its limits

Candidates were derived from primary sources on 2026-08-18: the IETF datatracker pages for
the four relevant drafts, the IANA registries, the published reports and publication
indexes of assessment practices, and the primary publication records of the academic work
on this protocol family. No prior candidate list was used as an input.

Three limits apply to everything in this section.

1. **Nobody has been contacted.** Every "meets Q*n*" judgement below is about *published
   evidence*, not about a candidate's interest, availability, capacity, price, or
   willingness to work under section 3's deliverables. Those are unknowable without
   contact, which is externally blocked and not authorised.
2. **I1-I5 cannot be verified from public material.** Independence is established by a
   signed D6 after disclosure, not by inference here.
3. **Absence of published work is not absence of competence.** Where a table says
   "no published *X* found", it means exactly that — a search of primary sources on
   2026-08-18 did not surface it — not that the candidate lacks the skill.

### 4.2 Organisations

| Candidate | Q1 MLS | Q2 hybrid PQ KEM | Q3 impl. review | Q4 Rust/FFI | Q5 inventions | Q6 report shape | Q7 named | Q8 retest | Primary evidence (verified 2026-08-18) |
|---|---|---|---|---|---|---|---|---|---|
| **Trail of Bits** | **Yes** | **Yes** | **Yes** | Yes | Yes | **Yes** | Yes | Likely | Published *Discord DAVE Protocol Design Review* (Aug 2024) and *Code Review* (Sep 2024) of an MLS-based E2EE deployment; DAVE's own whitepaper cites their findings by identifier (`TOB-DISCE2EC-2/-5/-7`) with severity and difficulty. Published *Open Quantum Safe liboqs Security Review* (Apr 2025). Published *SimpleX Chat* and *Ockam* cryptographic reviews. Publication index at `github.com/trailofbits/publications` |
| **Cryspen** | **Yes** | **Yes** | Yes | **Yes** | Partial | Different shape | Yes | Unknown | Karthikeyan Bhargavan (Cryspen) co-authored *TreeKEM: A Modular Machine-Checked Symbolic Security Analysis of Group Key Agreement in MLS* (ePrint 2025/410, with Wallez/Inria and Protzenko/Microsoft) and *Formal verification of the PQXDH Post-Quantum key agreement protocol* (USENIX Security '24, with Jacomme, Kiefer, Schmidt). Cryspen's own account of the Signal SPQR work (published 2025-10-02) describes ProVerif models, their libcrux ML-KEM implementation, and a hax/F* verification pipeline for the Rust implementation |
| **SRLabs** | **Yes** | Not found | **Yes** | Yes | Yes | **Yes** | **Yes** | **Yes** | The OpenMLS security assurance assessment: report v1.2, 11 March 2026, prepared for Phoenix R&D, funded by the Sovereign Tech Agency; named assessment team (Constantin Schwarz, Nils Ollrogge, Bruno Produit, Marc Heuse); STRIDE threat model, manual review, fuzzing and static analysis; scope table with per-component priority; reviewed to a commit dated 22 October 2025; **eight findings with per-finding status — five Mitigated, one Acknowledged, one Risk Accepted, one Mitigated at Info** — and an explicit remediation-support phase in which "the fix is verified by" the assessor |
| **Phoenix R&D** | **Yes** (deepest) | **Yes** | Yes | **Yes** | Yes | n/a (client, not assessor) | Yes | Unknown | Maintainers of OpenMLS; their own site states they offer "software development, research and consulting services to companies that are interested in secure messaging, post-quantum resistance, and privacy-preserving technologies". They published the audit-results post (Raphael Robert, 2026-05-27) |
| **NCC Group Cryptography Services** | Not found | Partial | **Yes** | Yes | Yes | **Yes** | Yes | Likely | Public report index at `cryptoservices.github.io` lists cryptographic implementation reviews (Go `x/crypto/ssh`, BLS signatures, Keyfork, WhatsApp-related assessments for Meta). No MLS-specific published report was found on that index |
| **Cure53** | Not found | Not found | **Yes** | Partial | Partial | **Yes** | Yes | Yes | Site states they provide "infrastructure, platform and cryptography audits" and publish reports "upon explicit request by the project maintainers"; listed crypto-adjacent work includes Noble Cryptography Libraries (08.2024), Nym (07.2024), Threema mobile apps (10.2020) |
| **Radically Open Security** | Not found | Not found | Yes | Unknown | Unknown | Yes | Yes | Unknown | Describes itself as a "Non-Profit Computer Security Consultancy" committed to transparency. Relevant chiefly as the audit route attached to certain European funding programmes rather than on published MLS or PQ work |

**Reading of the organisation table.** Trail of Bits and SRLabs are the only two candidates
whose *published output already has the exact shape section 3 demands* — source-anchored
findings, identifiers, severities, per-finding dispositions including "Risk Accepted", and
assessor-verified remediation — and both have published work on an MLS codebase or an
MLS-based deployment. Trail of Bits additionally evidences Q2 through the `liboqs` review;
SRLabs' published PQ KEM work was not found, which is the one mandatory item it does not
clearly evidence alone. Cryspen evidences Q1 and Q2 more deeply than anyone else and is the
strongest match for WP2 (the KEM divergence) and WP1's protocol questions, but its
published output is verification artifacts and papers rather than findings registers, so
Q6 and Q8 would have to be established by agreement rather than by precedent. Phoenix R&D
has the deepest MLS competence available anywhere, and is the clearest **I3 disclosure
case**: they author OpenMLS, an alternative implementation to the `mls-rs` this project
pins, and they operate in the same product space as this project. That is a disclosure and
a commercial-conflict question for the owner to weigh, not an automatic disqualification —
I1 is untouched, since they wrote none of this code.

The realistic shape of a compliant engagement is therefore **a combination under one
contract**: an implementation-review practice carrying Q3/Q4/Q6/Q8 and the findings
register, plus a named hybrid-PQ-KEM specialist carrying Q2 for WP2. Section 1.4 permits
this and states the condition — one register, one retest, one statement of coverage.

### 4.3 Individuals

Named for domain evidence only. Several hold institutional positions that may not permit
paid consulting at all; none has been approached, and no inference about availability
should be drawn from inclusion here.

| Candidate | Published position (verified 2026-08-18) | Where they would fit | Conflict note |
|---|---|---|---|
| **Rohan Mahy**; **Richard Barnes** (Cisco) | Authors of `draft-ietf-mls-pq-ciphersuites`, revision 06, 21 July 2026, expiring 22 January 2027, MLS WG, state "Waiting for WG Chair Go-Ahead / Revised I-D Needed - Issue raised by WG". Barnes is additionally co-author of `draft-ietf-hpke-pq-05` (with Connolly) and `draft-irtf-cfrg-concrete-hybrid-kems-04`, and is listed by IANA as a designated expert for the MLS Cipher Suites registry | WP2: authoritative on what `TBD2` requires and what the divergence costs | Barnes' registry-expert role makes him the wrong person to position as *the* independent assessor of a Private Use deployment that diverges from his own draft. A targeted consultation is a different thing from the gate-7 review, and mixing them would weaken both |
| **Deirdre Connolly** (Selkie Cryptography); **Peter Schwabe** (MPI-SP & Radboud); **Bas Westerbaan** (Cloudflare) | Authors of `draft-connolly-cfrg-xwing-kem`, revision 10, 2 March 2026, **expiring 2026-09-03**, Independent Submission stream. X-Wing is the construction IANA records as the reference for HPKE KEM `0x647A` — the identifier `TBD2` uses and the beta does not | WP2, precisely: whether the pre-standard variant shipped by the pinned provider is sound in its own right, independent of its non-conformance | Reviewing a divergence *from* their own construction is a strength, not a conflict, provided I3 disclosure is made |
| **Théophile Wallez** (Inria Paris); **Jonathan Protzenko** (Microsoft Azure Research) | With Bhargavan, authors of *TreeKEM* (ePrint 2025/410) — "the first machine-checked security proof for TreeKEM" — and of *TreeSync* (USENIX Security '23), whose analysis "identified a new attack" and produced changes adopted into the MLS draft | WP1's protocol-level questions, especially transcript authentication and roster integrity — the closest published analogue to this project's ADR-037 invention | Institutional consulting constraints likely; no published engagement of the D1-D7 shape |
| **Konrad Kohbrok**, **Raphael Robert** (Phoenix R&D) | OpenMLS maintainers; Robert is also listed by IANA as a designated expert for the MLS Cipher Suites registry and authored the audit-results post | WP1, WP7 | Same I3 disclosure and commercial-conflict considerations as Phoenix R&D above; plus, for Robert, the same registry-expert consideration as Barnes |

---

## 5. Funding routes

Evaluated against each body's published criteria. **The decisive fact for most of them is
local and verifiable: this repository carries no licence file at any level and is not
published as open source** (checked 2026-08-18). Almost every open-source audit fund
requires an OSI- or FSF-approved licence as a threshold condition, and several additionally
require the findings to be published.

| Route | What it provides | Published eligibility (verified 2026-08-18) | Verdict for this project |
|---|---|---|---|
| **Owner-funded** | Direct commercial engagement | None | **The only route with no eligibility blocker.** It is also the only route compatible with a closed codebase, with owner control of disclosure timing, and with the 10-16 engineer-week estimate as a single procurement. Recommended baseline |
| **OTF Security Lab** | Independent audits, explicitly including "early-stage security assessments of their technical design, those looking for cryptographic design reviews, and those looking for code reviews". Reports >170 audits supported | "Projects that are not receiving OTF support but are otherwise relevant to internet freedom may apply for an audit." OTF "places high priority on funding tools that are open-source and freely available to download and use". Beneficiary focus is "the world's most repressive environments" and the Global South. **"Audit findings are made publicly available after undergoing a responsible disclosure period."** Applicants in surveillance technology are ineligible | **The best-fit external route on subject matter** — it funds exactly cryptographic design and code review, and this project's design constraints (no foreign runtime dependency, operation without international internet, Persian as a first-release language) sit inside its remit. Two real obstacles: the project is not currently open source, against OTF's stated priority; and findings become public, which the owner must decide to accept. Neither is a technical blocker the way an OSI-licence requirement is |
| **NLnet / NGI Zero** | Grants €5,000-€50,000, plus "security and accessibility audits, mentoring, testing expertise, and copyright & licensing advice" to grantees | "All software and hardware developed **must** be published under a recognised free and open source license." Open to "individuals, research organisations, non-profits, public institutions, companies". "There is a deadline on the 3rd of every _odd_ month". Funds noted as in transition, with new funds active after summer | **Blocked by the licence requirement.** Grant ceiling is also below the estimate in section 2.4 for the full scope, though it could fund one work package |
| **Sovereign Tech Agency** | Funded the OpenMLS audit performed by SRLabs — the closest precedent in existence for the engagement described here | The funding relationship is confirmed by the OpenMLS maintainers' own announcement and by the SRLabs report's acknowledgement ("SRLabs thanks the Sovereign Tech Agency for funding this independent audit"). **The agency's own eligibility pages could not be retrieved: `sovereign.tech` returned HTTP 403 on 2026-08-18.** Secondary sources describe an OSI/FSF licence requirement, a focus on open digital *base* technologies (libraries, protocols, tooling, infrastructure), and a €50,000 minimum — these are recorded here as unverified at primary source | **Blocked in its current form, and structurally mismatched.** Even setting the licence aside, the precedent funds *base technology* — the OpenMLS library — not a closed end-user application built on it. The analogous fundable object here would be an upstream component, not this client |
| **OSTIF** | Facilitates and manages third-party audits of open-source projects, publishing the resulting reports | Open-source projects; requests are made by contacting the organisation directly. **Their site returned HTTP 403 on 2026-08-18**, so the criteria could not be read at primary source; the audit-report corpus itself is publicly linked | **Blocked by openness.** Reports are published as a matter of course |
| **Alpha-Omega (OpenSSF)** | Grants typically $50,000-$100,000 | Projects must use an "OSI-approved open source license"; standalone projects, foundations, or core ecosystem services; quarterly intake (January, April, July, October) with co-design and decision phases; grantees commit to monthly public reports and three public blog posts | **Blocked by the licence requirement**, and the public-accountability commitments are incompatible with a closed codebase |
| **GitHub Secure Open Source Fund** | $10,000 per project plus training and credits | "Clear open source license"; "Open source first project with demonstrated community traction and adoption"; maintainer located in a GitHub Sponsors-supported region; rolling applications | **Blocked by the licence and traction requirements.** At $10,000 it is also an order of magnitude below the estimate, and it funds security education rather than a third-party cryptographic review |

**Conclusion on funding.** If the codebase stays closed, exactly one route is open:
the owner pays. Every grant route evaluated requires open-source publication, and two of
them additionally require the findings to be public. If the owner is willing to publish the
crypto core under an OSI-approved licence — a separate strategic decision that this
document does not make and should not pre-empt — then OTF's Security Lab becomes the
best-matched route on subject matter, and the Sovereign Tech precedent becomes reachable
for an upstream-shaped component rather than for the client application.

---

## 6. What remains externally blocked

Complete locally, in this document, needing nobody outside the repository:

- the qualification bar (section 1);
- the scope of work and its baseline, work packages, exclusions, and effort benchmarks
  (section 2);
- the definition and acceptance criteria of all seven required deliverables (section 3);
- the candidate evaluation against the bar, from primary sources (section 4); and
- the funding-route evaluation against published criteria, including the local facts that
  decide most of it (section 5).

Externally blocked, and not satisfiable by any work in this repository:

| Blocked item | Why it cannot be done here | What would unblock it |
|---|---|---|
| **Retaining a reviewer** | Requires contacting a candidate, agreeing scope and price, and signing. No candidate has been approached; none has agreed to anything | Owner authorises contact, then contracts |
| **Funding** | Requires either the owner committing money or applying to a body — and every grant route evaluated is blocked by the absent open-source licence | Owner funds directly, or makes the separate decision to publish under an OSI-approved licence and then applies |
| **The review itself** | An independent party must read the code. Assembling material is not review; this document is not review; the packets are not review | The engagement runs |
| **Closure of the review's findings** | D3-D5 need a reviewer to raise findings, the owner to fix them, and **the reviewer** to retest and confirm. D5 is structurally impossible for the owner to produce | Findings raised, fixed, retested, confirmed in writing |
| **Gates 1, 2, 3** | Registry assignment, a final MLS specification with an IANA-assigned suite value, and a maintained provider implementing the final mapping. ADR-026 forbids assigning an identifier locally | Action by IANA, the MLS working group, and upstream providers |
| **Upstream interoperability vectors** | The MLS WG publishes none for any PQ suite. Project-generated vectors explicitly do not advance this | The working group publishes them |
| **Gates 4, 5, 6** | Need the packaged Android artifact on hardware, the bucket evidence, and the full multi-device crash matrix — implementation work, not review work, and not part of this task | Separate implementation and device-matrix work |

The gate list is unchanged by this document. All seven production gates in
the MLS profile remain open. The Phase-A preflight still shows five of
five prerequisites blocked.

---

## 7. Validation

### 7.1 External claims and their primary sources

Every external claim in this document traces to a source below. All were retrieved and
read on **2026-08-18** unless stated otherwise.

| Claim | Primary source | Verified |
|---|---|---|
| `draft-ietf-mls-pq-ciphersuites` is at revision 06, dated 21 July 2026, expires 22 January 2027, authors Rohan Mahy and Richard L. Barnes, MLS WG, state "Waiting for WG Chair Go-Ahead" / "Revised I-D Needed - Issue raised by WG" | https://datatracker.ietf.org/doc/draft-ietf-mls-pq-ciphersuites/ | 2026-08-18 |
| `draft-connolly-cfrg-xwing-kem` is at revision 10, dated 2 March 2026, expires 2026-09-03, Independent Submission, authors Deirdre Connolly (SandboxAQ), Peter Schwabe (MPI-SP & Radboud), Bas Westerbaan (Cloudflare) | https://datatracker.ietf.org/doc/draft-connolly-cfrg-xwing-kem/ | 2026-08-18 |
| `draft-ietf-hpke-pq` is at revision 05, dated 6 July 2026, authors Richard Barnes (Cisco) and Deirdre Connolly (Selkie Cryptography) | https://datatracker.ietf.org/doc/draft-ietf-hpke-pq/ | 2026-08-18 |
| `draft-irtf-cfrg-concrete-hybrid-kems` is at revision 04, CFRG, authors Connolly and Barnes, state "I-D Exists::Revised I-D Needed" | https://datatracker.ietf.org/doc/draft-irtf-cfrg-concrete-hybrid-kems/ | 2026-08-18 |
| The IANA "MLS Cipher Suites" registry contains only `0x0000` RESERVED, RFC 9420 `0x0001`-`0x0007`, GREASE, and Private Use `0xF000`-`0xFFFF`; **no post-quantum or ML-KEM suite is registered**; last updated 2025-11-17; policy Specification Required; designated experts Sean Turner, Raphael Robert, Richard Barnes | https://www.iana.org/assignments/mls/mls.xhtml | 2026-08-18 |
| IANA HPKE registries: KEM `0x647A` = X-Wing, reference `draft-connolly-cfrg-xwing-kem-06`; KDF `0x0002` = HKDF-SHA384 (RFC 5869); AEAD `0x0002` = AES-256-GCM (NIST SP 800-38D); last updated 2026-04-16 | https://www.iana.org/assignments/hpke/hpke.xhtml | 2026-08-18 |
| OpenMLS was independently audited by SRLabs, funded by the Sovereign Tech Agency; eight issues, one High; seven fixed in openmls 8.1 and 7.3, one Low outstanding at publication; post by Raphael Robert, 2026-05-27 | https://blog.phnx.im/openmls-independent-security-audit/ and https://blog.openmls.tech/ | 2026-08-18 |
| The SRLabs report: "Threat model and hacking assessment report", v1.2, 11 March 2026, prepared for Phoenix R&D; assessment team Constantin Schwarz, Nils Ollrogge, Bruno Produit, Marc Heuse; scope `openmls`/`traits`/`basic_credential` with per-component priority, reviewed to a commit dated 22 October 2025; crypto and storage providers explicitly out of scope; STRIDE methodology in four steps ending in remediation support where "the fix is verified by" the assessor; findings 1 High / 3 Medium / 2 Low / 2 Info with statuses Mitigated, Acknowledged, Risk Accepted; "SRLabs thanks the Sovereign Tech Agency for funding this independent audit" | https://blog.openmls.tech/SRL-OpenMLS_security_assurance_assessment.pdf | 2026-08-18 |
| Trail of Bits published *Discord DAVE Protocol Design Review* (Aug 2024, 4 engineer-weeks) and *Discord DAVE Protocol Code Review* (Sep 2024, 4 engineer-weeks); *Open Quantum Safe liboqs Security Review* (Apr 2025, 5); *Ockam Design Review* (Nov 2023, 11); *Go Cryptographic Libraries Security Review* (Mar 2025, 12); *SimpleX Chat* (Oct 2022) | https://github.com/trailofbits/publications | 2026-08-18 |
| DAVE is an MLS-based E2EE protocol (MLS 1.0, ciphersuite 2, RFC 9420) and its whitepaper cites Trail of Bits findings by identifier with severity — `TOB-DISCE2EC-5` (low, high difficulty), `TOB-DISCE2EC-7` (medium, high difficulty), `TOB-DISCE2EC-2` | https://github.com/discord/dave-protocol (`protocol.md`) | 2026-08-18 |
| *TreeKEM: A Modular Machine-Checked Symbolic Security Analysis of Group Key Agreement in MLS* — Théophile Wallez (Inria Paris), Jonathan Protzenko (Microsoft Azure Research), Karthikeyan Bhargavan (Cryspen); ePrint 2025/410, approved 2025-03-04; "the first machine-checked security proof for TreeKEM" | https://eprint.iacr.org/2025/410 | 2026-08-18 |
| *TreeSync: Authenticated Group Management for Messaging Layer Security*, USENIX Security '23, Wallez, Protzenko, Beurdouche, Bhargavan; F* specification, DY* analysis, identified a new attack, changes adopted into the MLS draft | https://www.usenix.org/conference/usenixsecurity23/presentation/wallez | 2026-08-18 |
| *Formal verification of the PQXDH Post-Quantum key agreement protocol for end-to-end secure messaging*, USENIX Security '24 — Karthikeyan Bhargavan, Charlie Jacomme, Franziskus Kiefer, Rolfe Schmidt; ProVerif and CryptoVerif; identified flaws in the specification | https://www.usenix.org/system/files/usenixsecurity24-bhargavan.pdf | 2026-08-18 |
| Cryspen's Signal engagement: PQXDH analysis from 2023, then SPQR from design through implementation — ProVerif models, libcrux ML-KEM with an incremental API, and a hax/F* verification pipeline for the Rust implementation; published 2025-10-02 | https://cryspen.com/post/signal-spqr-verification/ | 2026-08-18 |
| **`mls-rs` states: "This library has been validated for conformance to the RFC 9420 specification but has not yet received a full security audit by a 3rd party."** Dual-licensed Apache-2.0 OR MIT | https://github.com/awslabs/mls-rs and https://awslabs.github.io/mls-rs/ | 2026-08-18 |
| Phoenix R&D offers "software development, research and consulting services to companies that are interested in secure messaging, post-quantum resistance, and privacy-preserving technologies" | https://phnx.im/ | 2026-08-18 |
| NCC Group Cryptography Services publishes cryptographic implementation reviews (Go `x/crypto/ssh`, BLS signatures, Keyfork, WhatsApp-related work for Meta); no MLS-specific report found on that index | https://cryptoservices.github.io/ | 2026-08-18 |
| Cure53 provides "infrastructure, platform and cryptography audits" and publishes reports "upon explicit request by the project maintainers"; listed work includes Noble Cryptography Libraries (08.2024), Nym (07.2024), Threema (10.2020) | https://cure53.de/ | 2026-08-18 |
| SRLabs is based in Berlin and lists Software Assurance and Blockchain Security ("the cryptography underneath") among its services | https://www.srlabs.de/ | 2026-08-18 |
| Radically Open Security describes itself as a "Non-Profit Computer Security Consultancy" | https://www.radicallyopensecurity.com/ | 2026-08-18 |
| OTF Security Lab: supports audits for OTF-supported projects, and "projects that are not receiving OTF support but are otherwise relevant to internet freedom may apply"; covers "early-stage security assessments of their technical design, those looking for cryptographic design reviews, and those looking for code reviews"; "Audit findings are made publicly available after undergoing a responsible disclosure period"; >170 audits supported; contact `security_lab@opentech.fund` | https://docs.opentech.fund/otf-application-guidebook/our-labs/security-lab and https://docs.opentech.fund/otf-application-guidebook/llms-full.txt | 2026-08-18 |
| OTF: "places high priority on funding tools that are open-source and freely available to download and use"; beneficiary focus on "the world's most repressive environments" and the Global South; applicants in surveillance technology ineligible; overhead capped at 10% of direct costs; determination 6-8 weeks after submission | https://docs.opentech.fund/otf-application-guidebook/llms-full.txt | 2026-08-18 |
| NLnet: "all software and hardware developed **must** be published under a recognised free and open source license"; €5,000-€50,000; "anyone can apply: individuals, research organisations, non-profits, public institutions, companies"; offers "security and accessibility audits, mentoring, testing expertise"; "There is a deadline on the 3rd of every _odd_ month" | https://nlnet.nl/funding.html | 2026-08-18 |
| Alpha-Omega: requires an "OSI-approved open source license"; typically $50,000-$100,000; quarterly intake in January, April, July, October; grantees commit to monthly public reports and three public blog posts | https://alpha-omega.dev/grants/how-to-apply/ | 2026-08-18 |
| GitHub Secure Open Source Fund: requires a "Clear open source license", an "Open source first project with demonstrated community traction and adoption", maintainer in a GitHub Sponsors-supported region; $10,000 total, paid $6,000/$2,000/$2,000; rolling applications | https://github.com/open-source/github-secure-open-source-fund | 2026-08-18 |
| **Not verified at primary source:** the Sovereign Tech Agency's own eligibility criteria, funding minimum, and application process. `https://www.sovereign.tech/programs`, `https://www.sovereign.tech/programs/fund`, and `https://www.sovereign.tech/tech/openmls` each returned **HTTP 403** on 2026-08-18. Only the funding *relationship* to the OpenMLS audit is primary-sourced, via the SRLabs report and the OpenMLS announcement above. OSTIF's criteria are likewise unverified — `https://ostif.org/what-we-do/` returned HTTP 403 the same day | — | 2026-08-18 |

### 7.2 Internal consistency

| Check | Result |
|---|---|
| Gate list unchanged | **Pass.** No gate in the MLS profile is marked satisfied, partially satisfied, or advanced by this document. All seven remain open |
| Phase-A prerequisite 5 | **Pass.** Still recorded as Blocked. This document supplies the scope-of-work half only, and says so |
| No reviewer named as retained | **Pass.** Every candidate is marked not approached and not retained, in section 4.1 and in the status banner |
| Consistent with the MLS packet's review-status section | **Pass.** Both state that assembling material is not review, that gates 1-3 cannot be moved from this repository, and that gate 7 needs an external party |
| Consistent with the MLS packet's closure conditions | **Pass.** Section 3's D1-D7 are a superset of the packet's stated closure requirements (blocking/high findings resolved, exact reviewed source hashes recorded, vector reproduction on the packaged artifact, physical-device crash matrix, explicit written acceptance of residual risk). Vector reproduction and the device matrix are recorded here as gates 4 and 6 rather than as review deliverables, which matches the profile's own division |
| Consistent with the pairwise packet | **Pass.** The pairwise packet requires all blocking/high findings closed, exact reviewed source hashes, vector reproduction on the packaged Android artifact, and explicit residual-risk acceptance; WP3 and D1-D7 cover its review half |
| Consistent with ADR-017 and ADR-026 | **Pass.** ADR-017's "independent assessment" is the engagement defined here. ADR-026's prohibition on locally assigning a production identifier is restated, and no review outcome is presented as substituting for gate 2 |
| Source baseline consistent with the packets | **Pass.** The packets' baseline `4e65eaf` was verified on 2026-08-18 to be source-identical to current `HEAD` `7605659`; the difference is three documentation files and no backend file |
| Backend untouched | **Pass.** `git diff --name-only -- backend` is empty for `4e65eaf..HEAD`, and this work changed no backend file |
| Effort figures traceable | **Pass.** Every engineer-week figure in section 2.4 is quoted from the published index cited in section 7.1; the 10-16 week estimate is labelled an estimate derived from those comparables |

---

## 8. External actions the owner must authorise

None of these has been taken. Each requires an explicit decision by the owner.

1. **Decide the funding basis.** Owner-funded is the only route open while the codebase is
   closed. Everything else waits on decision 2.
2. **Decide whether the crypto core is published under an OSI-approved licence.** This is a
   strategic product decision, not a review decision. It is the single fact that unblocks
   or blocks NLnet, Alpha-Omega, GitHub SOSF, OSTIF, and the Sovereign Tech precedent, and
   it materially affects OTF's stated priority.
3. **Decide whether findings may be published.** OTF publishes audit findings after a
   responsible-disclosure period; Alpha-Omega requires public reporting. An owner who needs
   findings to stay private has ruled those routes out irrespective of licensing.
4. **Authorise contact with candidates.** No approach, enquiry, or request for a quote has
   been made to anyone in section 4, and none may be made without this authorisation.
5. **Authorise disclosure of source to a third party**, including whatever NDA the owner
   requires, before any candidate can scope the work properly.
6. **Confirm engagement feasibility on the owner's side** — contracting, payment route, and
   any export-control or sanctions considerations that apply to the owner's jurisdiction
   and the candidate's. These are legal questions this document does not attempt to answer.
7. **Fix the review revision** and record it in D1 and D2 at engagement start.
8. **Commit to producing D4 and D7 personally.** Remediation evidence and the itemised
   residual-risk acceptance are owner deliverables. A reviewer cannot supply them, and
   without them the gate stays open even after a clean report.

---

## Appendix A: owner acceptance of residual risk (D7)

**Empty. Nothing is accepted.**

This appendix exists so that D7 has a defined home. It is filled in only after a review has
actually happened, itemising each accepted residual risk individually, signed and dated by
the owner. An empty appendix means no residual risk has been accepted — never that none
exists.

## Appendix B: engagement record

**Empty. No engagement exists.**

| Field | Value |
|---|---|
| Reviewer | *none retained* |
| Named assessors | *none* |
| D1 agreed scope statement | *not produced* |
| D2 reviewed source hashes | *not produced* |
| D3 findings register | *not produced* |
| D4 remediation evidence | *not produced* |
| D5 retest confirmation | *not produced* |
| D6 independence statement | *not produced* |
| D7 residual-risk acceptance | *not produced* |
| Gate 7 status | **open** |

An empty row means the deliverable does not exist. It never means the deliverable was
waived, satisfied informally, or judged unnecessary.
