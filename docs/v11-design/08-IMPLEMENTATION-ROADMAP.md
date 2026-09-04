# 08 - v11 Implementation Roadmap

## Delivery rules

- Each stage is a separate, narrowly scoped branch and pull request.
- No stage is merged until its own old/new compatibility fixtures and rollback path pass.
- Source remains a single-file runtime distribution. Test fixtures and design/user documentation may remain separate.
- Remove behavior before refactoring structure. Do not spend risk budget moving unchanged functions.
- Never combine restore changes with monitoring/cache/Redis/CLI deletion.
- Every mutating stage starts with read-only discovery and ends with effective verification.
- A roadmap stage may stop at a compatibility shim when safe ownership migration is not yet proven.
- `10.0.4` remains the rollback/reference release; S0 makes no version change.

## Branch and script policy during development

```text
main                         stable v10 line; root wp-shell.sh remains the default
v10-maintenance              critical security/data-integrity/compatibility fixes only
v11                          simplified development base
legacy/wp-shell-v10.0.4.sh   immutable byte-for-byte v10.0.4 snapshot
wp-shell-v11.sh              experimental v11 implementation, not production GA
```

S1-S6 feature branches target `v11`, never `main`. Until v11 GA, the root `wp-shell.sh` and existing raw-main download URL remain v10. A development installation may use `/usr/local/sbin/wp-shell-v11`, but normal v11 testing must not replace `/usr/local/sbin/wp-shell`. The development script shares existing production namespaces only on deliberately selected disposable/test systems; it does not create a second control plane merely for namespace symmetry.

## S0 - Design and frozen baseline

Status: this documentation-only proposal.

Scope:

- record the exact `10.0.4` baseline and validation;
- inventory runtime, commands, persistent state, units, policies and dependencies;
- classify every public command and major feature;
- define the smaller CLI/Core boundary;
- define migration blockers, test disposition and reduction estimates;
- compare current restore, the unmerged Phase 2C proposal and conservative restore.

Explicit exclusions:

- no runtime, README, wrapper, test, workflow or version edits;
- no production host access;
- no deletion or migration;
- no Phase 2C implementation.

Exit gate:

- documentation-only diff;
- baseline `bash -n`, ShellCheck, local static/unit tests and exact-SHA GitHub checks recorded;
- design reviewed before S1 begins.

## S1 - Remove historical monitoring and automatic tuning

Primary result: delete the largest self-contained complexity cluster while preserving the PHP hard-safety invariant.

### Add before deleting

- current-state `capacity` output;
- explicit `site DOMAIN workers N --confirm` using `/etc/wp-shell/tuning.v1` as manual desired state;
- conservative current managed-pool PSS estimator that may only raise the baseline;
- effective OPcache accounting per active PHP version;
- read-only v10 migration preflight for metrics/tuner state;
- confirmed, reversible disablement of metrics producer with unit-state recording;
- non-mutating compatibility route for retired scheduled entry points during the compatibility window;
- direct `status` output replacing only essential current-state dashboard facts.

### Remove

- SQLite schema, collection, cursors, retention and health bookkeeping;
- metrics service/timer creation for new installs;
- terminal curses dashboard;
- historical traffic/resource report and analysis;
- automatic recommendations, sample thresholds and `tune --apply` expansion;
- metrics-only dependencies after all call edges are gone.

### Preserve unchanged

- hard aggregate worker budget, Swap exclusion and non-FPM reserves;
- effective default/site pool parsing and mismatch veto;
- aggregate manual override validation;
- imported-site admission before persistence;
- post-write semantic verification and rollback;
- MariaDB legacy gate, all transaction safety, site isolation and backup/restore behavior.

### Tests/gates

- all Phase 2B invariants re-homed without SQLite;
- 1/2/4/8/16GB and mixed-site matrix;
- current-PSS invalid/stale/upward-only cases;
- no clean install creates SQLite/metrics units;
- v10 data preserved and producer disablement reversible/idempotent;
- no restore, cache, private Redis, remote backup or staging diff.

