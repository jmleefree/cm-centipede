# gendata — test data generator

Fills the resources provisioned by OpenTofu with test data, so cm-centipede has
something real to migrate:

| Target | What lands there |
|---|---|
| **bucket** | Dummy files uploaded to an object storage bucket over the S3 API |
| **filesystem** | The same dummy files transferred to a VM over SFTP |
| **database** | The `shop_db` tables and seed data, loaded with native Go drivers |

Works against **AWS** and **NCP**, selected with `--provider`.

> gendata is a **standalone Go module**, separate from the repository root
> module. Run go commands with `GOWORK=off` so they build against this module's
> own `go.mod` regardless of any `go.work` above it; the `Makefile` sets it for
> you.

---

## Quick start

```bash
# 1. The infrastructure must already exist - see ../README.md
cd tofuenv
./scripts/up.sh
./scripts/provision.sh aws bucket

# 2. Build and run - through the wrapper, which assembles the connection info
./scripts/gen-data.sh --target bucket --provider aws
```

gendata is told where the resources are; it looks nothing up itself. The
connection info arrives as JSON on stdin, assembled by whichever environment
provisioned them — [`../scripts/gen-data.sh`](../scripts/gen-data.sh) reads it
from `tofu output` and OpenBao. Running the binary directly means assembling
that yourself:

```bash
cd gendata && make build
echo '{"BucketName":"...","Region":"...","AccessKey":"...","SecretKey":"..."}' \
  | ./gendata --target bucket --provider aws --inputs-file -
```

**stdin, not a file** — the JSON holds the database password and the
object-storage secret key, and a file would leave both on disk after the run.
`--inputs-file <path>` is still accepted for a hand-written file while debugging;
put no secrets in one.

---

## Prerequisites

1. **The runner container is up and the target is provisioned.**

   ```bash
   cd tofuenv
   ./scripts/up.sh
   ./scripts/provision.sh <aws|ncp> <bucket|vm|database>
   ```

   `../scripts/gen-data.sh` reads `tofu output` through the `tofuenv-runner`
   container, so a target with no state is reported rather than guessed at.

2. **`tofuenv/.env` has `VAULT_ADDR` and `VAULT_TOKEN`.** CSP access keys are *not*
   read from `.env` — they come from OpenBao at `secret/csp/aws` or `secret/csp/ncp`,
   because `up.sh` blanks them in `.env` after registering them.

3. **Go is installed** (to build the binary).

4. **NCP managed databases need their public domain issued first.** Until then the
   `*_host` outputs are empty, and gendata skips those engines with a warning
   pointing at `./scripts/ncp-db-domain.sh`. Self-hosted MariaDB is unaffected.

---

## Usage

```bash
./gendata --target all                            # bucket + filesystem + database (AWS)
./gendata --target all --provider ncp              # the same, on NCP
./gendata --target bucket                          # one target
./gendata --target database --engine mysql         # one engine
./gendata --target all --dry-run                   # generate locally, send nothing
GENDATA_DB_SIZE_MB=2048 ./gendata --target database  # fixture + 2 GB of rows
./gendata --target bucket --force                  # overwrite existing data
./gendata --target bucket --cleanup                # the reverse: empty the bucket
```

`../scripts/gen-data.sh` is a thin wrapper that builds the binary first and passes
every flag straight through, which is usually more convenient.

| Flag | Default | Values |
|---|---|---|
| `--target` | `all` | `bucket`, `filesystem`, `database`, `all` |
| `--provider` | `aws` | `aws`, `ncp` |
| `--engine` | `all` | `mysql`, `mariadb`, `postgresql`, `mongodb`, `all` |
| `--config` | `config/config.json` | Path to the config file |
| `--inputs-file` | — | **Required.** JSON with the connection info: a path, or `-` for stdin |
| `--dry-run` | `false` | Generate dummy files only; skip upload, SFTP and DB load |
| `--force` | `false` | Skip the pre-flight checks: existing data (allows overwrite and `DROP`) and capacity |
| `--cleanup` | `false` | Delete data instead of generating it — see below. `--target bucket` only |
| `--env-keys` | — | Print the environment variables gendata reads and exit; nothing else is required |

### `--cleanup` — emptying the bucket

`--cleanup` runs the whole thing backwards: no dummy files are generated, no pre-flight
runs (it exists to *find* data), no manifest is written, and every object in the bucket
is deleted. `--dry-run` alongside it reports the count without deleting anything.

