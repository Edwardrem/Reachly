# Run the demo yourself

The recorded demo runs against four Docker servers: `bastion`, `web-01`, `db-01` and `build-box`. They are here, so
anyone with Docker can run the same incident live, with their own AI key, and measure the run from Reachly's own
audit log.

## The incident

`web-01` runs a small shop: nginx in front of an orders API. Fifteen days ago the logrotate timer was switched off,
and a load-balancer health check started calling `/healthz` three times a second. The nginx access log grew until it
filled `web-01`'s 692 MB `/var` volume, 50 minutes before you start. With `/var` full, the orders API can't save
orders, so checkout returns HTTP 500. The shop's log shows 24 failed checkouts.

A good fix frees the space, turns the logrotate timer back on, and tests a real rotation. That test shows a second
fault. nginx's rotate hook (`invoke-rc.d`) is refused in the container, so nginx keeps writing to the rotated file.
The logrotate timer is off on the other three hosts too.

Nothing is simulated in Reachly. These are real sshd servers, the disk really is full, and every command really runs.

## What you need

- A Mac with Reachly, and an AI provider set up in Settings › AI Integration. The video used CAIMEx with DeepSeek
  V4 Flash.
- Docker, running (Docker Desktop on a Mac). The first `up.sh` builds the image from `ubuntu:24.04`, which takes a
  minute or two and needs the network.
- `ssh`, `ssh-keygen` and `python3` 3.9 or later. macOS has all three.
- Disk space, measured on Docker Desktop:
  - in Docker: about 1.4 GB (the image is 279 MB, `web-01` 690 MB, `build-box` 441 MB);
  - on your Mac: about 510 MB for the generated logs in `demo/fleet/.state/`.
- Memory: under 100 MB for all four servers.

`web-01` runs `--privileged`, for one reason. Its `/var` is a small ext4 volume of its own, on a loop device under
device-mapper, so it can fill up while `/` still has room. Only the bastion publishes a port, on `127.0.0.1`. The
other three are reached through it.

## Start the servers

```sh
demo/fleet/up.sh
```

`up.sh` does the following:

- builds the image if it's missing;
- makes a host key for each server and a client key, in `demo/fleet/.state/`. Nothing secret is in the repo;
- writes fresh logs, because the story is told relative to now;
- starts `reachly-demo-bastion`, `-web-01`, `-db-01` and `-build-box` on the network `reachly-demo-net`;
- waits until each server takes the key.

The bastion listens on `127.0.0.1:2200`. Port 2222 is left for the repo's test sshd. To use another port:
`REACHLY_DEMO_PORT=2201 demo/fleet/up.sh`. Running `up.sh` again gives you a fresh incident.

Check it from a terminal, with the ssh config `up.sh` wrote:

```sh
ssh -F demo/fleet/.state/ssh_config web-01 'df -h /var'
```

## Add the hosts to Reachly

`up.sh` writes `demo/fleet/.state/reachly-demo.reachly`, a plain Reachly file with no secrets. It holds the four
hosts, the jump host, the key file, the four host keys and the AI permission modes the video started with.

1. Optional, but it keeps the demo hosts and their audit log apart from yours: quit Reachly, then start it on a
   separate data folder. Your AI settings and key are shared with this window, so the assistant works there too.

   ```sh
   open -n -a Reachly --env REACHLY_DATA_DIR="$PWD/demo/fleet/.state/reachly-data"
   ```

2. Choose File › Import… (⇧⌘O), pick `demo/fleet/.state/reachly-demo.reachly`, and click **Import 11 Records**. You
   get 2 groups, 1 key, 4 hosts and 4 trusted host keys. Importing the file again updates these records; it doesn't
   add copies. If you change the port, run `up.sh` and import the file again.

Reachly can also import an ssh config (File › Import From › ~/.ssh/config…), but that won't set up this fleet. It
reads only `~/.ssh/config`. It keeps `ProxyJump` as a note on the host rather than setting the jump host. It sets no
permission modes.

To add the hosts by hand instead:

1. Add `demo/fleet/.state/id_ed25519` as a key-file identity.
2. Add `bastion`: hostname `127.0.0.1`, port `2200`, user `jump`, that identity.
3. Add `web-01`, `db-01` and `build-box`: the hostname is the host's own name, port `22`, user `deploy`, that
   identity, and Route › Jump host `bastion`.
