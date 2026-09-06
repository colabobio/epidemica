# Running an Epidemica server on AWS

> **Not yet run.** These instructions were written against the code as it stands and are internally
> consistent with it, but no part of this has been executed end to end — there is no Docker daemon
> in the development environment. Treat the first deployment as a test of this document as much as
> of the infrastructure, and correct it in place when something is wrong.

Self-hosting is the priority for Epidemica, so this deliberately does **not** describe a
cloud-native architecture that only works on AWS. It describes running the same container an
institution would run on its own hardware, on an EC2 instance. One artefact, one set of
instructions, one thing to debug — and a US study can be served without the project acquiring a
second deployment story that then has to be kept working.

The ECS path is at the bottom for teams with existing AWS practice.

## What makes this server unusual

**It contains a Python interpreter.** The twin runs Starsim as a subprocess. A server built without
it starts cleanly, serves enrollment, accepts observations, and then fails every tick with
`{:engine_unavailable, ...}` — which on a participant's phone looks like a study where nothing ever
happens. [`../docker/Dockerfile`](../docker/Dockerfile) installs both halves; a buildpack or a
stock `phx.gen.release` image will not.

**It hands devices an absolute URL.** `protocol_url` is built from `PHX_HOST`, and the app fetches
that URL directly. Get it wrong and enrollment *succeeds*, the bundle fetch fails, and the app
refuses the study with nothing logged server-side. This is the single most common way a deployment
appears to work and does not.

**Phones will not accept plain HTTP.** Android blocks cleartext by default from API 28 and iOS App
Transport Security blocks it too, so TLS is not optional for anything past a simulator.

## Sizing

A study is small. 60 participants uploading contact episodes every 15 minutes is a few hundred
rows an hour, and a daily tick is one Python process for a few seconds. `t4g.small` (2 vCPU, 2 GiB)
is comfortable; the binding constraint is the ~1.5 s Starsim import per tick, not throughput.

Budget roughly 20 GB of disk. Observations are the bulk and they are small.

## 1. Prepare

You need:

- An AWS account and a region. Use `us-east-1` or `us-west-2` for US studies unless there is a
  reason not to.
- A DNS name you control, e.g. `study.epidemica.info`. **Decide this before you build anything** —
  it is baked into `PHX_HOST` and therefore into every `protocol_url`, and changing it after
  devices have enrolled means they can no longer fetch their protocol.
- The repository checked out on your machine.

## 2. Network and instance

```sh
REGION=us-east-1
NAME=epidemica-study

# Security group: HTTP and HTTPS from anywhere, SSH from your address only.
aws ec2 create-security-group --group-name "$NAME" \
  --description "Epidemica study server" --region "$REGION"

SG=$(aws ec2 describe-security-groups --group-names "$NAME" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION")

aws ec2 authorize-security-group-ingress --group-id "$SG" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION"
aws ec2 authorize-security-group-ingress --group-id "$SG" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "$REGION"
aws ec2 authorize-security-group-ingress --group-id "$SG" \
  --protocol tcp --port 22 --cidr "$(curl -s https://checkip.amazonaws.com)/32" --region "$REGION"
```

Launch an instance. Prefer Session Manager over an SSH key if your account is set up for it — one
fewer credential to look after:

```sh
aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id \
  --instance-type t4g.small \
  --security-group-ids "$SG" \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true}' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
  --region "$REGION"
```

Allocate an Elastic IP and associate it, so the address survives a stop/start — otherwise a reboot
silently breaks every enrolled device:

```sh
aws ec2 allocate-address --domain vpc --region "$REGION"
# then associate-address with the allocation and instance ids
```

Point your DNS `A` record at that Elastic IP and wait for it to resolve. Certificate issuance
depends on it.

## 3. Install and build

On the instance:

```sh
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git
sudo usermod -aG docker ubuntu && newgrp docker

git clone https://github.com/colabobio/epidemica.git
cd epidemica/deploy/docker

cp .env.example .env
```

Fill in `.env`:

```sh
PHX_HOST=study.epidemica.info
POSTGRES_PASSWORD=$(openssl rand -base64 36)
SECRET_KEY_BASE=$(docker run --rm hexpm/elixir:1.18.4-erlang-28.0.1-debian-bookworm-20250630-slim \
  sh -c 'mix local.hex --force >/dev/null && mix phx.gen.secret' 2>/dev/null | tail -1)
```

Then build and start. The first build is slow — it compiles Elixir dependencies and resolves the
Python environment:

```sh
docker compose build
docker compose up -d db
docker compose run --rm server /app/bin/migrate
docker compose up -d
```

Check it came up, and check the part that is easy to get wrong:

```sh
curl -s https://study.epidemica.info/v1/health

# The twin can actually reach Python. If this is not {:ok, ...} the study will run and simulate
# nothing, which is the failure this whole page exists to prevent.
docker compose exec server /app/bin/epidemica_server eval '
  EpidemicaServer.Twin.Runner.run(%{
    "study_id" => "smoke", "day" => 1, "seed" => 1, "population" => 2,
    "pars" => %{"diseases" => %{"beta" => 0.5}},
    "protection" => %{"efficacy" => 1.0, "blocks_transmission" => true},
    "agents" => [
      %{"index" => 0, "subject" => "a", "virtual" => false, "state" => "infected", "infected_on_day" => 0},
      %{"index" => 1, "subject" => "b", "virtual" => false, "state" => "susceptible"}
    ],
    "contacts" => [], "total_cases_before" => 0
  }) |> elem(0) |> IO.inspect(label: "twin")
'
```

