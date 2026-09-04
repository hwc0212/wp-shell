# 09 - Simplification Scorecard

## How to read this scorecard

The current figures are measured at `main` commit `8dd604bea4f201a797ac7e8912a843c32c6e9c4f`. Target figures are design ranges, not quotas. A smaller line count does not justify weakening an admission gate, compatibility reader, transaction, backup verifier, path check or regression test.

The scorecard separates source size from operational complexity. The latter—persistent producers, hidden background mutations, cross-feature policies and rollback obligations—is the main reason for v11.

## Measured baseline and target

| Measure | v10.0.4 measured | Post-S1-S5 target | Intended change |
|---|---:|---:|---|
| Main runtime lines | 7,303 | 4,000-4,600 | Down about 37-45% |
| Main runtime bytes | 347,861 | 190-230KB | Down about 34-45% |
| Main runtime functions | 320 | 180-220 | Fewer responsibility boundaries and feature handlers |
| Compatibility wrapper lines | 34 | Approximately current for v11 | Preserve; warn, do not rewrite |
| Documented public command forms | 60 | About 18 common Core forms plus 10-15 advanced/compatibility forms | Smaller normal operator surface |
| Shell test files | 21 | Approximately 18-22 | Do not optimize test count; strong Core/migration tests replace feature tests |
| Shell test lines | 3,323 | Approximately 3,000-4,000 | Safety coverage may stay flat or grow |
| README lines | 1,848 | Approximately 250-400 plus focused linked guides | Short operational entry point |
| README bytes | 91,094 | Approximately 20-35KB | Remove embedded implementation encyclopedia |
| SQLite historical tables | 6 | 0 | Remove metrics product/state |
| Normal-install wp-shell metrics/backup units | 4 files | 0 mandatory | No mandatory wp-shell daemon/timer |
| Other fixed generated service/timer files | 4 files | 0-2 optional Cloudflare updater files | Cache operations removed; real-IP updater remains optional |
| Per-private-Redis units | 1 service per instance | 0 new; compatibility-only existing | No new private Redis orchestration |
| Runtime implementation languages | Bash + embedded Python | Bash + small embedded Python validation | Remove curses application, retain justified safe parsers |
| Base apt packages installed | 19 | About 17; optional features on demand | Likely remove SQLite/FastCGI-only dependency after evidence; do not churn packages for the metric |
| PHP packages per version | 12 | About 12 | Site functionality, not a simplification target |
| Hidden automatic mutation loops | Metrics, tuning, cache operations, remote upload and optional site/host schedules | None mandatory; only explicit/optional schedules | Operator-visible ownership |

## Runtime reduction estimate by responsibility

These ranges overlap at shared helpers and should not be added as exact deletion promises. They are an order-of-magnitude planning check.

| Responsibility | Estimated removable/simplifiable runtime | Compatibility cost retained in v11 | Net intent |
|---|---:|---:|---|
| SQLite metrics, cursor/retention, analyzer, dashboard, automatic tuner | 1,050-1,250 lines | 100-180 lines for current capacity/status and v10 migration shims | Largest S1 reduction |
| Advanced OPcache mutation/UI | 250-350 lines | 80-140 lines for conservative baseline/effective accounting | Keep capacity evidence only |
| Private Redis and object-cache orchestration | 300-450 lines | 120-220 lines for existing-state detection/preservation | No new instances; long compatibility tail |
| FastCGI page cache, invalidation MU plugin and operations queue/timer | 400-600 lines | 150-280 lines for existing public-behavior preservation | Remove only after explicit per-site migration |
| Remote encrypted backup transport | 250-400 lines | 100-220 lines until off-host replacement is verified | Local integrity remains Core |
| Staging, bulk updates and plugin-specific operations | 300-450 lines | 60-120 lines for detection/blocking | Application policy externalized |
| Generic host extras, broad security/header policy and menu glue | 250-400 lines | 100-180 lines for SSH/UFW/Core compatibility | Distribution/administrator ownership |
| CLI/state/documentation consolidation after deletion | 200-350 lines | Compatibility wrappers/aliases remain | S3/S5, not early refactoring |

The total realistic net reduction remains about 2,700-3,300 runtime lines, yielding the 4,000-4,600 target. If compatibility evidence requires more code, safety wins and the target moves upward.

## Operational-state reduction

### Current generated background surface

Eight fixed service/timer files can be generated across current features:

- metrics service and timer;
- backup service and timer;
- operations/cache service and timer;
- Cloudflare-IP update service and timer.

Private Redis adds a service per instance. Per-site WP-Cron and AIDE may add Cron files. The number of files is less important than the number of independent failure clocks and command compatibility obligations.

### Target surface

- clean v11 installation: no mandatory wp-shell service/timer;
- optional Cloudflare official-CIDR updater: at most one service/timer pair;
- optional WP-Cron: a small, explicit, idempotent per-site schedule with staging off by default;
- distribution Certbot/unattended timers are reported as their own owners, not counted as wp-shell daemons;
- v10 units/data remain until confirmed migration and retention decisions; “not generated” does not mean “deleted.”

## State-class score