It exists for one caller. `ncloud_objectstorage_bucket` has no `force_destroy` — the one
`tofu/aws/bucket` sets on `aws_s3_bucket` — so NCP answers `DeleteBucket` with **409
`BucketNotEmpty`** while a single object is left, and `../scripts/deprovision.sh ncp
bucket` cannot finish. It empties the bucket through gendata first, because gendata is
the only thing in tofuenv that speaks S3.

Two consequences of that job:

- **It empties the whole bucket, not just `basePrefix`.** What blocks the destroy is any
  object at all, including whatever a migration test wrote outside `gendata/`.
- **Objects go one delete call at a time.** Batching them into Multi-Object Delete would
  be faster, but NCP does not list that operation among the S3 APIs it supports.

`--target bucket` is required: naming any other target is an error rather than a no-op,
since `--target` defaults to `all` and a silent partial cleanup would be worse than a
refusal. AWS is not rejected — the same bucket may be reached with either CSP's
credentials — it simply never needs this, because `force_destroy` already covers it.

### Build targets

```bash
make build      # -> ./gendata
make vet
make run        # build, then run with default flags
make tidy
make clean
```

---

## How a run works

1. **Read the inputs** — `config.json` for behaviour, the `GENDATA_*` environment
   variables on top of it, and the connection info from `--inputs-file` (the
   wrapper pipes it in). Ports, `DBUser` and `DBName` left empty get gendata's
   defaults: `3306`/`5432`/`27017`, `dbadmin`, `testdb`.
2. **Pre-flight capacity check** — a size that would not fit on the provisioned
   volume or DB storage stops the run here. `--force` overrides it.
3. **Pre-flight existing-data check** — if the target already holds data, gendata
   stops. This matters because paths are fixed and reloading a fixture on top of an
   existing one fails or duplicates rows (`Collection.Drop` for MongoDB).
   `--force` overrides it.
4. **Run each target:**
   - `bucket` → generate, then upload to `s3://<bucket>/<basePrefix><leaf>/<type>/<file>`
   - `filesystem` → generate, then SFTP to `<basePath>/<leaf>/<type>/<file>`
   - `database` → load the `shop_db` fixture for each engine into the **provisioned**
     database (`tofu output db_name`, default `testdb`), then add the bulk rows if
     `GENDATA_DB_SIZE_MB` asks for any
5. **Write `runs/last-run.json`** — a summary of the last run, with no secrets, plus a
   console summary.

Destination paths carry **no per-run identifier**. Re-running therefore overwrites the
same locations instead of piling up copies, and step 3 notices the previous run.

### PostgreSQL: the tables land in a schema named after the database

On every other engine the database name from `.env` is the whole story: MySQL and
MariaDB have no separate schema layer and MongoDB has none either. PostgreSQL does, so
gendata creates **a schema with the same name as the database** — `testdb.products`,
not `public.products` — keeping one identifier from `.env` describing the fixture
container everywhere.

It is not `public` for a hard reason. On **NCP** the managed PostgreSQL master account
owns the database but has neither `USAGE` nor `CREATE` on schema `public`: that schema
belongs to `postgres` with the default `PUBLIC` grant revoked, and the account cannot
grant itself anything there. Even the pre-flight `SELECT to_regclass('public.products')`
fails with `42501 permission denied for schema public`. Owning the database is enough to
create a schema, so the fixtures get their own — and AWS, where the master account could
use `public`, follows the same layout so both CSPs stay comparable.

Two things make it work, both in `internal/database/db.go`:

- the connection string carries `options='-c search_path=<db_name>'`, so **every**
  connection the pool opens defaults to that schema — running `SET search_path` after
  connecting would only affect whichever connection served that statement;
- after creating the schema, gendata runs `ALTER ROLE CURRENT_USER IN DATABASE ... SET
  search_path`, so a later `psql` session lands there too instead of seeing an
  apparently empty database. A role may always set its own defaults, so this needs no
  superuser rights; if it fails, it is logged and the load continues.

The fixture SQL never qualifies a name, so nothing in `shop_db_pg.sql` had to change.

### MongoDB: the connection is pinned to one node

The MongoDB URI carries `directConnection=true`. Without it, NCP's managed MongoDB is
unreachable from outside even with a public domain issued.

The instance is created as `STAND_ALONE`, but it still identifies itself as a replica
set member. The driver therefore does what it normally should: it connects to the seed,
asks the server which hosts belong to the set, and switches to those — and the server
answers with its **private** domain, which only resolves inside the VPC:

