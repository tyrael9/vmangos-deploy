# PartyBot test image deployment

This fork includes a small helper for repeatedly deploying custom PartyBot
server images to an ARM64 vMaNGOS host. It changes only the `mangosd` and
`realmd` images. It does not recreate, restart, or migrate the database, and it
does not touch database backups, volumes, configuration files, or extracted
client data.

## Requirements

- Run the script from a Linux host with Bash, Python 3, Docker, and Docker
  Compose v2 installed.
- The host must be ARM64. The script rejects images that are not `arm64`.
- The host must be able to pull `ghcr.io/tyrael9/vmangos-server` (public package
  access or a prior `docker login ghcr.io` with `read:packages`).
- The repository's normal Compose file (`compose.yaml`) and local configuration
  must already be set up.

## Deploy a test build

First make sure players have logged out. Replacing `mangosd` disconnects all
currently connected players.

Use the tag shown by the successful image-publish workflow run:

```sh
./scripts/partybot-deploy.sh deploy partybot-daba395
```

The tag is an example; replace it with the exact tag published for the build
you want to test. The script:

1. Resolves the current Compose configuration and records the currently
   configured `mangosd` and `realmd` image references.
2. Pulls the requested image and verifies that its architecture is `arm64`.
3. Saves the previous two image references for rollback.
4. Recreates only `mangosd` and `realmd` with `--no-deps`.
5. Waits for both services' health checks. The default timeout is 600 seconds.

The script does not create a database dump on each run because the database
service is not restarted or changed. Continue using the configured database
backup service for database backups.

## Inspect and troubleshoot

```sh
./scripts/partybot-deploy.sh status
./scripts/partybot-deploy.sh logs
./scripts/partybot-deploy.sh logs 200
```

`status` prints the effective image references and Compose service status.
`logs` prints the latest logs for `mangosd` and `realmd`.

To change the health-check timeout for one invocation:

```sh
PARTYBOT_HEALTH_TIMEOUT=900 ./scripts/partybot-deploy.sh deploy partybot-daba395
```


## One-command diagnostics

The read-only diagnostics script collects the effective server image/status,
the two PartyBot config flags, and a timestamped tail of the current
`mangosd`/`realmd` logs. It parses `[PartyBotShadow]` summaries and prints a
small PASS/WARN/FAIL report. It also writes a mode-0600 JSON report to
`.partybot/diagnostics/latest.json`.

Run it from the deployment repository on the Oracle host:

```sh
bash scripts/partybot-diagnostics.sh
```

By default it examines the last 5,000 log lines and considers the Shadow
heartbeat stale after 120 seconds. Both can be adjusted without editing files:

```sh
PARTYBOT_DIAGNOSTICS_TAIL=10000 PARTYBOT_DIAGNOSTICS_STALE_SECONDS=180 \
  bash scripts/partybot-diagnostics.sh
```

The script uses the deployment helper's effective Compose configuration,
including its private PartyBot override. It does not restart containers, run
SQL, inspect or modify database services/volumes, or change configuration.
The `logs` helper includes Docker timestamps so freshness can be assessed.

Interpretation:
- `PlayerBot.EngineShadow=1` and `PlayerBot.DecisionTrace=1` are required for
  heartbeat summaries.
- `candidates=0 selected=0` is expected until runtime strategies/actions are
  registered; it is not a failure.
- No heartbeat is a WARN, not proof of a code defect: Shadow may be disabled,
  no eligible party bot may be active, the log window may be too short, or
  snapshot construction may not have completed.
- The report is a convenience summary of config and logs, not proof of correct
  in-game decisions. Share `.partybot/diagnostics/latest.json` for analysis;
  it contains bot/group/map identifiers and should be treated as server
  diagnostic data.

## Roll back

```sh
./scripts/partybot-deploy.sh rollback
```

The helper restores the previous image references, waits for the health checks,
and retains the just-replaced images as the next rollback target. Running
`rollback` again toggles back to the other recorded version.

The active and rollback Compose overrides are stored under `.partybot/` in the
repository directory. That directory is ignored by Git and should be kept on
the server so the helper can remember which images are active.

## Important Compose note

When a PartyBot override is active, use this helper for image deployment and
rollback. The helper explicitly includes its private Compose override file.
A plain `docker compose up -d` does not read that private file and can therefore
recreate the server with the image references from the base `compose.yaml`.

Regular read-only commands such as `docker compose ps` and `docker compose
logs` remain safe. Use `./scripts/partybot-deploy.sh status` and `logs` when you
want the helper's effective Compose configuration to be shown as well.