## 4. Register a study

The bundle's bytes are stored verbatim and its hash derived from them, so upload the file rather
than pasting it:

```sh
docker compose cp ../../studies/epigame7/bundle.json server:/tmp/bundle.json

# Set a real start date first — the committed one is a placeholder, and the schedule is part of the
# protocol, so this changes the bundle hash. That is correct: a study starting on a different day
# is a different study.
docker compose exec server /app/bin/epidemica_server eval '
  bundle = File.read!("/tmp/bundle.json") |> Jason.decode!()
  bundle = put_in(bundle["schedule"]["starts_at"], "2026-09-14T04:00:00Z")
  source = Jason.encode!(bundle)
  {:ok, study} = EpidemicaServer.Studies.create_study_from_bundle("Epigame seven-day", source)
  {:ok, _} = EpidemicaServer.Studies.add_join_code(study, "EPIGAME-7")
  IO.puts("study #{study.id} code EPIGAME-7")
'
```

Note `starts_at` is an absolute instant. `2026-09-14T04:00:00Z` is midnight in New York on daylight
time — pick the instant that corresponds to local midnight where the study runs, and check whether
daylight saving changes during it.

## 5. Advance the days

Ticks are scheduled automatically. `Oban.Plugins.Cron` runs `Twin.Scheduler` hourly, and the
scheduler itself decides which study-days are due and enqueues them — see
[`tasks/done/0002-scheduled-ticks.md`](../../tasks/done/0002-scheduled-ticks.md) for the design, and
note in particular that a day is only offered once its period has ended *plus* a buffer derived from
the study's own `sync.min_interval_seconds` (or a 30-minute default), so late uploads have time to
land before the network is frozen.

Nothing needs to be configured for this to work. It is wired into the image's own
`config/config.exs`, not into anything an operator sets.

### Checking it is actually working

A scheduler that has never run looks exactly like a scheduler that is running fine and finding
nothing due, until it doesn't. Check it explicitly rather than assuming:

```sh
# Which days are currently due, if any
docker compose exec server /app/bin/epidemica_server eval '
  EpidemicaServer.Twin.Scheduler.due_ticks() |> IO.inspect(label: "due")
'

# What the scheduler has actually enqueued and run so far
docker compose exec server /app/bin/epidemica_server eval '
  EpidemicaServer.Repo.all(
    from j in Oban.Job, where: j.worker == "EpidemicaServer.Twin.Scheduler",
    order_by: [desc: j.inserted_at], limit: 5
  ) |> Enum.map(&{&1.state, &1.inserted_at}) |> IO.inspect(label: "scheduler runs")
'
```

A study that should have ticked and has not is a study whose scheduler is not running — check the
second of these before concluding anything else. `Ops.status/1` and `Ops.catch_up/1` (see section 4)
are the operator-facing entry points for the same question from a different direction.

## 6. Backups

Participant data is not reproducible. Take a nightly dump to S3:

```sh
aws s3api create-bucket --bucket epidemica-backups-<suffix> --region "$REGION"
```

```cron
0 3 * * * cd /home/ubuntu/epidemica/deploy/docker && /usr/bin/docker compose exec -T db \
  pg_dump -U epidemica epidemica_server | gzip | \
  /usr/local/bin/aws s3 cp - s3://epidemica-backups-<suffix>/$(date +\%F).sql.gz
```

Enable versioning and a lifecycle rule on the bucket. **Restore-test it once** before a study
starts; a backup nobody has restored is a hypothesis.

## 7. Updating

```sh
git pull
docker compose build
docker compose run --rm server /app/bin/migrate
docker compose up -d
```

Migrations are additive so far, so this is a short outage rather than a risky one. Do not deploy
mid-study without reading the diff: the twin records `engine_version` on every tick precisely so
that a Starsim upgrade during a study is visible in the data, but visible is not the same as
harmless.

## Alternative: ECS Fargate

Worth it if your institution already runs ECS. Not worth it otherwise — it replaces one thing to
understand with five.

- Build and push the same image to ECR.
- RDS PostgreSQL, `db.t4g.micro`, in private subnets. Set `DATABASE_URL` from Secrets Manager.
- One Fargate service, **desired count 1**, behind an ALB with an ACM certificate.
- `SECRET_KEY_BASE` from Secrets Manager; `PHX_HOST` the ALB's DNS name or your CNAME.
- Health check `/v1/health`.

Ticks run on their own via `Oban.Plugins.Cron` — no EventBridge schedule is needed. **Keep the
desired count at 1.** `Oban.Plugins.Cron` runs only on the leader node, so a two-task deployment
would not double-schedule — but the `twin` queue's `twin: 1` limit is per node, not per cluster, so
two tasks could still run ticks concurrently if a job were ever enqueued by hand. The unique index
on `twin_ticks (study_id, day)` means the loser fails rather than corrupting anything, and the
failure would be silent in the logs of whichever node lost. One node makes that impossible.

## Costs

Roughly, `us-east-1`, on-demand:

| | |
|---|---|
| `t4g.small` | ~$12/month |
| 20 GB gp3 | ~$2/month |
| Elastic IP (attached) | free |
| S3 backups | pennies |

The ECS path adds an ALB (~$18/month) and RDS (~$12/month for `db.t4g.micro`), roughly tripling it
for a study that does not need the capacity.

## See also

- [`../docker`](../docker) — the image both this and a self-hosted deployment use
- [`../app-release`](../app-release) — building the app against this server
- [`../local`](../local) — running a study on a laptop
