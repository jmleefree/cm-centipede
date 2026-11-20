# cm-centipede OpenTofu-Based Migration Test Environment

Create and destroy **object storage buckets, databases and VMs** on **AWS**,
**NCP (Naver Cloud Platform)**, **Alibaba Cloud** and **Azure** using OpenTofu, with
credentials held in OpenBao.

These resources exist to give cm-centipede something real to migrate. Each resource
type is prepared and destroyed **independently** — you can create just a bucket,
just a VM, or just the databases.

---

## Support matrix

| CSP | vm<br>(for filesystem testing) | objectStorage | mysql | mariadb | postgresql | mongodb |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| aws | ✅ Ubuntu / Windows<br>(+ NFS via EFS, optional)<br>(+ servers on the VM, optional) | ✅ | ✅ | ✅ | ✅ | — |
| ncp | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| alibaba | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| azure | ✅ | ✅ | ✅ | — | ✅ | ✅ |

Every database in the table is a managed service. Each CSP is left with the engines it offers:
AWS has no managed MongoDB, and NCP and Azure have no managed MariaDB, so those three cells
are empty. Alibaba offers all four (RDS for MySQL / MariaDB / PostgreSQL, ApsaraDB for MongoDB).
Azure Database for MariaDB was retired on 2025-09-19, so Azure has MySQL and PostgreSQL
Flexible Server and Azure DocumentDB (Cosmos DB for MongoDB vCore).