Stop S1 if current-state evidence cannot conservatively replace the PSS safety input. Do not keep the auto tuner merely to reuse its database.

## S2 - Retire optional acceleration and application orchestration

S2 is a sequence of small PRs, not one broad deletion.

### S2a - Advanced OPcache ownership

- stop exposing automatic OPcache tuning/mutation commands;
- retain a conservative new-install baseline and read-only effective per-version reserve;
- preserve safe existing overrides and block on conflicting administrator state;
- do not lower or enlarge OPcache merely because a feature is removed.

### S2b - Private Redis and object-cache orchestration

- stop offering private Redis for new sites;
- keep shared Redis loopback baseline without automatic plugin activation;
- detect and preserve existing instances, secrets, sockets and WordPress connection state;
- provide a separate externalization runbook; no shared-Redis fallback;
- delete runtime creation/migration code only after compatibility fixtures prove existing site apply/status is safe.

### S2c - FastCGI Page Cache Lite and cache orchestration removal

- retain Nginx-to-PHP-FPM FastCGI transport, per-site Unix sockets, required parameters, timeout/buffer compatibility and effective validation;
- retain default-off Page Cache Lite with explicit per-site enable/disable/status/manual clear;
- render one conservative generic WordPress bypass set and an additional WooCommerce set only when WooCommerce is an explicit site property;
- remove plugin auto-discovery, Pretty Links/RFQ/theme-specific logic, arbitrary exclusion CLI, automatic Cloudflare/APO coordination, historical cache metrics and automatic tuning;
- migrate/disable the automatic invalidation MU plugin/operations timer explicitly while preserving files and custom Nginx state;
- preserve effective legacy public behavior or block the affected apply;
- never delete cache data or MU plugins automatically;
- retain static-resource browser cache headers independently.

### S2d - Remote backup transport

- retain verified local backup/verify/backup-all;
- stop creating new rclone/encryption policies;
- preserve existing upload until a verified external replacement exists;
- block migration if it is the only off-host protection;
- only then remove upload/timer/config-generation code from Core.

### S2e - Staging and application operations

- remove new staging/clone orchestration and plugin-specific assumptions;
- remove bulk WordPress core/plugin/theme upgrade orchestration;
- remove Action Scheduler-specific inspection;
- detect/preserve existing staging routes/data;
- keep optional simple WP-Cron only if it stays idempotent and safe from unintended staging execution.

### S2f - Generic host extras and broad policies

- externalize AIDE, Postfix and unattended-upgrades management;
- retain explicit SSH/UFW safety and status;
- retain minimal compatibility-first Nginx security controls;
- stop newly managing broad HSTS/strict-header profiles while preserving existing serving behavior;
- keep Cloudflare official-CIDR real-IP compatibility only.

Every S2 PR must show clean-new-install absence plus existing-v10 preservation. If preservation needs most of the old implementation, keep the compatibility code for v11 instead of forcing deletion.

## S3 - Consolidate CLI, state and compatibility surface

Primary result: make the smaller product understandable after behavioral deletions are already safe.

Scope:

- implement the noun-based CLI contract in `03-CLI-CONTRACT.md`;
- reduce interactive menu to Core lifecycle/backup/audit/capacity actions;
- retain numeric site selectors and legacy wrappers as one-major compatibility paths;
- repurpose the former no-op migration command as explicit `migrate v10` preflight/confirmation;
- separate read-only loading from path initialization and migration;
- stop writing removed derived state on clean installs;
- preserve unknown fields and inactive historical data;
- add state-version/ownership output without a sweeping schema rewrite;
- remove retired command shims only when migration-state evidence proves no active caller.

Do not rename every internal function or reformat the entire script. The CLI/state cleanup follows behavior removal so reviews can distinguish product changes from code movement.

Tests/gates:

- every old documented command classified as forward/warn/block/remove;
- read-only commands produce no filesystem/service mutations;
- wrapper forwarding and argument fidelity;
- corrupt/unknown state fail-closed behavior;
- v10 migration and rollback idempotency;
- no change to site routing, effective pools or backups from CLI translation alone.

