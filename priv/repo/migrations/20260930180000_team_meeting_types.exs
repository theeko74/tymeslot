defmodule Tymeslot.Repo.Migrations.TeamMeetingTypes do
  use Ecto.Migration

  @moduledoc """
  Lets a team offer several meeting types, and gives its page a custom tagline.

  A team used to carry a single duration, mirrored onto one settings meeting
  type. It now owns any number of meeting types (still stored in
  `meeting_types`, owned by the team's owner and flagged with `team_id`), so
  the team's own `duration_minutes` goes, and `tagline` is added: the line the
  team page shows under the team's name.

  A team's meeting types are named and slugged within the team, not within the
  owner's own meeting types: a team offering "30 minutes" must not collide with
  the owner's personal "30 minutes". The per-user unique indexes on name and
  slug are therefore narrowed to personal types (`team_id IS NULL`), and
  per-team ones are added.

  ## Existing rows

  Before the per-team indexes are built, any team meeting types sharing a name
  within one team are renamed apart (the later ones get their id appended), and
  any sharing a custom slug keep only the earliest slug (the others fall back to
  their name-derived slug). At this point a team holds at most one meeting type,
  so both statements are expected to touch nothing; they are there so the index
  builds cannot fail on data this project cannot see.

  That one meeting type was created private, because the team page used to
  book it without listing it. The page now lists a team's public types, so it
  is made public here, or an existing team page would offer nothing.

  ## Locking

  The index rebuilds lock `meeting_types` while they run, which is acceptable
  because migrations run before the application starts (`start.sh` runs them in
  a one-shot VM), so no request waits on the lock.
  """

  def up do
    alter table(:teams) do
      add(:tagline, :string)
      # The column was added by this same unreleased feature and is no longer
      # read: a team's durations now live on its meeting types.
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove(:duration_minutes)
    end

    # See "Existing rows" above.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("UPDATE meeting_types SET is_private = false WHERE team_id IS NOT NULL")

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE meeting_types mt
    SET name = mt.name || ' (' || mt.id || ')'
    FROM (
      SELECT id, row_number() OVER (PARTITION BY team_id, name ORDER BY id) AS rn
      FROM meeting_types
      WHERE team_id IS NOT NULL
    ) dup
    WHERE mt.id = dup.id AND dup.rn > 1
    """)

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE meeting_types mt
    SET slug = NULL
    FROM (
      SELECT id, row_number() OVER (PARTITION BY team_id, slug ORDER BY id) AS rn
      FROM meeting_types
      WHERE team_id IS NOT NULL AND slug IS NOT NULL
    ) dup
    WHERE mt.id = dup.id AND dup.rn > 1
    """)

    # Not concurrent: see "Locking" above.
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:user_id, :name], name: :meeting_types_user_id_name_index))

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:user_id, :name],
        name: :meeting_types_user_id_name_index,
        where: "team_id IS NULL"
      )
    )

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:team_id, :name],
        name: :meeting_types_team_id_name_index,
        where: "team_id IS NOT NULL"
      )
    )

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:user_id, :slug], name: :meeting_types_user_id_slug_index))

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:user_id, :slug],
        name: :meeting_types_user_id_slug_index,
        where: "slug IS NOT NULL AND team_id IS NULL"
      )
    )

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:team_id, :slug],
        name: :meeting_types_team_id_slug_index,
        where: "slug IS NOT NULL AND team_id IS NOT NULL"
      )
    )
  end

  def down do
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:team_id, :slug], name: :meeting_types_team_id_slug_index))
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:user_id, :slug], name: :meeting_types_user_id_slug_index))

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:user_id, :slug],
        name: :meeting_types_user_id_slug_index,
        where: "slug IS NOT NULL"
      )
    )

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:team_id, :name], name: :meeting_types_team_id_name_index))
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:meeting_types, [:user_id, :name], name: :meeting_types_user_id_name_index))
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:meeting_types, [:user_id, :name], name: :meeting_types_user_id_name_index)
    )

    alter table(:teams) do
      add(:duration_minutes, :integer, null: false, default: 30)
      remove(:tagline)
    end
  end
end
