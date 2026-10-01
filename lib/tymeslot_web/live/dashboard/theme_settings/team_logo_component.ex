defmodule TymeslotWeb.Dashboard.ThemeSettings.TeamLogoComponent do
  @moduledoc """
  Uploads or removes a team's logo, which the team page shows in place of
  its owner's photo. Works like the profile photo upload
  (`TymeslotWeb.Dashboard.ProfileSettings.AvatarUploadComponent`): the file
  uploads as soon as it is picked, under the same type and size limits and
  the same per-user rate limit.

  Required assigns: `team`, `current_user` (its owner) and `parent`, the
  component told of each change (`team_updated`).
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Teams
  alias TymeslotWeb.Helpers.UploadHandler

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # The component keeps the team it changed last; the parent's copy can be
    # older.
    assigns = if socket.assigns[:team], do: Map.delete(assigns, :team), else: assigns
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:uploads] && socket.assigns.uploads[:team_logo] do
        socket
      else
        allow_upload(socket, :team_logo,
          accept: Avatars.accepted_extensions(),
          max_entries: 1,
          max_file_size: Avatars.max_file_size(),
          auto_upload: true,
          progress: &handle_progress/3
        )
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate_logo", _params, socket), do: {:noreply, socket}

  def handle_event("upload_logo", _params, socket) do
    case UploadHandler.settle_upload(socket, :team_logo) do
      {socket, :settled} -> rate_limit_and_consume(socket)
      {socket, :in_progress} -> {:noreply, socket}
    end
  end

  def handle_event("remove_logo", _params, socket) do
    case Teams.remove_logo(socket.assigns.team.id, socket.assigns.current_user.id) do
      {:ok, team} ->
        Flash.info(dgettext("dashboard_teams", "Logo removed"))
        {:noreply, changed(socket, team)}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_teams", "The logo could not be removed."))
        {:noreply, socket}
    end
  end

  # `consume_uploaded_entries/3` raises while an entry is still in flight, so
  # both triggers go through `settle_upload/2` first, as for the profile photo.
  defp handle_progress(_config, entry, socket) do
    if entry.done? do
      case UploadHandler.settle_upload(socket, :team_logo) do
        {socket, :settled} -> rate_limit_and_consume(socket)
        {socket, :in_progress} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp rate_limit_and_consume(socket) do
    case RateLimiter.check_avatar_upload_rate_limit(socket.assigns.current_user.id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        {:noreply, consume(socket)}
    end
  end

  defp consume(socket) do
    %{team: team, current_user: user} = socket.assigns

    results =
      consume_uploaded_entries(socket, :team_logo, fn %{path: path}, entry ->
        # The temporary file is gone once this returns, so it is stored here.
        upload = %{path: path, client_name: entry.client_name, client_size: entry.client_size}
        {:ok, Teams.store_logo(team.id, user.id, upload)}
      end)

    case results do
      [{:ok, team}] ->
        Flash.info(dgettext("dashboard_teams", "Logo updated"))

        socket
        |> changed(team)
        |> push_event("upload-complete", %{})

      [{:error, reason}] ->
        Flash.error(error_message(reason))
        socket

      [] ->
        socket
    end
  end

  defp changed(socket, team) do
    send_update(socket.assigns.parent, team_updated: team)
    assign(socket, :team, team)
  end

  defp error_message(reason) when is_binary(reason), do: reason

  defp error_message(:invalid_image_format),
    do: dgettext("dashboard_teams", "This file is not a valid image.")

  defp error_message(_reason), do: dgettext("dashboard_teams", "The logo could not be saved.")

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-5" phx-hook="AutoUpload">
      <div class="w-20 h-20 rounded-token-2xl overflow-hidden bg-tymeslot-100 border-2 border-white shadow-lg shrink-0">
        <img
          src={Teams.logo_path(@team) || Profiles.avatar_url(@team.owner.profile, :thumb)}
          alt={@team.name}
          class="w-full h-full object-cover"
        />
      </div>

      <div class="space-y-2">
        <.section_header level={3} title={dgettext("dashboard_teams", "Team logo")} class="mb-0" />
        <p class="text-token-sm text-tymeslot-500 max-w-md">
          {dgettext(
            "dashboard_teams",
            "Shown on the team page in place of your photo. JPG, PNG, GIF or WebP, 10MB at most."
          )}
        </p>

        <form
          id={"#{@id}-form"}
          phx-submit="upload_logo"
          phx-change="validate_logo"
          phx-target={@myself}
          class="flex flex-wrap items-center gap-3"
        >
          <div class="relative">
            <.live_file_input
              upload={@uploads.team_logo}
              class="absolute inset-0 w-full h-full opacity-0 cursor-pointer z-20"
            />
            <span class="btn btn-secondary btn-sm">
              <.icon name="hero-arrow-up-tray" class="w-4 h-4 mr-2" />
              {if @uploads.team_logo.entries != [],
                do: dgettext("dashboard_teams", "Uploading..."),
                else: dgettext("dashboard_teams", "Upload a logo")}
            </span>
          </div>

          <button
            :if={@team.logo}
            type="button"
            id={"#{@id}-remove"}
            phx-click="remove_logo"
            phx-target={@myself}
            class="text-token-sm font-bold text-red-500 hover:text-red-700"
          >
            {dgettext("dashboard_teams", "Remove the logo")}
          </button>

          <button type="submit" class="hidden">{dgettext("dashboard_teams", "Upload")}</button>
        </form>

        <p
          :for={err <- upload_errors(@uploads.team_logo)}
          class="text-token-xs font-bold text-red-600"
        >
          {Phoenix.Naming.humanize(err)}
        </p>
        <%= for entry <- @uploads.team_logo.entries do %>
          <p
            :for={err <- upload_errors(@uploads.team_logo, entry)}
            class="text-token-xs font-bold text-red-600"
          >
            {Phoenix.Naming.humanize(err)}
          </p>
        <% end %>
      </div>
    </div>
    """
  end
end