## S4 - Conservative restore transaction

Primary result: make restore recoverable without adopting the large persistent Phase 2C state machine.

Scope only:

1. deep-verify the requested backup;
2. create and verify a current-site safety backup and print its exact ID;
3. enter and prove fail-closed maintenance;
4. restore files, database, permissions and managed connection state;
5. run bounded, non-mutating WordPress verification;
6. exit maintenance on success;
7. on failure keep maintenance and both backups, write a small root-only failure receipt, and print an exact confirmed safety-backup recovery command.

The receipt contains identity and recovery evidence, not a multi-stage automatic resume machine. Recovery always names the safety backup explicitly and requires confirmation.

Out of scope:

- automatic forward resume;
- multi-operation state machine/journal;
- distributed/remote transaction semantics;
- automatic mail/form/task execution as verification;
- remote-backup redesign;
- claiming atomicity across filesystem and MariaDB.

Tests/gates:

- failure injection at every destructive boundary;
- disk-full/interruption/corruption/path/symlink/permissions/secret tests;
- exact recovery ID and fail-closed maintenance assertions;
- successful recovery and idempotency;
- local backup format compatibility;
- no unrelated runtime subsystem change.

The existing unmerged Phase 2C PR remains a reference for failure scenarios, not the implementation base to merge wholesale.

## S5 - User documentation and release migration guide

Only after runtime contracts stabilize:

- replace the 1,848-line README with a concise Chinese quick start, supported platforms, common lifecycle/backup/audit commands, safety model and links;
- publish a detailed v10-to-v11 migration guide based on S3's real behavior;
- document external ownership examples for remote backups, monitoring, cache, staging and host policy without endorsing a mandatory vendor/plugin;
- document recovery drills and the difference between config rollback and site restore;
- document compatibility duration and deprecation dates;
- generate a command reference from tested `--help` output or validate them against each other;
- keep server-side CLI output English/ASCII.

Documentation must not promise a removed feature, present a configured budget as measured memory, or describe an untested backup as recoverable.

## S6 - Reassess maintainability and packaging

S6 begins only after measured S1-S5 complexity reduction.

Questions:

- Is the remaining approximately 4,200-4,800-line single file reviewable with current section boundaries?
- Are repeated render/validate/transaction patterns already centralized enough?
- Would a build step or multiple mandatory runtime files increase upgrade/rollback risk more than it helps maintenance?
- Can static generated artifacts reduce duplication without changing single-file distribution?

Default answer: retain one distributed file. Refactor only duplicated, high-risk logic with direct tests. Do not introduce a framework, package manager, daemon, web UI, public management port or runtime module loader.

## Release sequencing

```text
10.0.4 frozen reference
  -> S0 reviewed design
  -> S1 monitoring/tuner removal + capacity replacement
  -> S2a..S2f independent optional-feature simplification/migrations, including Page Cache Lite
  -> S3 CLI/state consolidation
  -> S4 conservative restore
  -> S5 user documentation
  -> S6 evidence-based maintainability reassessment
```

Version numbering and release tagging are implementation decisions after review. No design PR should consume a runtime version.

## Global go/no-go gates

Proceed to the next stage only when:

- Git diff is limited to the declared ownership area;
- all existing relevant tests and new regressions pass without weakened assertions;
- clean install, repeated apply and v10 compatibility fixtures pass;
- configuration candidates and effective services are both validated;
- failure injection proves no partial live write or misleading success;
- no secret is exposed;
- migration and rollback are operator-readable and deterministic;
- remaining compatibility shims and blockers are explicitly listed.

Stop and redesign if a deletion would:

- bypass PHP/MariaDB admission;
- share site execution identities;
- overwrite administrator configuration;
- silently change public caching/routing;
- stop the only remote backup;
- make a restore less recoverable;
- require a new daemon/database/public port;
- convert a safe reload to an unnecessary restart;
- bundle unrelated cleanup to make the line-count target look better.