4. Set Claude agent › Permission to Read-only on all four.
5. On the first connection, compare each host key with `ssh-keygen -lf demo/fleet/.state/keys/<host>/host_key.pub`.

## Run it as in the video

Permission modes:

| Host      | At the start | Before the third message |
|-----------|--------------|--------------------------|
| bastion   | Read-only    | Read-only                |
| web-01    | Read-only    | Ask every time           |
| db-01     | Read-only    | Read-only                |
| build-box | Read-only    | Read-only                |

1. Connect to `web-01` (⌘K, `web-01`). Open the Claude panel (View › Show Claude Panel, ⇧⌘A), and leave its scope on
   All hosts.
2. Ask, exactly:

   > Customers say checkout on web-01 is failing. Find out why, then write a one-page PDF report for the team.

3. When it has answered, ask:

   > Please free up the space and make sure it can't happen again, then check that checkout works.

   `web-01` is read-only, so the change is refused (recorded as `blocked`), and the assistant explains the fix
   instead.
4. Edit `web-01` (right-click › Edit…). Set Claude agent › Permission to **Ask every time**, and save.
5. Ask:

   > web-01 now asks before every command. Go ahead with the fix, then check that checkout works.

   Each command now waits in the approval sheet, for you to approve, edit or deny it.

A different model, or the same one on another day, takes a different path, so your counts will differ from the
video's. Builds newer than the video also have a stricter command guard, so a read-only host may refuse a few
commands the video shows running. The incident is the same.

## Measure the run

`measure.py` reads Reachly's agent audit log. Reachly writes one record for every command or file action the AI asks
for: the host, the command, the decision, the exit status and how long it ran. It runs on Python 3.9 or later, with
the standard library only.

```sh
python3 demo/measure.py demo/fleet/.state/reachly-data --last   # the data folder from step 1 above
python3 demo/measure.py                                         # your usual data folder
python3 demo/measure.py Reachly-agent-audit-2026-11-26.json     # an export: AI History › ⋯ › Export JSON…
```

The log lives in `Reachly.store` in the data folder. The default is `~/Library/Application Support/Reachly/`, or
`$REACHLY_DATA_DIR`. `measure.py` reads a copy, so it is safe to run while Reachly is open. `--json` prints the same
numbers as JSON. For each conversation it prints:

- start: when the first command started;
- end: when the last command ended;
- elapsed time, and the longest gap between two commands. That gap is mostly the time a person took, such as the
  switch to Ask in step 4;
- the commands, and how many ran;
- the hosts touched;
- the count of each decision.

This is its output for the recorded run:

```text
Conversation D93940FB-E476-4D0F-AC67-E5CA1F4E9103
  Customers say checkout on web-01 is failing. Find out why…
  start       2026-11-26 19:40:45 +0200   (first command starts)
  end         2026-11-26 19:54:11 +0200   (last command ends)
  elapsed     13m 26s   (longest gap between commands: 4m 05s, 19:43:24 to 19:47:29)
  chat        first message 19:40:39, last saved 19:54:30 (13m 50s)
  commands    52 asked for: 45 ran, 7 not run   (run_command 51, read_file 1)
              1 of those that ran exited non-zero
  hosts       4: web-01 46, bastion 2, build-box 2, db-01 2
  decisions   auto-allowed 18, approved 27, edited 0, denied 0, blocked 7, cancelled 0, changes-requested 0
```

The decisions mean:

- `auto-allowed`: the host's mode let the command run without asking;
- `approved` and `edited`: a person said yes, after changing the command in the case of `edited`;
- `denied`: a person said no;
- `blocked`: the host's mode refused the command, and nobody was asked.

The team's proposed pilot would measure the same way: from the audit log Reachly writes for every AI action, not a
stopwatch. Anyone can check the numbers against the store or an export.

## Tear it down

```sh
demo/fleet/down.sh
```

This removes the four `reachly-demo-*` containers and the `reachly-demo-net` network, and nothing else. `web-01`'s
loop and device-mapper devices go away on their own when its container stops, so nothing is left in Docker's kernel.

The image stays, so the next `up.sh` starts quickly; `down.sh` prints the command that removes it.
`demo/fleet/.state/` keeps the keys, the logs and the optional Reachly data folder, so the next `up.sh` keeps the
same host keys. Delete that folder to remove all of them. If you imported the hosts into your usual Reachly, delete
them there too.
