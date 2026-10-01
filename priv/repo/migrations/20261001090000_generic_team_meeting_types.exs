defmodule Tymeslot.Repo.Migrations.GenericTeamMeetingTypes do
  use Ecto.Migration

  @moduledoc """
  Makes team meeting types generic: one is created once, by a user, and offered
  by any number of that user's teams.

  A team meeting type used to belong to exactly one team (`meeting_types.team_id`).
  It now carries `is_team_type` and is attached to teams through the
  `team_meeting_types` join table, so the same "30 minutes" can be offered by
  two teams without being configured twice. Team meeting types stay out of
  every personal listing, and are named and slugged among their owner's team
  meeting types rather than among their personal ones.

  ## Existing rows

  Every row with a `team_id` becomes a team meeting type attached to that team.
  Team types of one user sharing a name (two teams each with their own
  "30 minutes") are renamed apart, the later ones getting their id appended,
  and those sharing a custom slug keep only the earliest one, the others falling
  back to their name-derived slug, so that the per-user indexes can be built.

  ## Locking

  The index rebuilds lock `meeting_types` while they run, which is acceptable
  because migrations run before the application starts (`start.sh` runs them in
  a one-shot VM), so no request waits on the lock.
  """

  def up do
    alter table(:meeting_types) do
      # A constant default on a new column is a metadata-only change in
      # PostgreSQL 11+, so no table rewrite.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add(:is_team_type, :boolean, null: false, default: false)
    end

    create table(:team_meeting_types) do
      # excellent_migrations:safety-assured-for-next-line column_reference_added
      add(:team_id, references(:teams, on_delete: :delete_all), null: false)
      # excellent_migrations:safety-assured-for-next-line column_reference_added
      add(:meeting_type_id, references(:meeting_types, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    # The join table is created empty above, then filled below from rows that
    # already satisfy the constraint (one per meeting type).
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(unique_index(:team_meeting_types, [:team_id, :meeting_type_id]))
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(index(:team_meeting_types, [:meeting_type_id]))

    # See "Existing rows" above.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("UPDATE meeting_types SET is_team_type = true WHERE team_id IS NOT NULL")

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    INSERT INTO team_meeting_types (team_id, meeting_type_id, inserted_at, updated_at)
    SELECT team_id, id, now(), now() FROM meeting_types WHERE team_id IS NOT NULL
    """)

    # Not concurrent: see "Locking" above.
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:team_id, :slug], name: :meeting_types_team_id_slug_index))
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:team_id, :name], name: :meeting_types_team_id_name_index))
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:user_id, :slug], name: :meeting_types_user_id_slug_index))
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:user_id, :name], name: :meeting_types_user_id_name_index))

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE meeting_types mt
    SET name = mt.name || ' (' || mt.id || ')'
    FROM (
      SELECT id, row_number() OVER (PARTITION BY user_id, name ORDER BY id) AS rn
      FROM meeting_types
      WHERE is_team_type
    ) dup
    WHERE mt.id = dup.id AND dup.rn > 1
    """)

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE meeting_types mt
    SET slug = NULL
    FROM (
      SELECT id, row_number() OVER (PARTITION BY user_id, slug ORDER BY id) AS rn
      FROM meeting_types
      WHERE is_team_type AND slug IS NOT NULL
    ) dup
    WHERE mt.id = dup.id AND dup.rn > 1
    """)

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:user_id, :name],
        name: :meeting_types_user_id_name_index,
        where: "NOT is_team_type"
      )
    )

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:user_id, :name],
        name: :meeting_types_user_id_team_type_name_index,
        where: "is_team_type"
      )
    )

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:user_id, :slug],
        name: :meeting_types_user_id_slug_index,
        where: "slug IS NOT NULL AND NOT is_team_type"
      )
    )

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:user_id, :slug],
        name: :meeting_types_user_id_team_type_slug_index,
        where: "slug IS NOT NULL AND is_team_type"
      )
    )

    alter table(:meeting_types) do
      # Replaced by `team_meeting_types` above, every value carried over.
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove(:team_id)
    end
  end

  def down do
    alter table(:meeting_types) do
      add(:team_id, references(:teams, on_delete: :delete_all))
    end

    execute("""
    UPDATE meeting_types mt
    SET team_id = link.team_id
    FROM (
      SELECT DISTINCT ON (meeting_type_id) meeting_type_id, team_id
      FROM team_meeting_types
      ORDER BY meeting_type_id, id
    ) link
    WHERE mt.id = link.meeting_type_id
    """)

    drop(
      index(:meeting_types, [:user_id, :slug], name: :meeting_types_user_id_team_type_slug_index)
    )

    drop(index(:meeting_types, [:user_id, :slug], name: :meeting_types_user_id_slug_index))

    drop(
      index(:meeting_types, [:user_id, :name], name: :meeting_types_user_id_team_type_name_index)
    )

    drop(index(:meeting_types, [:user_id, :name], name: :meeting_types_user_id_name_index))

    create(index(:meeting_types, [:team_id]))

    create(
      unique_index(:meeting_types, [:user_id, :name],
        name: :meeting_types_user_id_name_index,
        where: "team_id IS NULL"
      )
    )

    create(
      unique_index(:meeting_types, [:team_id, :name],
        name: :meeting_types_team_id_name_index,
        where: "team_id IS NOT NULL"
      )
    )

    create(
      unique_index(:meeting_types, [:user_id, :slug],
        name: :meeting_types_user_id_slug_index,
        where: "slug IS NOT NULL AND team_id IS NULL"
      )
    )

    create(
      unique_index(:meeting_types, [:team_id, :slug],
        name: :meeting_types_team_id_slug_index,
        where: "slug IS NOT NULL AND team_id IS NOT NULL"
      )
    )

    drop(table(:team_meeting_types))

    alter table(:meeting_types) do
      remove(:is_team_type)
    end
  end
end
