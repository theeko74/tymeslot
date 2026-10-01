defmodule Tymeslot.ThemeCustomizations.Owner do
  @moduledoc """
  Whose theme customisation it is: a profile's own booking page, or a team's.

  A profile is named by its id, as it always has been, so every existing
  caller is unchanged. A team page is `{:team, team_id, profile_id}`: its rows
  carry the team's id and the owner's profile id, so that the profile's cascade
  and file cleanup still cover them, and its uploaded files live under the
  team's own directory.
  """

  @type t :: pos_integer() | {:team, pos_integer(), pos_integer()}

  @doc "The profile id stored on the owner's rows."
  @spec profile_id(t()) :: pos_integer()
  def profile_id({:team, _team_id, profile_id}), do: profile_id
  def profile_id(profile_id) when is_integer(profile_id), do: profile_id

  @doc "The team id stored on the owner's rows, nil for a profile's own."
  @spec team_id(t()) :: pos_integer() | nil
  def team_id({:team, team_id, _profile_id}), do: team_id
  def team_id(profile_id) when is_integer(profile_id), do: nil

  @doc "The path segments of the owner's upload directory under `themes/`."
  @spec storage_segments(t()) :: [String.t()]
  def storage_segments({:team, team_id, _profile_id}), do: ["teams", to_string(team_id)]
  def storage_segments(profile_id) when is_integer(profile_id), do: [to_string(profile_id)]
end
