defmodule TymeslotWeb.Live.Scheduling.TeamHelpers do
  @moduledoc """
  Resolves a team page, `/team/:team_slug`, into the socket state the booking
  flow reads.

  A team page is a booking page whose organiser is the team's owner: it
  borrows their profile, theme and username, so the flow's organiser-keyed
  machinery (theme context, preview token, cancel links, the ICS download)
  works unchanged. What differs is carried by the `:team` assign: which times
  are offered (`Tymeslot.Availability.TeamOffer`), who the booking occupies,
  the page's paths, and the name shown in place of the organiser's.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Phoenix.PubSub
  alias Tymeslot.Teams
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Shared.ReschedulePin

  @doc """
  Loads the team at `slug` onto the socket, or raises a 404 for an unknown
  slug.
  """
  @spec handle_team_resolution(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_team_resolution(socket, slug) do
    case Teams.get_team_by_slug(slug) do
      %{meeting_type: %{} = meeting_type} = team ->
        owner_profile = Teams.owner_profile(team)
        member_profiles = Teams.member_profiles(team)

        socket
        |> OrganizerHelpers.handle_username_resolution(nil)
        |> assign(:team, team)
        |> assign(:team_member_profiles, member_profiles)
        |> assign(
          :organizer_profile,
          owner_profile && %{owner_profile | meeting_types: [meeting_type]}
        )
        |> assign(:organizer_user_id, team.owner_user_id)
        |> assign(:username_context, owner_profile && owner_profile.username)
        |> assign(:meeting_types, [meeting_type])
        |> assign(:booking_window_days, booking_window_days(member_profiles, meeting_type))
        |> assign(:page_title, dgettext("booking", "Schedule with %{name}", name: team.name))

      _unknown ->
        raise TymeslotWeb.NotFoundError, "No team found for #{inspect(slug)}"
    end
  end

  @doc """
  How far ahead the team page may book: the shortest window among members,
  since a time past any member's window is one that member cannot be booked for.
  """
  @spec booking_window_days([map()], map() | nil) :: pos_integer()
  def booking_window_days([], meeting_type),
    do: OrganizerHelpers.booking_window_days(nil, meeting_type)

  def booking_window_days(member_profiles, meeting_type) do
    member_profiles
    |> Enum.map(&OrganizerHelpers.booking_window_days(&1, meeting_type))
    |> Enum.min()
  end

  @doc """
  Pins a team page to its settings meeting type, as a reschedule is pinned to
  its meeting's type (`TymeslotWeb.Themes.Shared.ReschedulePin`): it is the only
  type offered, and it arrives selected. `assign_meeting_type` is the flow's
  own assigner, so the type's questions, location and booking window follow.
  A socket without a team is returned as is.
  """
  @spec pin_meeting_type(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t(), map() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def pin_meeting_type(
        %{assigns: %{team: %{meeting_type: %{} = meeting_type}}} = socket,
        assign_meeting_type
      ) do
    socket
    |> assign_meeting_type.(meeting_type)
    |> ReschedulePin.pin(meeting_type)
  end

  def pin_meeting_type(socket, _assign_meeting_type), do: socket

  @doc """
  Subscribes the connected page to calendar updates for everyone whose
  calendar decides what it offers: every member on a team page, the organiser
  otherwise. Once per socket.
  """
  @spec subscribe_to_host_calendars(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def subscribe_to_host_calendars(socket) do
    host_user_ids = host_user_ids(socket.assigns)

    if connected?(socket) && host_user_ids != [] &&
         !socket.assigns[:calendar_pubsub_subscribed] do
      Enum.each(host_user_ids, &PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{&1}"))
      assign(socket, :calendar_pubsub_subscribed, true)
    else
      socket
    end
  end

  defp host_user_ids(%{team: %{}, team_member_profiles: profiles}),
    do: Enum.map(profiles, & &1.user_id)

  defp host_user_ids(%{organizer_user_id: id}) when is_integer(id), do: [id]
  defp host_user_ids(_assigns), do: []

  @doc "The team page's path for a flow step."
  @spec path(map(), :schedule | :booking | :confirmation) :: String.t()
  def path(team, :schedule), do: Teams.public_path(team)
  def path(team, :booking), do: Teams.public_path(team) <> "/book"
  def path(team, :confirmation), do: Teams.public_path(team) <> "/thank-you"
end
