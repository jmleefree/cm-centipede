# ---------------------------------------------------------------------------
# The target databases for one MySQL or MariaDB cell.
#
#   A cell migrates every database named in var.databases, and each one has to
#   exist and be empty before the migration starts - centipede creates a target
#   database only for providerName "onprem", and a managed instance is aws or
#   ncp. So the matrix creates them here, and one destroy removes the lot.
#
#   There is no counterpart to tofu/pg-target's GRANT: on MySQL and MariaDB the
#   master account already holds every privilege on a database it created, so
#   creating it is the whole job.
# ---------------------------------------------------------------------------

resource "mysql_database" "target" {
  for_each = toset(var.databases)

  name = each.value

  # Stated, not left to the instance. This used to be left out, meant to follow
  # the server's defaults, but the provider (petoju/mysql) fills in these two
  # values itself when none is given, so every cell database was created with
  # them all along. Writing them here keeps that if the provider's default
  # changes, and matches the sources (MYSQL_SRC_CHARSET / _COLLATION). Table
  # character sets travel inside the dump's CREATE TABLE statements either way.
  default_character_set = "utf8mb4"
  default_collation     = "utf8mb4_general_ci"
}
