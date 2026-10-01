defmodule Tymeslot.Teams.TeamLogos do
  @moduledoc """
  A team's logo: the image its page shows in place of the owner's photo.

  Stored like a profile avatar (`Tymeslot.Profiles.Avatars`), under the upload
  directory at `team_logos/<team id>/`, with the file name on the team row. The
  same file types and size cap apply, and the same content check rejects a file
  that is not really an image whatever its extension.
  """

  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Teams.{TeamQueries, TeamSchema}
  alias Tymeslot.Utils.MediaValidator
  alias TymeslotWeb.Helpers.UploadHandler

  @directory "team_logos"

  @type uploaded_entry :: %{
          required(:path) => String.t(),
          required(:client_name) => String.t(),
          optional(:client_size) => non_neg_integer()
        }

  @doc "The public path of the team's logo, or nil when it has none."
  @spec logo_path(TeamSchema.t() | map() | nil) :: String.t() | nil
  def logo_path(%{id: team_id, logo: logo}) when is_binary(logo) and logo != "",
    do: "/uploads/#{@directory}/#{team_id}/#{logo}"

  def logo_path(_team), do: nil

  @doc """
  Validates and stores an uploaded logo, records it on the team, and removes
  the one it replaces.
  """
  @spec store(TeamSchema.t(), uploaded_entry()) ::
          {:ok, TeamSchema.t()} | {:error, String.t() | atom() | Ecto.Changeset.t()}
  def store(%TeamSchema{} = team, entry) do
    params = %{
      "path" => entry.path,
      "client_name" => entry.client_name,
      "size" => Map.get(entry, :client_size)
    }

    with {:ok, _params} <- Avatars.validate_upload(params),
         {:ok, filename} <- copy(team, entry),
         {:ok, updated} <- TeamQueries.update_logo(team, filename) do
      delete_file(team, team.logo)
      {:ok, updated}
    end
  end

  @doc "Removes the team's logo, file and record."
  @spec remove(TeamSchema.t()) :: {:ok, TeamSchema.t()} | {:error, Ecto.Changeset.t()}
  def remove(%TeamSchema{} = team) do
    with {:ok, updated} <- TeamQueries.update_logo(team, nil) do
      delete_file(team, team.logo)
      {:ok, updated}
    end
  end

  @doc "Removes every logo file of a deleted team. Touches no database row."
  @spec delete_all_files(pos_integer()) :: :ok
  def delete_all_files(team_id) when is_integer(team_id) do
    File.rm_rf(team_directory(team_id))
    :ok
  end

  defp copy(team, entry) do
    extension = entry.client_name |> Path.extname() |> String.downcase()
    unique = "#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
    filename = "#{team.id}_logo_#{unique}#{extension}"
    directory = team_directory(team.id)

    with :ok <- File.mkdir_p(directory),
         {:ok, binary} <- File.read(entry.path),
         :ok <- validate_image(binary),
         :ok <- File.cp(entry.path, Path.join(directory, filename)) do
      {:ok, filename}
    end
  end

  defp validate_image(binary) do
    if MediaValidator.valid_image?(binary), do: :ok, else: {:error, :invalid_image_format}
  end

  defp delete_file(_team, nil), do: :ok

  defp delete_file(team, filename) do
    UploadHandler.delete_file_safely(Path.join(team_directory(team.id), filename), %{
      team_id: team.id,
      operation: "team_logo_delete"
    })

    :ok
  end

  defp team_directory(team_id) do
    upload_directory = Application.get_env(:tymeslot, :upload_directory, "uploads")
    Path.join([upload_directory, @directory, Integer.to_string(team_id)])
  end
end