```
server selection error: context deadline exceeded, current topology:
{ Type: ReplicaSetNoPrimary, Servers: [{ Addr: 49he6d.vpc.mg.naverncp.com:27017,
  Last error: dial tcp 10.10.1.9:27017: i/o timeout }] }
```

`directConnection=true` pins the driver to the address it was given and skips discovery
altogether, which is correct for a single-node target and harmless against any other
MongoDB reached through a hand-assembled `--inputs-file`.

---

## How much data — `.env`, then `config.json`

Sizes come from three places, each overriding the one before it:

```
config/config.json   <   GENDATA_* environment variables   <   command-line flags
   the defaults               what this deployment wants           what this run wants
```

In tofuenv the middle one is [`../.env`](../.env.example), under **gendata test data
size**. `gen-data.sh` sources that file with `set -a`, so gendata inherits the
variables and needs no plumbing of its own:

| Variable | Sets |
|---|---|
| `GENDATA_DUMMY_SIZE_MB` | every dummy format, in MB |
| `GENDATA_DUMMY_SIZES` | per format, applied on top: `csv=500,txt=500,sql=500,json=500,xml=500,png=100,gif=100,zip=0`. A format left out keeps the value above rather than being switched off; `0` switches it off |
| `GENDATA_DB_SIZE_MB` | bulk rows added to each database after the fixture, in MB |

They are **not** `TF_VAR_*`: OpenTofu never reads them. In tofuenv's `.env` that
prefix means "a variable of some tofu module", and borrowing it for a value that
never reaches tofu is a claim a reader has to test to disprove.

Direct runs get the same knobs, since they are ordinary environment variables:

```bash
GENDATA_DB_SIZE_MB=500 ./gendata --target database --inputs-file -
```

A variable that is set but unparseable fails the run rather than falling back to
the config.json value — `GENDATA_DB_SIZE_MB=1G` would otherwise generate nothing
and say nothing about why. A key gendata does not recognise is a different
problem: the environment cannot reject it, it is simply never read. `gen-data.sh`
catches that by comparing the `GENDATA_` keys in `.env` against `gendata
--env-keys`, and warns.

Every run logs the sizes in effect and where they came from, and
`runs/last-run.json` records the same under `origins`.

### Capacity

The sizes have to fit on what was provisioned, so `gen-data.sh` sends the limits
it knows along with the connection info and gendata refuses a request over **80%**
of one:

| Target | Limit | From |
|---|---|---|
| filesystem | VM root volume | `TF_VAR_aws_vm_volume_size` (20 GB); unknown on NCP, so the check is skipped |
| database | instance storage | AWS `TF_VAR_db_allocated_storage` (20 GB); NCP a fixed 10 GB |

This is not tidiness. A managed instance that fills its volume goes read-only or
into `STORAGE_FULL`, and on both CSPs the way back is deprovision and provision
again. `--force` skips the check along with the existing-data one.

---

## Configuration — `config/config.json`

```json
{
  "layout":        { "folderDepth": 2, "folderBreadth": 2 },
  "objectStorage": { "basePrefix": "gendata/", "concurrency": 10, "endpointOverride": "", "bucketLookup": "auto" },
  "filesystem":    { "basePath": "/home/ubuntu/testdata", "concurrency": 10 },
  "dummy":         { "sizeCSV": 1, "sizeTXT": 1, "sizeSQL": 1, "sizeJSON": 1, "sizeXML": 1, "sizePNG": 1, "sizeGIF": 1, "sizeZIP": 1 },
  "database":      { "sizeMB": 0, "batchSize": 1000, "idOffset": 1000000, "seed": 42,
                     "weights": { "order_items": 30, "orders": 20, "reviews": 20, "customers": 12, "inventory_log": 10, "products": 8 } }
}
```

**`dummy`** — how much to generate per format, **in MB**. A value of `N` produces `N`
files of about 1 MiB each, so roughly `N` MB in total; `"sizeCSV": 10` is about 10 MB
of CSV. All eight formats ship as `1`; set one to `0` to skip that format entirely.
Text formats (csv, json, xml, sql, txt) are filled to the exact byte target, while the
binary ones (png, gif, zip) are approximate.

**`layout`** — the destination folder tree, `folderDepth` levels deep and
`folderBreadth` wide. Folder names (`dir_n`) are deterministic and files are spread
round-robin across the leaves. Shared by the bucket and filesystem targets.

**`objectStorage`** — upload tuning. `endpointOverride` points at any S3-compatible
endpoint, such as a local MinIO. `bucketLookup` is `auto`, `dns` or `path`.