The detailed file map is in `04-STATE-AND-CONFIG-MAP.md`. At a product level:

| State category | v10 | v11 target |
|---|---|---|
| Authoritative Core configuration | Mixed with optional feature policy | Narrow environment/site/credential/PHP/manual-worker/Core-policy state |
| Derived historical telemetry | SQLite, cursors, health, recommendations | None |
| Background-operation queues | Cache/event operation state | None in Core |
| Local backup metadata | Manifest/checksums/archive/SQL | Keep and strengthen verification |
| Restore control state | Minimal/incomplete current behavior | One small root-only failed-restore receipt, not a state machine |
| Transaction/rollback metadata | Managed config fingerprints/backups | Keep |
| Optional-feature compatibility state | Actively generated/mutated | Read/preserve/block until explicit external migration |
| Secrets | Credentials, Redis/remote encryption state | Keep only Core-required site/database secrets; never log; retired secrets preserved until owner migration |

## Complexity drivers and expected benefit

| Rank | Driver | Current cost/risk | Simplification benefit |
|---:|---|---|---|
| 1 | Metrics/dashboard/tuner | Persistent database, minute timer, embedded UI and automatic mutations tied into capacity | Removes the largest code/state/background cluster while making worker changes explicitly operator-owned |
| 2 | Feature-rich per-site policy | Site repair/apply can own cache, Redis, staging, security, Cron and TLS simultaneously | Narrows blast radius and makes unknown/retained behavior visible |
| 3 | Backup + remote transport + restore | Integrity, retention, encryption, scheduling and recovery have different failure semantics | Core focuses on verified local artifacts and conservative recovery; off-host tooling gets an explicit owner |
| 4 | Private Redis + full-page cache | Services, sockets, secrets, drop-ins, Nginx routing, queues and invalidation | Large reduction in credentials, background work and application-plugin coupling |
| 5 | Generic host and WordPress application operations | wp-shell becomes a control panel for unrelated system/plugin policy | Smaller contract, fewer surprising mutations and easier production review |

## Safety scorecard

| Invariant | v10.0.4 | v11 design target |
|---|---|---|
| PHP aggregate budget | Hard admission implemented | Preserve; current PSS can only make it more conservative |
| Swap treatment | Excluded from resident worker capacity | Preserve |
| Effective pool validation | Default and per-site semantic checks | Preserve |
| Imported-site pre-persistence admission | Implemented | Preserve |
| MariaDB legacy risk | Effective audit and explicit transactional migration | Preserve |
| Managed config transaction | Candidate/validate/backup/atomic replace/rollback | Preserve |
| Administrator-file ownership | Conflict/fingerprint safeguards | Preserve/clarify |
| Per-site PHP identity | Implemented | Preserve |
| WordPress config permissions/write window | Implemented | Preserve |
| Backup verification | Checksums/archive/SQL safety present | Preserve and expose deep disposable-DB verification |
| Restore failure recovery | Safety backup exists but actionable automatic recovery is incomplete | Improve in S4 with exact safety ID, fail-closed maintenance and explicit recovery |
| Optional feature migration | Active feature creation/management | Preserve existing behavior; explicit owner transition; no silent deletion |

## Dependencies and maintenance score

### Dependencies deliberately retained

- Python 3 for strict archive-member and CIDR parsing: already in supported Ubuntu and security-relevant.
- `jq` while current WordPress release JSON handling uses it: replacing a few calls is not an S1 safety improvement.
- existing Ubuntu repositories and service managers: no new third-party package source.
- single-file distribution: no runtime loader/build-chain migration.

### Dependencies expected to leave the clean baseline

- SQLite after historical metrics are fully disconnected and v10 data becomes inactive.
- `libfcgi-bin` only if Core health/effective verification no longer uses it after S1/S2 review.
- rclone, AIDE, Postfix and unattended-upgrades as wp-shell-installed product features; an administrator may still install/use them independently.

No score is awarded for removing an already-installed dependency from an upgraded host. v11 simply stops requiring it for new Core operation; package removal remains the administrator's decision.

## Success criteria

v11 is simpler when all of the following are true:

- a clean install creates fewer persistent producers and no metrics database;
- a normal operator can understand install, status/audit/capacity, site lifecycle and backup/restore without navigating optional subsystem menus;
- a Core apply has a smaller, explicit ownership set;
- worker safety no longer depends on a minute collector but is not less conservative;
- old page cache/private Redis/remote backup/staging behavior is detected and preserved or blocked, never silently changed;
- rollback and restore are clearly different and both honest about their scope;
- tests continue proving production invariants even if their total line count does not fall;
- no new daemon, management port, framework or plugin assumption replaces the deleted complexity.

## Non-goals

- optimizing for the smallest possible Bash file;
- matching Cloudways, SpinupWP or a web control panel feature list;
- improving PageSpeed scores through infrastructure-wide plugin/theme assumptions;
- automatically tuning a diverse fleet from incomplete evidence;
- forcing every v10 host to remove optional state during upgrade;
- using Swap to make an unsafe worker allocation look admissible;
- merging the unreviewed restore state-machine branch as a shortcut;
- rewriting the project before responsibility deletion is proven.
