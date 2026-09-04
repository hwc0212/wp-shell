# wp-shell v10 legacy snapshot

`wp-shell-v10.0.4.sh` is the frozen historical and stable/LTS snapshot of
the runtime published as Git tag `v10.0.4`.

The file is byte-for-byte identical to `wp-shell.sh` at that tag. It is kept
executable and must not receive feature development, modernization, cleanup,
or silent fixes.

If a critical v10 security issue, severe data-integrity issue, or severe
compatibility regression requires maintenance, make the fix from the
`v10-maintenance` branch and publish a new reviewed 10.x patch release such as
`10.0.5`. Do not edit this `v10.0.4` snapshot in place.

The simplified v11 implementation is developed separately on the `v11`
branch in `wp-shell-v11.sh`. v11 development does not make v10.0.4 unsafe or
deprecated, and existing v10 installations do not need to migrate merely
because v11 development exists.
