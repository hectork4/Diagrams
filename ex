
This document was reviewed by Cole (CEO) who provided important context that changes several core assumptions:

| Original Assumption | Clarification from Cole |
|---------------------|------------------------|
| "Grants get mixed in one record" is a problem | `bonus_rounds` is intentionally a **wallet** model (like bet processing). This is by design. |
| "No clean mapping grant → rounds" | Traceability exists via **FIFO ordering** + `bonus_rounds_bets` table |
| "Sources are mixed without traceability" | Source is stored in `bonus_round_transaction.note` (usually `reward_manifest_id`) |
| "Data duplication is a structural problem" | Duplication is **TEMPORARY** during games migration. No real overlap. |
| "SQS will solve retry complexity" | SQS is just HTTP wrapped - still need retry/fallback mechanisms |

### Revised Recommendation

Based on this feedback:
- **PAUSE** the architectural refactor
- **WAIT** for original games migration to complete (server-betbr → gaming-service)
- **RE-EVALUATE** only if specific production problems emerge

The code developed (V2 schema by Martin, SQS modules, feature flags) remains available for future use.

---
