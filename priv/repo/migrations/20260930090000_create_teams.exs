defmodule Tymeslot.Repo.Migrations.CreateTeams do
  use Ecto.Migration

  @moduledoc """
  Teams: several hosts booked together on one public page (`/team/:slug`).

  A team page offers only the times every member is free, and a booking made
  there is one meeting shared by all of them. The owner is its organiser, as on
  a personal page; the other members are recorded in `meeting_co_hosts`, a
  snapshot taken at booking time so that a member leaving the team later does
  not rewrite who the meeting was booked with.

  A team's booking settings live in a real `meeting_types` row owned by the
  team's owner and flagged by `meeting_types.team_id`, so the booking pipeline,
  which re-reads the meeting type by id, needs no second code path.

  `meetings.team_id` is nilified when a team is deleted: the meetings it
  produced stay on everyone's calendar, they just stop pointing at a team.
  """

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  #
  # The new tables are empty and unreachable until this migration commits. The
  # two columns added to existing tables are nullable, have no default and are
  # null on every existing row, so validating their foreign keys scans nothing
  # that can fail. The non-concurrent index builds lock `meetings` and
  # `meeting_types` while they run, which is acceptable because migrations run
  # before the application starts (`start.sh` runs them in a one-shot VM), so
  # no request waits on the lock.

  def change do
    create table(:teams) do
      add(:owner_user_id, references(:users, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:description, :text)
      add(:duration_minutes, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:teams, [:slug]))
    create(index(:teams, [:owner_user_id]))

    create table(:team_members) do
      add(:team_id, references(:teams, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:role, :string, null: false, default: "member")

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:team_members, [:team_id, :user_id]))
    create(index(:team_members, [:user_id]))

    alter table(:meeting_types) do
      add(:team_id, references(:teams, on_delete: :delete_all))
    end

    # Not unique: `Tymeslot.Teams` writes a team's one settings row in the
    # transaction that creates the team, and nothing else sets the column.
    create(index(:meeting_types, [:team_id]))

    alter table(:meetings) do
      add(:team_id, references(:teams, on_delete: :nilify_all))
    end

    create(index(:meetings, [:team_id]))

    create table(:meeting_co_hosts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:confirmation_sent_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:meeting_co_hosts, [:meeting_id, :user_id]))
    create(index(:meeting_co_hosts, [:user_id]))
  end
end
