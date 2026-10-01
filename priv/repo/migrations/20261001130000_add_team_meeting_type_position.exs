defmodule Tymeslot.Repo.Migrations.AddTeamMeetingTypePosition do
  use Ecto.Migration

  @moduledoc """
  Orders a team page's meeting types per team.

  A team meeting type is generic and can be offered by several teams, each
  listing its types in its own order: the order lives on the link,
  `team_meeting_types.position`, not on the meeting type. Existing links are
  numbered in the order the pages showed them until now, the meeting types'
  own `sort_order` then name.
  """

  def up do
    alter table(:team_meeting_types) do
      # A constant default on a new column is a metadata-only change in
      # PostgreSQL 11+, so no table rewrite.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add(:position, :integer, null: false, default: 0)
    end

    flush()

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE team_meeting_types AS l
    SET position = ranked.position
    FROM (
      SELECT l2.id,
             row_number() OVER (
               PARTITION BY l2.team_id ORDER BY mt.sort_order, mt.name, mt.id
             ) - 1 AS position
      FROM team_meeting_types AS l2
      JOIN meeting_types AS mt ON mt.id = l2.meeting_type_id
    ) AS ranked
    WHERE ranked.id = l.id
    """)
  end

  def down do
    alter table(:team_meeting_types) do
      remove(:position)
    end
  end
end
