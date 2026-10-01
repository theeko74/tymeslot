defmodule Tymeslot.Repo.Migrations.TeamPageTextAndLogo do
  use Ecto.Migration

  @moduledoc """
  Gives a team page the same introductory wording a personal page has, and a
  logo of its own.

  `booking_text_enabled`, `booking_heading`, `booking_greeting` and
  `booking_instruction` mirror the profile columns of the same names: with the
  switch off the page shows its built-in lines (the team's name, its members,
  its description). They replace `tagline`, a single custom greeting line; a
  team that had one keeps it as its custom greeting, its name as the heading
  and its description (or the built-in instruction) as the instruction, the
  three being required together.

  `logo` is the file name of the team's uploaded logo, shown on the team page
  in place of the owner's photo.
  """

  def up do
    alter table(:teams) do
      # A constant default on a new column is a metadata-only change in
      # PostgreSQL 11+, so no table rewrite.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add(:booking_text_enabled, :boolean, null: false, default: false)
      add(:booking_heading, :string)
      add(:booking_greeting, :string)
      add(:booking_instruction, :string)
      add(:logo, :string)
    end

    flush()

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE teams
    SET booking_text_enabled = true,
        booking_heading = left(name, 60),
        booking_greeting = left(tagline, 80),
        booking_instruction = COALESCE(NULLIF(left(description, 80), ''), 'Pick an option below.')
    WHERE tagline IS NOT NULL
    """)

    alter table(:teams) do
      # Carried over into `booking_greeting` above.
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove(:tagline)
    end
  end

  def down do
    alter table(:teams) do
      add(:tagline, :string)
    end

    flush()

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE teams SET tagline = left(booking_greeting, 120)
    WHERE booking_text_enabled AND booking_greeting IS NOT NULL
    """)

    alter table(:teams) do
      remove(:booking_text_enabled)
      remove(:booking_heading)
      remove(:booking_greeting)
      remove(:booking_instruction)
      remove(:logo)
    end
  end
end