The AWS VM has three options of its own, all part of the `vm` resource rather than
resources of their own — see [Step 3](#step-3--prepare-resources):

- **Windows** (`TF_VAR_aws_vm_os=windows`, Windows Server 2022) instead of Ubuntu 22.04
- an **EFS file system** mounted over NFS (Ubuntu only)
- **servers installed on the VM itself** — MinIO, MySQL, MariaDB, PostgreSQL, MongoDB,
  natively, on either OS, reachable from outside. These are not managed services, so
  AWS gets a MongoDB and an S3-compatible object storage this way.

---

## Quick start (AWS)

```bash
cd tofuenv
cp .env.example .env && chmod 600 .env    # then change every ChangeMe: AWS keys, a DB password, a bucket name
./scripts/up.sh               # start OpenBao, store credentials, start the tofu runner
./scripts/prepare.sh aws bucket
./scripts/conn-info.sh aws bucket
./scripts/gen-data.sh --provider aws --target bucket
./scripts/teardown.sh aws bucket       # always clean up - these resources cost money
./scripts/down.sh
```

NCP needs three extra things. See [Step 4](#step-4--ncp-only-issue-the-public-domain)
and the [CSPs at a glance](#csps-at-a-glance) table. Alibaba works like AWS from the
command line (`./scripts/prepare.sh alibaba bucket`), with a network module created for
it automatically as on NCP. Azure works like AWS too (`./scripts/prepare.sh azure vm`);
its bucket needs a storage account you create first — see [Step 0](#step-0--prerequisites).

---

## How it fits together

```
 Step 0  Prerequisites     Docker + CSP access keys
            |
 Step 1  .env              cp .env.example .env && chmod 600 .env  ->  change every ChangeMe
            |
 Step 2  Start             ./scripts/up.sh
            |                └ start OpenBao -> store credentials -> blank .env keys -> start runner
            |
 Step 3  Prepare           ./scripts/prepare.sh aws bucket        (or vm / database)
            |                └ prints connection info when it finishes
            |                └ for NCP and Alibaba, the network module is created first (automatically)
            |
 Step 4  Public domain     NCP managed databases only: request it once in the console,
            |              then ./scripts/ncp-db-domain.sh
            |
 Step 5  Test data         ./scripts/gen-data.sh --target all      (optional)
            |
 Step 6  Connect           ./scripts/conn-info.sh                  (every environment; --prefix for one)
            |
 Step 7  Destroy           ./scripts/teardown.sh aws bucket
            |                └ for NCP and Alibaba, the network module is removed once nothing needs it
            |                └ ./scripts/list.sh shows what is still prepared, under every prefix
            |
 Step 8  Shut down         ./scripts/down.sh
```

Credentials never reach a tofu module as an environment variable: `up.sh` writes them
into OpenBao, blanks them in `.env`, and each module reads them at apply time through
the `vault` provider.

---

## CSPs at a glance

| | AWS | NCP | Alibaba | Azure |
|---|---|---|---|---|
| Bucket | S3 | Object Storage | OSS | Blob container, **in a storage account you create first** |
| VM OS | Ubuntu 22.04, or Windows Server 2022 | Ubuntu 22.04 (`TF_VAR_ncp_server_image_name`) | Ubuntu 22.04 (`TF_VAR_alibaba_image_name_regex`) | Ubuntu 22.04 gen2 (`TF_VAR_azure_image_sku`) |
| VM login account | `ubuntu` (`Administrator` on Windows) | **`root`** | **`root`** | **`azureuser`** (root is not allowed) |
| Servers installed on the VM | optional: MinIO, MySQL, MariaDB, PostgreSQL, MongoDB | — | — | — |
| MySQL / PostgreSQL | RDS | Managed Cloud DB | ApsaraDB RDS | Flexible Server |
| MongoDB | **not prepared** as a managed DB (can run on the VM) | Managed Cloud DB (STAND_ALONE) | ApsaraDB for MongoDB (replica set, account **`root`**) | Azure DocumentDB / Cosmos DB for MongoDB vCore (`mongodb+srv://`, TLS) |
| MariaDB | RDS | **not prepared** | ApsaraDB RDS | **not prepared** (service retired) |
| Network | default VPC, nothing to do | **a VPC is required — created and destroyed automatically** | **a VPC is required — created and destroyed automatically** | the vm module builds its own VNet; no network module |
| Resource group | — | — | — | one per module (`<prefix>-vm-rg`, `<prefix>-database-rg`), deleted by teardown |
| Reaching a DB from outside | works immediately | **a public domain must be requested once, in the console** | works immediately (public endpoints are created by the module) | works immediately (public access + firewall rule) |
| DB engine version format | major.minor (`8.0`) | **full version (`8.0.36`)** | major.minor (`8.0`, `14.0`) | MySQL `8.0.21` / `8.4`, PostgreSQL major (`14`), MongoDB `7.0` |
| Managed DB preparation time | a few minutes | **about 30 minutes** | RDS: a few minutes to ~20; MongoDB: 5-10 minutes | not measured yet |

---

## Step 0 — Prerequisites

**Tools**

```bash
docker --version            # Docker Desktop, or Docker on Linux
docker compose version
jq --version                # credential registration and Step 5
curl --version
go version                  # only needed for Step 5 (test data)
```

**Credentials** — you only need keys for the CSP you actually use.

| CSP | Keys | Where to get them |
|---|---|---|
| AWS | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | IAM user with S3, RDS and EC2 permissions (plus EFS for the VM's optional NFS) |
| NCP | `NCP_ACCESS_KEY`, `NCP_SECRET_KEY` | Portal > My Page > Manage Authentication Key |
| Alibaba | `ALIBABA_ACCESS_KEY_ID`, `ALIBABA_ACCESS_KEY_SECRET` | RAM user AccessKey with OSS, ECS, VPC, RDS and MongoDB permissions |
| Azure | `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | A service principal: `az ad sp create-for-rbac --role Contributor --scopes /subscriptions/<id>` |
| Azure (bucket) | `AZURE_S3_ACCESS_KEY`, `AZURE_S3_SECRET_KEY` | An **existing** storage account's name and one of its keys (portal: Storage account > Security + networking > Access keys) |

NCP Object Storage and Alibaba OSS use the same key pair as the rest of their CSP —
there is no separate S3 credential.

**Azure is different on both counts.** Blob Storage has no S3 API, and gendata reaches it
with the storage account's own name and key — `S3AccessKey` / `S3SecretKey` in cb-tumblebug
and cb-spider. So the storage account is **not created by tofuenv**: create a StorageV2
account in the portal first, and `tofu/azure/bucket` creates only the container in it. The
service principal also has to register the resource providers each module uses
(`Microsoft.Storage`, `.Compute`, `.Network`, `.DBforMySQL`, `.DBforPostgreSQL`,
`.DocumentDB`) — azurerm 5.x no longer does it unasked; Contributor is allowed to.

---

## Step 1 — Create `.env`

`.env` holds your keys and settings. It is covered by `.gitignore`; never commit or
share it.

```bash
cd tofuenv
cp .env.example .env && chmod 600 .env
```

**Mode `600` is required, not advised.** `up.sh` and `register-creds.sh` refuse
to read a `.env` that anyone else can. `VAULT_TOKEN` is the OpenBao **root**
token and it stays in the file permanently — anything that can read it can read
every credential you stored — and your CSP keys sit there in plaintext until
Step 2 registers them.

Then open `.env` and change every `ChangeMe` - empty the `[CREDENTIAL]` keys of a CSP you
do not use. The template documents every key; the
minimum for AWS is:

```dotenv
# Credentials - blanked automatically once stored in OpenBao (Step 2)
AWS_ACCESS_KEY_ID=your_access_key_id
AWS_SECRET_ACCESS_KEY=your_secret_access_key
AWS_DB_PASSWORD=a_strong_db_password
TF_VAR_aws_vm_server_password=        # empty unless you install servers on the VM (Step 3)

# Settings - kept as is
TF_VAR_aws_region=ap-northeast-2
TF_VAR_aws_name_prefix=cptf                             # short for "centipede tofu"
TF_VAR_aws_bucket_name=cptf-aws-bucket-yourname-20260804   # must be globally unique
TF_VAR_aws_db_name=testdb
TF_VAR_aws_db_username=dbadmin
```

For NCP, add:

```dotenv
# Credentials - blanked automatically once stored in OpenBao (Step 2)
NCP_ACCESS_KEY=your_access_key
NCP_SECRET_KEY=your_secret_key
NCP_DB_PASSWORD=Cent1pede!2024        # strict rules, see below

# Settings - kept as is
TF_VAR_ncp_region=KR
TF_VAR_ncp_zone=KR-2
TF_VAR_ncp_name_prefix=cptf           # short for "centipede tofu"
TF_VAR_ncp_bucket_name=cptf-ncp-bucket-yourname-20260804
TF_VAR_ncp_db_name=testdb
TF_VAR_ncp_db_username=dbadmin
TF_VAR_ncp_mysql_version=8.0.36       # full version string, not 8.0
TF_VAR_ncp_postgres_version=14.22
TF_VAR_ncp_mongodb_version=7.0.28
```

For Alibaba, add:

```dotenv
# Credentials - blanked automatically once stored in OpenBao (Step 2)
ALIBABA_ACCESS_KEY_ID=your_access_key_id
ALIBABA_ACCESS_KEY_SECRET=your_access_key_secret
ALIBABA_DB_PASSWORD=Cent1pede_2024    # shared by RDS and MongoDB, see below

# Settings - kept as is
TF_VAR_alibaba_region=ap-northeast-2
TF_VAR_alibaba_zone=ap-northeast-2a   # must sell ECS, RDS and MongoDB
TF_VAR_alibaba_name_prefix=cptf       # short for "centipede tofu"
TF_VAR_alibaba_bucket_name=cptf-alibaba-bucket-yourname-20260804   # globally unique
TF_VAR_alibaba_db_name=testdb
TF_VAR_alibaba_db_username=dbadmin    # RDS only; MongoDB is always root
```

The instance types, RDS classes and engine versions in `.env.example` are starting
values; check what the zone actually sells with `./scripts/alibaba-db-versions.sh`
once Step 2 is done.

For Azure, add:

```dotenv
# Credentials - blanked automatically once stored in OpenBao (Step 2)
AZURE_CLIENT_ID=your_client_id            # the service principal (appId)
AZURE_CLIENT_SECRET=your_client_secret
AZURE_TENANT_ID=your_tenant_id
AZURE_SUBSCRIPTION_ID=your_subscription_id
AZURE_S3_ACCESS_KEY=yourstorageaccount    # the existing storage account's NAME
AZURE_S3_SECRET_KEY=its_access_key        # one of its keys (base64)
AZURE_DB_PASSWORD=Cent1pede_2024          # shared by MySQL, PostgreSQL and MongoDB

# Settings - kept as is
TF_VAR_azure_region=koreacentral          # what Azure calls the location
TF_VAR_azure_name_prefix=cptf             # short for "centipede tofu"
TF_VAR_azure_bucket_name=cptf-azure-container-yourname   # container in that account
TF_VAR_azure_db_name=testdb
TF_VAR_azure_db_username=dbadmin
```

**The six Azure credential keys are registered together**, as one OpenBao secret
(`secret/csp/azure`): fill in all six or none. `up.sh` refuses a partial set, which would
otherwise blank the keys already stored. Check what the region sells with
`./scripts/azure-db-versions.sh` once Step 2 is done.

**The name prefix** is short for **centipede tofu** and names every resource this
environment creates (`cptf-vm`, `cptf-mysql`, `cptf-rds-sg`, `cptf-vpc`, ...), so they
are easy to tell apart from anything else in the account. Each CSP has its own key, and
they may hold different values:

| Key | Length limit | Why |
|---|---|---|
| `TF_VAR_aws_name_prefix` | 2-20 | An RDS identifier is capped at 63 and gets a `-postgres` suffix here |
| `TF_VAR_ncp_name_prefix` | 2-10 | The managed MongoDB `service_name` is capped at 15, and `cptf-mongodb` is already 12 |
| `TF_VAR_alibaba_name_prefix` | 2-20 | Kept the same as AWS; Alibaba's own name limits are far longer |
| `TF_VAR_azure_name_prefix` | 2-12 | Names the resource groups and the DB servers, which also take a 6-character random suffix (`cptf-postgres-ab12cd`) |

Lowercase letters, digits and hyphens, starting with a letter; a violation is rejected at
plan time. **Buckets are not covered by the prefix** — an S3 name has to be globally
unique, so `TF_VAR_aws_bucket_name`, `TF_VAR_ncp_bucket_name`,
`TF_VAR_alibaba_bucket_name` and `TF_VAR_azure_bucket_name` are set in full.

Keep some room below those limits: NCP login keys append a role and a random suffix on
top of the prefix (`cptf-vm-a1b2c3`), and the longest generated name is the prefix plus
11 characters (`-postgresql`, `-server-acg`).

**The prefix is also the environment.** Every module keeps one tofu state per prefix,
and every script acts on the prefix `.env` sets and no other. Changing it starts a
**new environment next to the old one**; the old one is left as it is — and keeps
costing money. See [Multiple environments](#multiple-environments-one-per-prefix).

Five things reliably go wrong here:

**Bucket names must be unique.** An S3 bucket name is globally unique across all AWS
accounts, so common names are already taken and the apply fails with
`BucketAlreadyExists`. Append a date or your own identifier. Lowercase letters, digits
and hyphens only, 3-63 characters. NCP bucket names must be unique within the region.
Alibaba OSS names are globally unique across all Alibaba Cloud accounts, like S3.
An Azure container name only has to be unique within its storage account, but each
environment still needs its own, as on the other CSPs (lowercase, digits and hyphens,
no `--`).

**Use `dbadmin`, not `admin`, as the DB username.** PostgreSQL reserves `admin` and
`rdsadmin`, so an apply using them fails. `dbadmin` is safe on all engines and is the
default.

**The NCP DB password rules are enforced.** A violation is rejected by `up.sh` before
anything is prepared:

- 8 to 20 characters
- at least one letter, one digit and one special character
- allowed special characters: `~ ! @ # $ % ^ * ( ) - _ = [ ] { } ; : , . < > ?`
- forbidden: `` ` `` `&` `+` `\` `"` `'` `/` and whitespace
- example: `Cent1pede!2024`

**The Alibaba DB password rules are enforced too.** RDS and MongoDB share
`ALIBABA_DB_PASSWORD` and apply the same rule; `up.sh` rejects a violation:

- 8 to 32 characters
- at least three of: uppercase, lowercase, digits, special characters
- allowed special characters: `! $ ^ & * ( ) _ + - =`
- forbidden: `@ # %` — Alibaba accepts them, but they break the MongoDB URI gendata
  builds — and anything not listed above
- quote it in single quotes in `.env` when it has a special character
- example: `Cent1pede_2024`

**The Azure DB password rules are enforced the same way.** MySQL, PostgreSQL and
MongoDB share `AZURE_DB_PASSWORD`:

- 8 to 128 characters
- at least three of: uppercase, lowercase, digits, special characters
- allowed special characters: `! $ ^ & * ( ) _ + - =`
- it must not contain `TF_VAR_azure_db_username` (Azure refuses that), in any case
- example: `Cent1pede_2024`

Azure also refuses some admin names — `admin`, `administrator`, `root`, `azure_superuser`,
`guest`, `public` and `pg_*`; the module rejects them at plan time.

**An AWS engine version the region does not offer fails the apply.** RDS is looser than
NCP about the format — it accepts both a prefix (`8.0`) and a full version (`8.0.42`),
and resolves a prefix to the current minor release, which the provider tracks separately
in `engine_version_actual`, so a prefix causes no replacement. The value still has to
exist in the region; list what it offers with `./scripts/aws-db-versions.sh` once Step 2
is done.

**TLS is enforced by some engine versions, not by others.** RDS MariaDB sets
`require_secure_transport=ON` from 11.8, and RDS PostgreSQL sets `rds.force_ssl=1`
from 15; MySQL never does by default. With the default versions (`8.0` / `10.6` /
`14`) a plaintext client connects to all three. Raise one of those versions and it
stops: set `TF_VAR_aws_secure_transport=off` to attach a parameter group that allows
plaintext, or connect with TLS instead.

The value is **fixed at creation time** — the parameter group is attached as the
instance boots, so no reboot is ever needed. Changing it afterwards means
`teardown.sh aws database` followed by `prepare.sh aws database`; a plain
`--force` re-apply would attach the group to a running instance and leave PostgreSQL
waiting for a reboot that never comes.

**NCP engine versions must be full version strings** — `8.0.36`, not `8.0`. The
provider normalises state to the full version it gets back from the API, and the field
forces replacement, so a partial version makes **every** subsequent plan want to
re-create the database (about 30 minutes each time). A wrong value is caught at plan
time, not after the apply. List the supported versions with
`./scripts/ncp-db-versions.sh` once Step 2 is done.

**An Alibaba RDS class is sold only for one combination** of engine version, edition
(`TF_VAR_alibaba_{mysql,mariadb,postgres}_category`: `Basic` or `HighAvailability`),
storage type and zone.
The database module checks the class against that combination at plan time, so a
mismatch stops before anything is created. `./scripts/alibaba-db-versions.sh` lists
the classes that fit the values `.env` sets, and the zones that sell every service.
MongoDB versions and classes are not in the provider's catalog, so
`./scripts/alibaba-db-versions.sh mongodb` asks the Alibaba Cloud API for them through
the `aliyun` CLI in the runner; they are sold per version, node count
(`TF_VAR_alibaba_mongodb_replication_factor`), storage type and zone.

**Azure SKUs come as `<tier>_<size>`** — `B_Standard_B1ms` is the Burstable edition's
smallest size — and `./scripts/azure-db-versions.sh` lists the ones the subscription can
use in the region, along with the VM sizes. Azure publishes no list of the MongoDB
(DocumentDB) versions or tiers it sells, so for those the script shows what azurerm
accepts — anything else is refused at plan time — and the clusters already in the
subscription. A tier at `M30` or above cannot be scaled back down to the burstable
`M10` / `M20` / `M25`.

Leave `VAULT_TOKEN` empty — Step 2 fills it in.

---

## Step 2 — Start the stack

```bash
./scripts/up.sh
```

This does four things:

1. Starts the **OpenBao** container (the credential vault).
2. **Initialises** it on first run, **unseals** it on later runs.
3. **Stores** the `.env` credentials in OpenBao, then **blanks those keys in `.env`**
   so no plaintext key stays on disk.
4. Starts the **tofu-runner** container, which every script drives via `docker exec`.

On success:

```
=== Ready ===
  Prepare    :  ./scripts/prepare.sh <csp> <resource>
```

| Flag | Effect |
|---|---|
| *(none)* | Register credentials, then blank them in `.env` |
| `--keep-env` | Register credentials but leave the `.env` values in place |
| `--no-register` | Skip credential registration entirely |

Credentials already in OpenBao are **not** overwritten by blank `.env` values, so
re-running `up.sh` is safe.

---

## Step 3 — Prepare resources

```
./scripts/prepare.sh <csp> <resource> [--engine e1,e2] [--force]
```

| CSP | Valid resources |
|---|---|
| `aws` | `bucket`, `vm`, `database` |
| `ncp` | `bucket`, `vm`, `database` |
| `alibaba` | `bucket`, `vm`, `database` |
| `azure` | `bucket`, `vm`, `database` |

**Running the same command twice is safe.** A resource that already holds tofu state is
reported and skipped, so nothing is created and nothing is charged:

```
=== aws/bucket (prefix cptf) is already prepared - nothing to do ===
  bucket_name = "cptf-aws-bucket-test"
  ...
  Connection info  :  ./scripts/conn-info.sh aws bucket --prefix cptf
  Re-apply anyway  :  ./scripts/prepare.sh aws bucket --force
  Destroy          :  ./scripts/teardown.sh aws bucket
```

Use `--force` to apply anyway. That is what you want when a previous apply stopped
halfway (state exists but some resources are missing) or when a `.env` value changed —
on NCP, remember that changing a managed DB variable re-creates the database.
`TF_VAR_aws_secure_transport` is the one AWS value `--force` cannot apply properly —
see [Step 1](#step-1--create-env).

**One database engine at a time** — `--engine` (database only) prepares just the
engines named, comma-separated, using the same names as `gen-data.sh --engine`:

| CSP | Engines |
|---|---|
| `aws` | `mysql`, `mariadb`, `postgresql` |
| `ncp` | `mysql`, `postgresql`, `mongodb` |
| `alibaba` | `mysql`, `mariadb`, `postgresql`, `mongodb` |
| `azure` | `mysql`, `postgresql`, `mongodb` |

```bash
./scripts/prepare.sh aws database --engine postgresql          # PostgreSQL only
./scripts/prepare.sh aws database --engine mysql               # adds MySQL; PostgreSQL stays
./scripts/prepare.sh ncp database --engine mysql,mongodb
```

- Engines already running are always kept: `--engine` only ever adds.
- Without `--engine`, a fresh database module gets every engine, as before.
- The skip check is per engine: the run is a no-op only when every engine named is
  already there.
- `--force` without `--engine` re-applies the engines the prefix already runs, so one
  you removed with `teardown.sh --engine` does not come back.
- The engine list is worked out by the script and handed to tofu as
  `TF_VAR_<csp>_db_engines`. It is not a `.env` setting.

**AWS**

```bash
./scripts/aws-db-versions.sh           # optional: list engine versions, instance classes, AMI
./scripts/prepare.sh aws bucket
./scripts/prepare.sh aws vm            # Ubuntu 22.04 (or Windows), for filesystem migration tests
./scripts/prepare.sh aws database      # RDS: MySQL + MariaDB + PostgreSQL (or --engine)
```

**AWS vm on Windows** — set `TF_VAR_aws_vm_os=windows` and the VM runs Windows Server
2022 instead of Ubuntu 22.04:

```dotenv
TF_VAR_aws_vm_os=windows
TF_VAR_aws_instance_type=t3.large    # Windows barely runs in a t3.micro's 1 GB
TF_VAR_aws_vm_volume_size=60         # 30 at least: the AMI's own size
```

- **SSH** works as on Ubuntu, with the generated key, but the account is `Administrator`.
  OpenSSH Server is installed on first boot, so the first connection can take a few
  minutes more. `ssh_command` has it ready.
- **RDP** logs in as `Administrator` with the password EC2 generates; tofu decrypts it
  with the same key. `./scripts/conn-info.sh aws vm --reveal` prints it as
  `admin_password`, next to `rdp_address`. Port 3389 is opened to `TF_VAR_allowed_cidr`.
- **Test data** goes to `C:/testdata` (`data_path`), which the init script creates;
  `TF_VAR_aws_data_path` moves it. It is not under the Administrator profile, which a
  folder made before the first logon would split into `Administrator.<host>`.
- Not supported on Windows: **NFS** (EFS has no Windows client; the plan refuses the
  combination) and **rsync**. centipede moves files to and from a Windows host over
  SFTP instead, listing the tree with PowerShell, so a Windows VM can be either end of
  a filesystem migration. gendata's SFTP works too.
- **Fixed at creation time.** Changing `TF_VAR_aws_vm_os` takes
  `prepare.sh aws vm --force`, which **re-creates the VM**.

**AWS vm with servers on it** — list them in `TF_VAR_aws_vm_servers` and they are
installed **natively on the VM (no Docker)**, on Ubuntu or Windows, each listening on all
interfaces with one shared account:

```dotenv
TF_VAR_aws_vm_servers='["minio","mysql","mariadb","postgresql","mongodb"]'
TF_VAR_aws_vm_server_username=dbadmin
TF_VAR_aws_vm_server_password=Cent1pede!2024   # required once a server is listed; moved into OpenBao by up.sh
TF_VAR_aws_instance_type=t3.large              # five servers need memory
TF_VAR_aws_vm_volume_size=50
TF_VAR_allowed_cidr=203.0.113.7/32             # your own IP - see the warning below
```

| Server | Port | Ubuntu 22.04 | Windows Server 2022 | Account |
|---|---|---|---|---|
| minio | 9000, console 9001 | GitHub release binary, systemd `cptf-minio` | GitHub release `.exe`, WinSW service `cptf-minio` | root user; bucket `TF_VAR_aws_vm_minio_bucket` created |
| mysql | 3306 | official tarball in `/opt/mysql`, `cptf-mysql` | official ZIP in `C:\cptf\mysql`, `cptf-mysql` | `'<user>'@'%'`, all privileges |
| mariadb | **3307** | official tarball in `/opt/mariadb`, `cptf-mariadb` | official ZIP in `C:\cptf\mariadb`, `cptf-mariadb` | `'<user>'@'%'`, all privileges |
| postgresql | 5432 | PGDG apt, `postgresql` | EDB binaries ZIP in `C:\cptf\postgresql`, `cptf-postgresql` | SUPERUSER role |
| mongodb | 27017 | mongodb-org apt, `mongod` | MSI + mongosh + Database Tools, `MongoDB` | `root` in the admin database |

- `TF_VAR_aws_vm_db_name` (`testdb`) is created on mysql, mariadb and postgresql; mongodb
  creates it on first write. mariadb moves to 3307 so it can run next to mysql — each has
  its own directories, socket and option file.
- **The install runs over SSH once the VM is up**, and `prepare.sh` waits for it: when it
  returns, the servers are ready, and when the install fails, so does the apply. Five
  servers take about 10 minutes on Ubuntu and 15–25 on Windows.
- **Changing the list, a version or the account later** — `prepare.sh aws vm --force`
  runs the install again **on the same VM**; it is not re-created. What is installed is
  kept and every account is reset. A server taken off the list loses its ports and
  outputs but stays installed. On mongodb, a changed password cannot be applied once
  authorization is on (the script logs in with the new one); re-create the VM for that.
- **CLI tools are on PATH** for the login account, SSH and RDP alike: `mysql` and
  `mysqldump` are MySQL's; MariaDB's are `mariadb`, `mariadb-dump`, ... (its own
  `mysql*` copies are left off PATH, or behind MySQL's on Windows); plus `psql`/`pg_dump`,
  `mongosh`/`mongodump` and `minio`. Connect over TCP with the port —
  `mariadb -h 127.0.0.1 -P 3307 -u dbadmin -p` — since the sockets are not in the
  clients' default places. `mc` is not installed.
- **Versions** are `.env` settings — `TF_VAR_aws_vm_{mysql,mariadb,postgres,mongodb}_version`
  and `TF_VAR_aws_vm_minio_release`; `.env.example` lists the defaults. On Ubuntu,
  postgresql and mongodb come from apt, so they get the latest minor of the configured
  series; everything else is exactly the version given.
- **MinIO** comes from its GitHub releases, checked against a pinned SHA-256: dl.min.io no
  longer serves the community builds and the open-source project is archived.
  `RELEASE.2025-09-07T16-13-09Z` is the last release that ships binaries; the later
  security release (`2025-10-15`) is source-only, so its fix is not in it, and no more
  will come.
- ⚠ **Every server port is open to `TF_VAR_allowed_cidr`, which is `0.0.0.0/0` unless you
  narrow it** — the whole internet, guarded by one password. Set it to your own IP. It
  must still include the address this machine reaches AWS from, since the install runs
  over SSH from here.
- `TF_VAR_aws_vm_server_password` is a `[CREDENTIAL]` key: `ChangeMe` is refused, and
  `up.sh` (or `./scripts/register-creds.sh`) checks it against the rules above, stores it
  in OpenBao at `secret/vm/aws` and blanks it in `.env`. The vm module reads it from there.
  To change it, put the new one in `.env`, run `./scripts/register-creds.sh`, then
  `prepare.sh aws vm --force`. Like every password here, it also ends up in the tofu
  state.

Fill them with test data with `./scripts/gen-data.sh --source vm` — see
[Step 5](#step-5--load-test-data-optional).

**AWS vm with NFS (EFS)** — set `TF_VAR_aws_nfs_enabled=true` before `prepare.sh aws vm`
and the VM comes with an EFS file system, mounted over NFS (v4.1) on first boot:

```dotenv
TF_VAR_aws_nfs_enabled=true
#TF_VAR_aws_nfs_mount_path=/home/ubuntu/testdata    # where EFS is mounted
#TF_VAR_aws_data_path=/home/ubuntu/testdata         # where gendata writes (Step 5)
```

The two paths are **independent**; they just share a default. Left alone, the test
data lands on the NFS mount, so a filesystem migration reads from NFS. Point either one
elsewhere and the data stays on the local disk while EFS is mounted on its own.

- The mount path must not be `/`, `/home`, `/home/ubuntu` or a system directory —
  mounting over the home directory hides `.ssh/authorized_keys` and locks SSH out.
  A violation is rejected at plan time.
- EFS is reachable from inside the VPC only. A mount target goes into every default
  subnet, and its security group accepts NFS (2049) from the VM alone.
- The mount happens in cloud-init, **after** `prepare.sh` returns — give it a couple of
  minutes before Step 5. Check it with `ssh ... cloud-init status --wait` and
  `ssh ... mountpoint <mount path>`.
- **Fixed at creation time.** Changing either `aws_nfs_*` value on a prepared VM
  takes `prepare.sh aws vm --force`, which **re-creates the VM** — anything on its local
  disk is lost. EFS and everything on it are destroyed with `teardown.sh aws vm`.

**NCP** — the same three resources, in any order:

```bash
./scripts/ncp-db-versions.sh           # optional: list engine versions, images and specs
./scripts/prepare.sh ncp bucket
./scripts/prepare.sh ncp vm
./scripts/prepare.sh ncp database      # managed: MySQL + PostgreSQL + MongoDB (or --engine)
```

**Sizing on NCP** — all set in `.env`, and all fixed at creation (changing one on a
prepared resource re-creates it):

| What | Variable | Default |
|---|---|---|
| VM spec | `TF_VAR_ncp_server_spec_code` | `s2-g3` — list with `./scripts/ncp-db-versions.sh server` |
| VM boot disk (GB) | `TF_VAR_ncp_vm_volume_size` | `50` (NCP's own default is 10). The VM's only disk, so the filesystem test data lands on it; the init script grows the root filesystem to fill it |
| DB spec, per engine | `TF_VAR_ncp_{mysql,postgres,mongodb}_product_code` | empty = NCP's default spec — list with `./scripts/ncp-db-versions.sh <engine>`, which shows the specs of the version `.env` sets, grouped by image |
| DB image, per engine | `TF_VAR_ncp_{mysql,postgres,mongodb}_image_product_code` | empty = NCP's choice. Set it with the spec: the `[image ...]` code the spec is listed under, since a spec only works with its own image. The plan refuses an image that is not one of the version's |

The managed DBs have no storage size setting; the provider exposes none. Cloud DB
storage grows by itself as data is written, so `gen-data.sh` does not cap the bulk size
on NCP.

NCP has no default VPC, so `vm` and `database` resolve a VPC, PUBLIC subnet and ACG
**by name** from the `network` module. You never prepare that module yourself:
whichever of the two you run first creates it, and Step 7 removes it once nothing
needs it any more. Each prefix gets a network of its own.

**Alibaba** — the same three resources, in any order:

```bash
./scripts/alibaba-db-versions.sh zones    # optional: zones selling ECS, RDS and MongoDB
./scripts/alibaba-db-versions.sh          # optional: RDS versions and classes, ECS types, images
./scripts/prepare.sh alibaba bucket
./scripts/prepare.sh alibaba vm
./scripts/prepare.sh alibaba database     # RDS MySQL + MariaDB + PostgreSQL, MongoDB (or --engine)
```

**Sizing on Alibaba** — all set in `.env`:

| What | Variable | Default |
|---|---|---|
| VM type | `TF_VAR_alibaba_instance_type` | `ecs.t6-c1m2.large` — list with `./scripts/alibaba-db-versions.sh server` |
| VM system disk (GB) | `TF_VAR_alibaba_vm_volume_size` | `40` (20-500). The VM's only disk; fixed at creation |
| VM public bandwidth (Mbps) | `TF_VAR_alibaba_vm_bandwidth_out` | `10`, billed by traffic. Caps traffic out of the VM |
| RDS edition, per engine | `TF_VAR_alibaba_{mysql,mariadb,postgres}_category` | `Basic`, `HighAvailability` (MariaDB is sold as HighAvailability only), `Basic` |
| RDS class, per engine | `TF_VAR_alibaba_{mysql,mariadb,postgres}_instance_class` | checked at plan time — list with `./scripts/alibaba-db-versions.sh <engine>` |
| RDS storage (GB) | `TF_VAR_alibaba_db_allocated_storage` | `20`, each RDS engine |
| MongoDB class / storage | `TF_VAR_alibaba_mongodb_instance_class`, `_storage`, `_storage_type` | `mdb.shard.4x.large.d` (2 vCPU / 8 GB), `20`, `cloud_essd1` — list with `./scripts/alibaba-db-versions.sh mongodb` |
| MongoDB nodes | `TF_VAR_alibaba_mongodb_replication_factor` | `3` (1, 3, 5 or 7) |

As on NCP, `vm` and `database` resolve a VPC, vSwitch and security group **by name**
from the `alibaba/network` module, which is created and removed automatically. There
is no Step 4 for Alibaba: the RDS and MongoDB public endpoints are created by the
database module, and access is limited by each instance's IP whitelist
(`TF_VAR_allowed_cidr`). The MongoDB host is the replica set Primary's public address,
and its account is always `root` — `gen-data.sh` passes it to gendata on its own.

**Azure** — the same three resources, in any order:

```bash
./scripts/azure-db-versions.sh            # optional: DB versions and SKUs, VM sizes, images
./scripts/prepare.sh azure bucket         # the container, in the existing storage account
./scripts/prepare.sh azure vm
./scripts/prepare.sh azure database       # MySQL + PostgreSQL Flexible Server, MongoDB vCore (or --engine)
```

**Sizing on Azure** — all set in `.env`:

| What | Variable | `.env.example` value |
|---|---|---|
| VM size | `TF_VAR_azure_vm_size` | `Standard_B2s` (2 vCPU / 4 GB) — list with `./scripts/azure-db-versions.sh server` |
| VM OS disk (GB) | `TF_VAR_azure_vm_volume_size`, `_disk_type` | `30` (30 or more), `StandardSSD_LRS`. The VM's only disk; fixed at creation |
| VM image | `TF_VAR_azure_image_offer`, `_sku` | Canonical `0001-com-ubuntu-server-jammy` / `22_04-lts-gen2` (needs a size with Hyper-V gen V2) |
| MySQL | `TF_VAR_azure_mysql_sku`, `_storage_gb` | `B_Standard_B1ms` (1 vCore / 2 GB), `20` (20-16384) |
| PostgreSQL | `TF_VAR_azure_postgres_sku`, `_storage_gb` | `B_Standard_B1ms`, `32` (fixed sizes: 32, 64, 128, ...) |
| MongoDB vCore | `TF_VAR_azure_mongodb_tier`, `_storage_gb`, `_high_availability` | `M30` (2 vCore / 8 GB), `32`, `Disabled` |

There is **no network module on Azure**. `tofu/azure/vm` puts the VM's VNet, subnet, NSG
and public IP in its own resource group, `<prefix>-vm-rg`; `tofu/azure/database` puts the
three servers in `<prefix>-database-rg`, with public access limited by a firewall rule
(`TF_VAR_allowed_cidr`, turned into the IP range Azure takes). The database servers' names
are DNS names unique across Azure, so they carry a random suffix kept in state.

MongoDB vCore hands out a `mongodb+srv://` connection string with TLS required. The
module outputs it as `mongodb_uri` and `gen-data.sh` passes it to gendata as is, instead
of a host and port. MySQL's `log_bin_trust_function_creators` is ON by default on Azure,
so the fixture's functions and triggers load with no parameter set.

Connection info is printed automatically when an apply finishes.

**How long to expect:**

| Resource | Time |
|---|---|
| bucket (any CSP) | seconds |
| the automatic `ncp network` / `alibaba network` step | about a minute, added to the first `vm` or `database` |
| vm (any CSP) | a few minutes |
| `aws vm` with `TF_VAR_aws_vm_servers` | about 10 minutes more on Ubuntu, 15–25 on Windows |
| `aws database` | several minutes |
| `ncp database` | **about 30 minutes** — do not interrupt it |
| `alibaba database` | RDS several minutes to ~20 each, MongoDB 5–10 minutes (they are created in parallel) |
| `azure database` | not measured yet; Flexible Server can take tens of minutes. The engines are created in parallel |

The NCP managed database resources have no update path: every attribute forces
replacement. Changing one variable re-creates the database and costs another 30
minutes, so get `.env` right before applying.

---

## Step 4 — NCP only: issue the public domain

NCP managed databases (MySQL, PostgreSQL, MongoDB) get **two** addresses: a private
domain that only resolves inside the VPC, and a public domain for everything else.
The public domain can only be requested **from the console** — there is no API for it,
so it cannot be automated. Until you request it, the `*_host` outputs are empty and
nothing outside the VPC can connect.

```
NCP console > Database > Cloud DB for <engine> > select the DB server
  > DB Management > Public Domain Management > Request      (once per prepared engine)
```

Then pull it into the tofu state and verify:

```bash
./scripts/ncp-db-domain.sh      # refresh state + report per-engine status
```

- The PUBLIC subnet created by the `network` module is a **prerequisite** for
  requesting a public domain.
- If you destroy and re-create a database, you must **request the domain again**.
- All three NCP engines are managed, so **none of them is exempt** — each needs its own
  public domain request.
- Only the engines you prepared are checked. One left out with `--engine` is listed
  as `(not prepared)` and not waited on.

---

## Step 5 — Load test data (optional)

Fills the prepared resources with dummy and seed data by building and running
[`gendata`](gendata/).

| Target | What it does |
|---|---|
| `bucket` | Uploads dummy files (CSV, TXT, JSON, XML, SQL, PNG, GIF, ZIP) |
| `filesystem` | Transfers dummy files to the VM over SFTP |
| `database` | Loads the `shop_db` schema and seed data into whichever engines the provider has (AWS: MySQL, MariaDB, PostgreSQL / NCP: MySQL, PostgreSQL, MongoDB / the AWS VM's servers, with `--source vm`: any of the four) |

**Prerequisites:** the runner container is up (Step 2), the target resources exist
(Step 3), `go` is installed, and for NCP managed databases the public domain has been
issued (Step 4) — engines without one are skipped with a warning.

**The filesystem target writes to `data_path`**, the vm module's output —
`/home/ubuntu/testdata` on AWS (`C:/testdata` on a Windows VM), `/root/testdata` on NCP,
following each image's login account. `conn-info.sh <csp> vm` prints it, and that path is the source a
filesystem migration reads from. Override it with `TF_VAR_aws_data_path` /
`TF_VAR_ncp_data_path`, to somewhere that account can write — SFTP does not sudo.

**Where the values come from.** `gen-data.sh` assembles the connection info and
pipes it into gendata; gendata itself looks nothing up. Addresses and the database
password come from `tofu output -json` inside the runner, the object-storage key
pair from OpenBao (`secret/csp/<csp>` — `.env` no longer holds it after Step 2),
and `VAULT_ADDR`/`VAULT_TOKEN` from `.env`. Only the modules your `--target` needs
are read, so `--target bucket` does not require a VM.

It goes over **stdin, never a file**: that JSON carries the database password and
the object-storage secret key, and a file would leave both on disk after the run.
Every environment that drives gendata hands its inputs over the same way, which is
what lets gendata have a single input path.

```bash
./scripts/gen-data.sh --target all                    # bucket + VM + DB on AWS
./scripts/gen-data.sh --provider ncp --target all     # same, on NCP
./scripts/gen-data.sh --target bucket
./scripts/gen-data.sh --target database --engine mysql
./scripts/gen-data.sh --target all --dry-run          # generate locally, upload nothing
./scripts/gen-data.sh --target bucket --cleanup       # the reverse: empty the bucket
./scripts/gen-data.sh -h                              # full option list
```

**The servers installed on the AWS VM** (`TF_VAR_aws_vm_servers`) are filled with
`--source vm`. Every value then comes from the `vm` module — the servers' addresses and
their one account — so neither the `bucket` and `database` modules nor OpenBao are read,
and they need not exist:

```bash
./scripts/gen-data.sh --source vm --target all                  # VM files + MinIO + the VM's DBs
./scripts/gen-data.sh --source vm --target database             # mysql, mariadb, postgresql, mongodb
./scripts/gen-data.sh --source vm --target database --engine mariadb
./scripts/gen-data.sh --source vm --target bucket               # the VM's MinIO bucket
```

The bucket target talks to MinIO at `http://<vm>:9000`, path-style. The bulk-size check
uses the VM's volume (`TF_VAR_aws_vm_volume_size`), which the databases share with the OS
and the filesystem data. The run summary goes to its own file,
`gendata/runs/aws-<prefix>-vm-last-run.json`.

| Option | Default | Values |
|---|---|---|
| `--source` | `managed` | `managed`: the `bucket` and `database` modules. `vm`: the servers on the AWS VM (aws only). Read by `gen-data.sh` itself, not passed to gendata |
| `--target` | `all` | `bucket`, `filesystem`, `database`, `all` |
| `--engine` | `all` | `mysql`, `mariadb`, `postgresql`, `mongodb`, `all`. An engine the provider does not serve, or one not prepared (`prepare.sh --engine`), has no host output and is skipped |
| `--provider` | `aws` | `aws`, `ncp` |
| `--dry-run` | off | Generate dummy files only; skip upload, transfer and load |
| `--force` | off | Skip the existing-data check (allows overwrite and `DROP`) |
| `--cleanup` | off | Delete instead of generate. `--target bucket` only, and it empties the **whole** bucket |

**How much data** — set it in `.env`, under **gendata test data size**. These values
override [`gendata/config/config.json`](gendata/config/config.json), which only holds
the defaults:

```dotenv
GENDATA_DUMMY_SIZE_MB=8          # bucket + filesystem: total MB over all eight formats
#GENDATA_DUMMY_SIZES=png=0,gif=0,zip=100
#GENDATA_DUMMY_MAX_FILES=1000    # at most this many dummy files; 0 = no limit
GENDATA_DB_SIZE_MB=0             # database: bulk rows added after the shop_db fixture, in MB
#GENDATA_TMP_DIR=/data/gendata-tmp  # where dummy files are staged locally; default /tmp
#GENDATA_DB_WORKERS=4             # parallelism - see the table below
```

| Variable | Sets |
|---|---|
| `GENDATA_DUMMY_SIZE_MB` | Dummy files for `bucket` and `filesystem`: the **total** in MB over all eight formats (csv, txt, sql, json, xml, png, gif, zip). It is split 1 MB at a time in that order — `8` is 1 MB of each, `10` gives csv and txt 2 MB and the rest 1 MB |
| `GENDATA_DUMMY_SIZES` | Per-format sizes in MB. The formats named keep their size, and what is left of the total is split over the others; `0` switches a format off. With a total of `1000`, `png=0,gif=0,zip=100` gives zip 100 MB and the five text formats 180 MB each. Naming more than the total is an error |
| `GENDATA_DUMMY_MAX_FILES` | The most dummy files to generate, `1000` by default (`layout.maxFiles` in `config.json`); `0` means no limit. Over it the total size is kept and the files grow instead — see below |
| `GENDATA_DB_SIZE_MB` | Bulk rows added to each database after the `shop_db` fixture, in MB. `0` loads the fixture only |
| `GENDATA_GEN_WORKERS` | Dummy files generated at once. `0` (default) is one per CPU; the files are the same whatever the count |
| `GENDATA_UPLOAD_CONCURRENCY` | `bucket`: objects uploaded at once (default 32) |
| `GENDATA_SFTP_CONCURRENCY` | `filesystem`: files transferred at once (default 10) |
| `GENDATA_SFTP_CONNECTIONS` | `filesystem`: SSH connections those transfers are spread over (default 4) |
| `GENDATA_DB_WORKERS` | `database`: connections writing the bulk rows at once on MySQL, MariaDB and MongoDB (default 4). PostgreSQL's COPY stays on one. The rows are the same whatever the count |
| `GENDATA_TMP_DIR` | Where the dummy files are staged on this machine before upload or transfer, and deleted afterwards. Unset means the system temp directory (`/tmp`). Must be an absolute path; created if missing. Use it when the dummy total is large, since all of it lands here first. A run stopped with Ctrl-C leaves its `gendata-*` directory behind |

- Sizes are **in MB**, and each MB is one file of about 1 MiB.
- They are **not** `TF_VAR_*`, since OpenTofu never reads them. `gen-data.sh` sources
  `.env`, so gendata picks them up. A `GENDATA_*` key gendata does not recognise is
  reported when `gen-data.sh` runs. A value it cannot parse, such as `1G`, fails the run.
- **Mind the capacity.** The dummy files have to fit on the VM's volume
  (`TF_VAR_aws_vm_volume_size`, 20 GB), and the bulk rows have to fit in the database
  storage (AWS 20 GB). gendata refuses a request over 80% of either. NCP Cloud DB storage
  grows by itself as data is written, so the database check is skipped there.
  On NCP the VM's boot disk is `TF_VAR_ncp_vm_volume_size` (50 GB by default; NCP's own
  default is 10 GB), and the check uses the size the VM was actually built with.
  A `data_path` on the VM's EFS mount (`TF_VAR_aws_nfs_enabled=true`) is not checked:
  EFS grows with what is written.
- The database size is an estimate of rows, and each engine adds its own overhead.
  gendata reports what actually landed, and the run summary records it.

**The file limit.** Under `GENDATA_DUMMY_MAX_FILES` every MB is one ~1 MiB file. Over it
the total size stays and the files get larger:

- With more formats on than files allowed, the largest formats keep one file each and
  the rest are skipped (a `[warn]` line names them); their size moves to the others.
- png and gif stay at **20 MiB a file** at most. When the limit cannot hold them at
  that size, their file count is reduced and the size they lose moves to the other
  formats.

| `GENDATA_DUMMY_MAX_FILES=1000`, `GENDATA_DUMMY_SIZE_MB=` | Files |
|---|---|
| `8` | 8 × 1 MiB |
| `5000` | 125 per format, ~5 MiB each |
| `50000` | png, gif 313 × ~20 MiB; the other six 62–63 × ~100 MiB |
| `200000` | 125 per format; png, gif ~20 MiB, the other six ~260 MiB |

The `dummy` line of the run log shows the plan actually used:
`dummy : 200 MB in 20 files (max 20 from env, sizes from env): csv=3×~8.3 MiB ...`.

Everything else stays in `config.json`: `layout` controls the folder tree — 3 levels
deep and 3 wide by default, 27 leaf folders the files are spread over — and
`objectStorage` and `filesystem` control paths and concurrency.

**Progress** — generating the dummy files, uploading them to the bucket and
transferring them to the VM each report files and bytes done, throughput and time
left, then a summary line:

```
bucket: 120/800 files (15%), 120.0 MiB / 800.0 MiB, 12.3 MiB/s, 55s left
bucket: 800/800 files, 800.0 MiB in 1m5s (12.3 MiB/s)
```

On a terminal the line is redrawn in place; piped into a file or `tee`, a line is
written at every 10% instead.

**Safety** — gendata refuses to run if the target already holds data, because the
database fixtures are destructive (they include `DROP`). Use `--force` to override.
Paths are fixed rather than per-run, so re-running overwrites the same location instead
of accumulating copies. A summary of the last run is written per environment, to
`gendata/runs/<csp>-<prefix>-last-run.json`.

---

## Step 6 — Get connection info

### `conn-info.sh` — everything at once (recommended)

```
./scripts/conn-info.sh [aws|ncp|alibaba|azure] [network|bucket|vm|database|all] [--prefix <name>] [--reveal]
```

```bash
./scripts/conn-info.sh                                   # every environment, every CSP, secrets masked
./scripts/conn-info.sh aws database                      # the DBs of every AWS environment
./scripts/conn-info.sh ncp --prefix cptf                 # one environment
./scripts/conn-info.sh ncp database --prefix cptf --reveal  # its passwords and URIs in clear text
```

| Argument | Default | Values |
|---|---|---|
| csp | both | `aws`, `ncp` |
| resource | `all` | `bucket`, `vm`, `database`, `all`, plus `network` for NCP |
| `--prefix` | every prefix | One environment's prefix. `.env` does not need to select it |
| `--reveal` | off | Print sensitive values in clear text instead of `<sensitive>` |

**Every environment is shown by default**, one block per prefix, the one `.env`
selects first and marked `*`. Only tofu state is read, so this works for any prefix
without touching `.env`. Modules that hold no resources are left out. For NCP
`database`, a warning is printed for any engine whose public domain has not been
issued.

`--reveal` prints passwords and connection URIs to your terminal — be careful with
scrollback, logs and screen sharing. Without `--prefix` it does so for **every**
environment at once, and says so first; add `--prefix` to reveal one.

### Connecting to a VM

Copy the `ssh_command` output and run it from the `tofuenv` directory:

```bash
ssh -i ssh_keys/aws-cptf-vm.pem ubuntu@3.35.xxx.xxx          # AWS: user is ubuntu
ssh -i ssh_keys/aws-cptf-vm.pem Administrator@3.35.xxx.xxx   # AWS Windows: Administrator
ssh -i ssh_keys/ncp-cptf-vm-a1b2c3.pem root@223.130.xxx.xxx  # NCP: user is root
```

A Windows VM also takes RDP at `rdp_address`, as `Administrator` with `admin_password`
(`./scripts/conn-info.sh aws vm --reveal`).

The private key is generated by tofu and written to `ssh_keys/` with mode 600. It is
gitignored; never commit it. The file name carries the prefix — on NCP the whole login
key name, random suffix included — so environments never overwrite each other's key.

### Reading one output directly

`conn-info.sh` masks sensitive values unless you pass `--reveal`. To read a single
value yourself:

```bash
docker exec -e TF_WORKSPACE=cptf tofuenv-runner bash -c \
  'cd /work/tofu/aws/database && tofu output -raw mysql_connection_uri'
```

`TF_WORKSPACE` is the prefix — every module keeps one state per prefix, and without it
tofu reads the empty `default` workspace. Replace `aws` with `ncp`, and `database` with
`bucket`, `vm` or `network`. Drop `-raw`
for non-sensitive outputs. Output names are the **same on every CSP**, so anything
reading them stays CSP-agnostic:

| Module | Outputs |
|---|---|
| bucket | `bucket_name`, `bucket_region`; AWS also `bucket_arn`, `bucket_domain_name`; NCP also `s3_endpoint`, `s3_signing_region` |
| every module | `name_prefix` — the prefix, and so the workspace, the environment lives in |
| vm | `public_ip`, `ssh_user`, `key_file`, `ssh_command`, `data_path`; AWS also `nfs_enabled`, `nfs_file_system_id`, `nfs_dns_name`, `nfs_mount_path`, `vm_os`, `admin_password` and `rdp_address` (Windows); NCP also `private_ip`, `login_key_name` |
| vm, AWS with servers | `vm_servers`, `server_username`, `server_password`, `db_name`; `<engine>_host`/`<engine>_port` named as in the database module (`mysql`, `mariadb`, `postgres`, `mongodb`); `minio_endpoint`, `minio_console_url`, `minio_bucket`. A server not installed has null outputs |
| database | `db_name`, `db_username`, `db_password`; per engine `<engine>_host`, `<engine>_port`, `<engine>_connection_uri` where `<engine>` is `mysql`, `mariadb` or `postgres` on AWS, and `mysql`, `postgres` or `mongodb` on NCP |
| database, NCP managed | `<engine>_public_domain`, `<engine>_private_domain`, `<engine>_acg_no` |

Sensitive outputs (`db_password`, every `*_connection_uri`, and the vm's `server_password`
and `admin_password`) need `-raw`. On NCP,
`<engine>_host` **is** the public domain, so it and the URI are empty until Step 4 is
done; `<engine>_private_domain` only resolves inside the VPC.

---

## Step 7 — Destroy resources

**Destroy what you prepared. RDS instances, servers and public IPs are billed.**

```
./scripts/teardown.sh <csp> <resource> [--engine e1,e2]
```

```bash
./scripts/teardown.sh aws database
./scripts/teardown.sh aws vm
./scripts/teardown.sh aws bucket
```

On NCP, the same three resources — the `network` module is not one of them:

```bash
./scripts/teardown.sh ncp database
./scripts/teardown.sh ncp vm
./scripts/teardown.sh ncp bucket
```

On Alibaba, likewise — its `network` module is handled the same way:

```bash
./scripts/teardown.sh alibaba database
./scripts/teardown.sh alibaba vm
./scripts/teardown.sh alibaba bucket
```

On Azure, likewise — there is no network module to clean up:

```bash
./scripts/teardown.sh azure database     # deletes <prefix>-database-rg with the servers
./scripts/teardown.sh azure vm           # deletes <prefix>-vm-rg with the VM and its network
./scripts/teardown.sh azure bucket       # deletes the container only - see below
```

**One database engine at a time** — `--engine` destroys just the engines named; the
others keep running:

```bash
./scripts/teardown.sh aws database --engine postgresql
./scripts/teardown.sh ncp database --engine mongodb
./scripts/teardown.sh alibaba database --engine mariadb
./scripts/teardown.sh azure database --engine mongodb
```

- It is a targeted destroy of those engines' own resources (the instance, plus its
  parameter group on AWS, its ACG rule on NCP, its account, database and public
  endpoint on Alibaba, or its database and firewall rule on Azure). The engines that stay are not re-applied, so a `.env` change
  made since cannot re-create them.
- Removing the **last** engine left destroys the whole database module — subnet group
  and security group included — exactly like a run without `--engine`.
- OpenTofu warns that `-target` is in effect and that outputs may be incomplete — expected
  here. The script follows the destroy with a refresh-only apply, which changes nothing
  but clears the removed engine's `*_host` / `*_port`, so `conn-info.sh` and `gen-data.sh`
  stop seeing it.
- Naming an engine that is not running is reported and does nothing.
- On NCP and Alibaba, the `network` module stays while any engine is left.

**`ncp bucket` is emptied first.** NCP's bucket resource has no `force_destroy` — the
one `tofu/aws/bucket` sets on `aws_s3_bucket` — and the S3 API refuses to delete a
bucket that still holds objects:

```
Error: DELETING ERROR
operation error S3: DeleteBucket, https response error StatusCode: 409,
api error BucketNotEmpty: The bucket you tried to delete is not empty.
```

So the script runs `./scripts/gen-data.sh --provider ncp --target bucket --cleanup`
before the destroy, which needs **go on the host**. Without it — or if the cleanup
fails — you are told so and the destroy still runs: an empty bucket goes either way.
If it comes back with `BucketNotEmpty`, empty the bucket in the console (incomplete
multipart uploads included) and run the command again.

**`alibaba bucket` is not emptied first.** `tofu/alibaba/bucket` sets `force_destroy`
on `alicloud_oss_bucket`, as AWS does, so the destroy deletes the objects itself and no
go is needed.

**`azure bucket` deletes the container, not the storage account.** The container goes with
every blob in it, so nothing has to be emptied first. The storage account
(`AZURE_S3_ACCESS_KEY`) was there before tofuenv and stays, with any other container in it.
`azure vm` and `azure database` delete their whole resource group instead.

A destroy that fails is **retried once, 60 seconds later** (`destroy failed — retry 1/1
in 60s`). NCP answers some delete calls with a 500 while the resource is still being
released, and the same call then goes through. If the retry fails too, the error is
printed again at the end and the command exits non-zero.

**Only the prefix `.env` sets is destroyed.** To remove an environment made under
another prefix, put that prefix back in `.env` and run the same commands. A workspace
the destroy empties is deleted with it.

A module that tracks no resource is reported and skipped rather than destroyed —
`ncp/database (prefix cptf) holds no resources - nothing to destroy.` The destroy would
be a no-op that still costs a full plan.

Because only `vm` and `database` reference the VPC, the script destroys the prefix's
`network` module for you as soon as **neither of them is left in that prefix** (a
database with even one engine left still counts). Destroy them in either order;
whichever goes last takes the VPC, subnet and ACG with it (on Alibaba: the VPC, vSwitch
and security group). While one of them is still prepared, you will see
`Keeping ncp/network: another module still uses it.` (`alibaba/network` on Alibaba).

If the CSP has not finished releasing the servers, that final network destroy can fail.
It is reported as a **warning**, not an error — the resource you asked for is already
gone — and re-running the same command a few minutes later finishes the job.

If an NCP managed database destroy ends in `WAITING FOR DELETE ERROR`, the delete
request already went through — **run the same command again** and it will finish. The
provider's delete wait is hard-coded (5 minutes for MySQL, 10 for PostgreSQL and
MongoDB) and sometimes expires first.

### NCP login keys that will not delete

An NCP destroy can get everything except the login key:

```
Error: Error Deleting LoginKey
Status: 500 Internal Server Error, Body: {
  "responseError": { "returnCode": "1300",
    "returnMessage": "Please try your call again later.\nTemporarily out of service." } }
```

`1300` is NCP's catch-all failure. It is usually described as transient — the server the
key belonged to is still being released — but it has been observed **unchanged over 12
minutes of retries**, and calling `deleteLoginKeys` directly returns the same thing, so
it is not something the scripts can wait out.

So they do not try. This is the one failure `teardown.sh` does **not** retry: once the
login key is all that is left, the 60-second retry would only spend a minute to fail
identically. Recovery is immediate, in two reported steps:

```
[1/2] dropping the key from state
        tofu state rm ncloud_login_key.vm   (cptf-vm-a1b2c3)
[2/2] re-running destroy to clear the module's outputs
```

**Forgetting the key is safe because the names are unique.** The login key is named
`<prefix>-vm-<random>` (a `random_id` resource in `tofu/ncp/vm`), so a key left behind at
NCP cannot collide with the one the next preparation asks for. That is the whole reason for the suffix: `ncloud_login_key`
refuses to create a name that already exists, and without the suffix one undeletable key
would block the module forever.

The cost is that leftovers accumulate in the account. They are harmless and free, but
worth clearing out now and then:

```
NCP console > Services > Compute > Server > Login Key   (Classic platform, not VPC)
```

To tell which key belongs to a live resource, read the output rather than guessing the
name:

```bash
docker exec -e TF_WORKSPACE=cptf tofuenv-runner bash -c \
  'cd /work/tofu/ncp/vm && tofu output -raw login_key_name'
```

The matching `ssh_keys/ncp-<login key name>.pem` is a `local_sensitive_file` resource, so
a destroy already removed it — if the file is still there, delete it: the key it belongs
to is gone.

---

## Multiple environments (one per prefix)

`TF_VAR_aws_name_prefix` and `TF_VAR_ncp_name_prefix` do more than name resources: each
prefix is an environment of its own. Every module — `bucket`, `vm`, `database` and
`ncp/network` — keeps one tofu state per prefix, as a
[workspace](https://opentofu.org/docs/language/state/workspaces/) named after it:

```
tofu/<csp>/<module>/terraform.tfstate.d/<prefix>/terraform.tfstate
```

**Every script acts on the prefix `.env` sets, and only on it** — `prepare.sh`,
`teardown.sh`, `gen-data.sh` and `ncp-db-domain.sh` alike. The read-only ones look at
all of them: `list.sh` lists every environment, and `conn-info.sh` shows every
environment's connection info (`--prefix <name>` for one). The rest of
`.env` (bucket name, engine versions, NFS, ...) describes that one environment too.

So changing a prefix does not rename, replace or break anything:

```bash
# .env: TF_VAR_aws_name_prefix=cptf
./scripts/prepare.sh aws vm           # cptf-vm, key in ssh_keys/aws-cptf-vm.pem
# .env: TF_VAR_aws_name_prefix=cptf2
./scripts/prepare.sh aws vm           # a second VM, cptf2-vm - cptf-vm keeps running
```

**See every environment** — the one command that looks past `.env`:

```bash
./scripts/list.sh
```

```
=== prepared environments ===
  CSP   PREFIX        bucket  vm   database  network
  aws   cptf          yes     yes  -
  aws   cptf2 *       -       yes  yes
  ncp   cptf *        -       yes  -         yes

  * the prefix .env selects - the environment every other script acts on.
```

---

## Step 8 — Shut down

```bash
./scripts/down.sh          # stop containers, keep vault data and stored credentials
./scripts/down.sh --wipe   # also delete vault data: credentials must be re-entered
```

### Coming back later

```bash
./scripts/up.sh
```

The vault is simply unsealed; your credentials are already stored, so there is nothing
to re-enter and the blank keys in `.env` are fine as they are. To **change** a
credential, put the new value in `.env` and run `./scripts/register-creds.sh`.
