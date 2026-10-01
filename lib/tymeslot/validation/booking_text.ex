defmodule Tymeslot.Validation.BookingText do
  @moduledoc """
  The changeset rules shared by every record carrying a booking page's
  introductory wording: a profile's own page and a team's.

  The record has a `booking_text_enabled` switch and three lines,
  `booking_heading`, `booking_greeting` and `booking_instruction`. The lines
  are kept whether or not they are in use, so switching the customisation off
  and back on restores the wording instead of losing it. That is why they are
  required only while the switch is on.

  Casts with `empty_values: []` deliberately. Ecto's default treats `""` as
  absent, which would silently drop the change when someone clears a field,
  leaving the old wording on the page.
  """

  import Ecto.Changeset

  alias Tymeslot.Validation.Constraints

  @fields [:booking_heading, :booking_greeting, :booking_instruction]

  @doc "The three wording fields."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "Casts and validates the switch and the three lines on `record`."
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:booking_text_enabled | @fields], empty_values: [])
    |> normalize()
    |> validate_length(:booking_heading, max: Constraints.booking_heading_max_length())
    |> validate_length(:booking_greeting, max: Constraints.booking_welcome_line_max_length())
    |> validate_length(:booking_instruction, max: Constraints.booking_welcome_line_max_length())
    |> validate_present()
  end

  defp normalize(changeset) do
    Enum.reduce(@fields, changeset, fn field, acc ->
      update_change(acc, field, &normalize_line/1)
    end)
  end

  defp normalize_line(nil), do: nil

  defp normalize_line(value) when is_binary(value) do
    # Postgres rejects null bytes even though they are valid UTF-8, so they are
    # stripped at the boundary rather than left to blow up on insert.
    case value |> String.replace("\x00", "") |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_present(changeset) do
    if fetch_field!(changeset, :booking_text_enabled) do
      validate_required(changeset, @fields)
    else
      changeset
    end
  end
end
