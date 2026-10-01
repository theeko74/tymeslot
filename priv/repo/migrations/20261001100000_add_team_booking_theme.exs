defmodule Tymeslot.Repo.Migrations.AddTeamBookingTheme do
  use Ecto.Migration

  @moduledoc """
  Gives a team page a theme of its own.

  `teams.booking_theme` is the theme the team page renders; nil keeps the
  previous behaviour of borrowing the owner's. A team's customisation of a
  theme (colours, background) is a `theme_customizations` row carrying the
  team's id. Such a row also carries the owner's `profile_id`, which stays
  `NOT NULL`, so that the existing cascade and per-profile file cleanup still
  cover it.

  Customisations are unique per (profile, theme) for a profile's own rows and
  per (team, theme) for a team's. Before the per-team index is built, duplicate
  team rows (none can exist yet, the column being new) would be removed; the
  statement is there so the build cannot fail on data this project cannot see.

  ## Locking

  The index rebuilds lock `theme_customizations` while they run, which is
  acceptable because migrations run before the application starts (`start.sh`
  runs them in a one-shot VM), so no request waits on the lock.
  """

  def up do
    alter table(:teams) do
      add(:booking_theme, :string)
    end

    alter table(:theme_customizations) do
      # Nullable and null on every existing row, so validating the key scans
      # nothing that can fail.
      # excellent_migrations:safety-assured-for-next-line column_reference_added
      add(:team_id, references(:teams, on_delete: :delete_all))
    end

    # See the moduledoc.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    DELETE FROM theme_customizations tc
    USING (
      SELECT id, row_number() OVER (PARTITION BY team_id, theme_id ORDER BY id) AS rn
      FROM theme_customizations
      WHERE team_id IS NOT NULL
    ) dup
    WHERE tc.id = dup.id AND dup.rn > 1
    """)

    # Not concurrent: see "Locking" above.
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(index(:theme_customizations, [:profile_id, :theme_id]))

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:theme_customizations, [:profile_id, :theme_id],
        name: :theme_customizations_profile_id_theme_id_index,
        where: "team_id IS NULL"
      )
    )

    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(
      unique_index(:theme_customizations, [:team_id, :theme_id],
        name: :theme_customizations_team_id_theme_id_index,
        where: "team_id IS NOT NULL"
      )
    )
  end

  def down do
    execute("DELETE FROM theme_customizations WHERE team_id IS NOT NULL")

    drop(index(:theme_customizations, [:team_id, :theme_id]))
    drop(index(:theme_customizations, [:profile_id, :theme_id]))
    create(unique_index(:theme_customizations, [:profile_id, :theme_id]))

    alter table(:theme_customizations) do
      remove(:team_id)
    end

    alter table(:teams) do
      remove(:booking_theme)
    end
  end
end