**`filesystem`** — default transfer path and concurrency. The default path is owned by
`ubuntu`, so no sudo is needed. If the vm module exports a `data_path` output, that
value wins — which is how NCP ends up at `/root/testdata`, since NCP images log in as
`root`.

**`database`** — the bulk phase. `sizeMB` is the only field expected to change
between runs, and `.env` carries it; the rest is tuning a deployment sets once, if
ever. `idOffset` is the primary key the generated rows start at, far above the
fixture's own ids so the two never collide and "fixture or bulk" stays answerable
from the id alone. `seed` makes a run reproducible — the same seed puts logically
identical rows into every engine, so a migration can be checked by comparing them.
`weights` splits `sizeMB` across the tables by share of bytes and is normalized by
its own sum, so switching one table off does not mean rebalancing the rest.

### The bulk phase

`sizeMB: 0`, the default, loads the fixture and stops — what gendata did before
this existed. Above 0, the megabyte budget is turned into row counts and written
**on top of** the fixture, into `customers`, `products`, `orders`, `order_items`,
`reviews` and `inventory_log`. Parents are generated before children and
referenced by id, so the rows are referentially valid without reading anything
back; `categories` is never generated and its ids are read from the fixture.

Three things about it are worth knowing:

- **It runs after the fixture, never instead of it.** The fixture carries the
  tables, views, procedures, triggers and the multibyte rows a migration is
  actually judged on. It also has to go in first: its seed inserts reference their
  parents by hard-coded id, and bulk rows inserted first would push the
  `AUTO_INCREMENT` counter past them.

- **The insert triggers are taken out of the way.**
  `trg_after_order_item_insert` decrements product stock and writes an
  `inventory_log` row per order item — correct for a shop, but against millions of
  generated rows it triples the write volume and drives stock deep into the
  negative, at which point `trg_before_product_update` starts rejecting rows.
  PostgreSQL disables them in place (`ALTER TABLE ... DISABLE TRIGGER USER`, which
  leaves the foreign keys checking, since those are system triggers). MySQL has no
  way to disable a trigger, so gendata backs each one up with
  `SHOW CREATE TRIGGER`, drops it, and recreates it afterwards under the `sql_mode`
  it was created with. A failure to recreate is logged as an `[ERROR]` with the
  statement to run by hand.

- **The size you ask for is not the size you get.** Row counts come from per-table
  byte estimates, and every engine adds its own overhead on top. gendata measures
  what actually landed — `information_schema.TABLES`, `pg_total_relation_size()`,
  `dbStats` — and reports it, `runs/last-run.json` included. That measured number,
  not the requested one, is what the next run has to fit alongside.

PostgreSQL is loaded with `COPY FROM STDIN` and MongoDB with unordered
`InsertMany`. MySQL and MariaDB get batched multi-row `INSERT`s rather than
`LOAD DATA LOCAL INFILE`, which would be faster but needs `local_infile=ON` on the
server — and both RDS and NCP ship it off, so the fast path would be refused on
every instance this environment provisions and the fallback would do all the work
anyway.

> Database TLS has no config knob: every engine negotiates **opportunistically**.
> mysql and mariadb use the driver's `TLSConfig=preferred`, postgres uses
> `sslmode=prefer`. TLS is attempted first, and a server without it still connects.

---

## What is inside

| Path | Role |
|---|---|
| `config/` | `config.json` parsing, the `GENDATA_*` environment overlay, plus the `Inputs` contract read from `--inputs-file` |
| `internal/generate/` | Dummy file generation in MB units, built on `gofakeit` |
| `internal/layout/` | Deterministic destination folder tree, shared by bucket and filesystem |
| `internal/bucket/` | S3 upload, listing and deletion through the MinIO client, with a per-CSP endpoint switch (the cb-spider `S3Manager` pattern) |
| `internal/filesystem/` | SFTP transfer to the VM |
| `internal/database/` | Fixture loading with native Go drivers, no CLI clients, plus the bulk phase (`bulk.go`, `bulkgen.go`) |

The `shop_db` fixtures are **embedded into the binary** with `go:embed` from
`internal/database/` (`shop_db_mysql.sql`, `shop_db_mariadb.sql`, `shop_db_pg.sql` and
`shop_db_mongo.json`), so gendata reads nothing from disk at runtime. SQL is executed
through engine-aware statement splitters; MongoDB is injected from Extended JSON.

The fixtures deliberately contain no `CREATE DATABASE` or `USE`, so the target database
must already exist — which it does, because tofu creates it. They carry no schema
qualifier either, which is what lets the PostgreSQL loader place them through
`search_path` (see above).
