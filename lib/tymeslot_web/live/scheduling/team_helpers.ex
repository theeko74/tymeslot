defmodule TymeslotWeb.Live.Scheduling.TeamHelpers do
  @moduledoc """
  Resolves a team page, `/team/:team_slug[/:slug]`, into the socket state the
  booking flow reads.

  A team page is a booking page whose organiser is the team's owner: it
  borrows their profile, theme and username, so the flow's organiser-keyed
  machinery (theme context, preview token, cancel links, the ICS download)
  works unchanged. What differs is carried by the `:team` assign: which meeting
  types are offered (the team's, never the owner's own), which times
  (`Tymeslot.Availability.TeamOffer`), who the booking occupies, the page's
  paths, and the name shown in place of the organiser's.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Phoenix.PubSub
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Teams
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Shared.BookingText

  @doc """
  Loads the team at `slug` onto the socket, or raises a 404 for an unknown
  slug.
  """
  @spec handle_team_resolution(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_team_resolution(socket, slug) do
    case Teams.get_team_by_slug(slug) do
      %{} = team ->
        owner_profile = Teams.owner_profile(team)
        member_profiles = Teams.member_profiles(team)
        listed = Teams.public_meeting_types(team)

        socket
        |> OrganizerHelpers.handle_username_resolution(nil)
        |> assign(:team, team)
        |> assign(:team_member_profiles, member_profiles)
        |> assign(:organizer_profile, owner_profile && team_profile(owner_profile, team, listed))
        |> assign(:organizer_user_id, team.owner_user_id)
        |> assign(:username_context, owner_profile && owner_profile.username)
        |> assign(:meeting_types, listed)
        |> assign(:booking_window_days, booking_window_days(member_profiles, nil))
        |> assign(:page_title, dgettext("booking", "Schedule with %{name}", name: team.name))

      nil ->
        raise TymeslotWeb.NotFoundError, "No team found for #{inspect(slug)}"
    end
  end

  # The owner's profile as the team page shows it: the team's meeting types,
  # the team's theme (which falls back to the owner's), and the team's logo in
  # place of the owner's photo when it has one. An absolute path in `avatar` is
  # served as is (`Tymeslot.Profiles.Avatars.uploaded_avatar_path/1`), so every
  # place that shows the organiser's photo shows the logo.
  defp team_profile(owner_profile, team, listed) do
    %{
      owner_profile
      | meeting_types: listed,
        booking_theme: Teams.booking_theme(team),
        avatar: Teams.logo_path(team) || owner_profile.avatar
    }
  end

  @doc """
  The team's active meeting type at `slug`, private ones included (a private
  type is reachable by its direct link), or nil. Never one of the owner's own.
  """
  @spec find_meeting_type(map(), String.t() | nil) :: map() | nil
  def find_meeting_type(%{team: %{meeting_types: meeting_types}}, slug),
    do: MeetingTypes.find_team_type_by_slug(meeting_types, slug)

  def find_meeting_type(_assigns, _slug), do: nil

  # The team page's introductory lines mirror a personal page's
  # (`TymeslotWeb.Themes.Shared.BookingText`): the team's own wording when its
  # owner switched it on, built-in lines naming the team otherwise.

  @doc "The team page's heading: the team's own, or its name."
  @spec heading(map()) :: String.t()
  def heading(%{team: team}), do: custom(team, :booking_heading) || team.name

  @doc """
  The line under the heading: the team's own greeting, or by default the
  team's name followed by its members'.
  """
  @spec greeting(map()) :: String.t()
  def greeting(%{team: team} = assigns) do
    custom(team, :booking_greeting) || default_greeting(team, assigns[:team_member_profiles])
  end

  @doc """
  The built-in greeting, the team's name followed by its members', shown
  while the team's own wording is switched off.
  """
  @spec default_greeting(map(), [map()] | nil) :: String.t()
  def default_greeting(team, member_profiles) do
    members = Enum.map_join(member_profiles || [], ", ", &Profiles.display_name/1)
    dgettext("booking", "With %{team}: %{members}", team: team.name, members: members)
  end

  @doc """
  The line telling the visitor what to do: the team's own, else its
  description, else the built-in instruction.
  """
  @spec instruction(map()) :: String.t()
  def instruction(%{team: team}) do
    custom(team, :booking_instruction) || team.description || BookingText.default_instruction()
  end

  defp custom(%{booking_text_enabled: true} = team, field), do: Map.get(team, field)
  defp custom(_team, _field), do: nil

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

  @doc """
  The team page's path for a flow step. `slug` names the meeting type; without
  one, every step but the confirmation falls back to the team's overview.
  """
  @spec path(map(), :overview | :schedule | :booking | :confirmation, String.t() | nil) ::
          String.t()
  def path(team, action, slug \\ nil)
  def path(team, :confirmation, _slug), do: Teams.public_path(team) <> "/thank-you"
  def path(team, :schedule, slug) when is_binary(slug), do: Teams.public_path(team) <> "/#{slug}"

  def path(team, :booking, slug) when is_binary(slug),
    do: Teams.public_path(team) <> "/#{slug}/book"

  def path(team, _action, _slug), do: Teams.public_path(team)
end
