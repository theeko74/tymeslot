defmodule TymeslotWeb.Live.Scheduling.TeamBookingFlowTest do
  @moduledoc """
  The public team page, `/team/:slug`: it opens on the schedule step pinned to
  the team's settings, names the team rather than its owner, and a booking made
  there is one meeting shared by every member.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :teams
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.TeamTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.CoHostQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Teams
  alias Tymeslot.TestMocks

  @calendar_day "button[data-testid='calendar-day']"
  @time_slot "button[data-testid='time-slot']"
  @next_step "button[data-testid='next-step']"
  @next_month "button[phx-click='next_month']"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    open_day = %{is_available: true, start_time: ~T[00:00:00], end_time: ~T[23:59:00]}

    %{team: team, members: members} =
      create_team_with_members(2,
        members: [
          [timezone: "Etc/UTC", days: Enum.to_list(1..7), hours: open_day],
          [timezone: "Etc/UTC", days: Enum.to_list(1..7), hours: open_day]
        ],
        team: [name: "Product Team", slug: "product-team"],
        meeting_type: [name: "Quick call", slug: "quick-call", duration_minutes: 30]
      )

    # One of the owner's own types, which the team page must never offer.
    [owner | _rest] = members
    insert(:meeting_type, user: owner.user, name: "Owner's own chat")

    %{team: team, members: members}
  end

  defp walk_to_booking_form(view) do
    wait_until(fn -> has_element?(view, @calendar_day) end)
    target_date = Date.add(Date.utc_today(), 2)

    if has_element?(view, @next_month) do
      BookingTestHelpers.show_month(view, target_date, :next)
    end

    day = "#{@calendar_day}[phx-value-date='#{Date.to_string(target_date)}']"
    wait_until(fn -> has_element?(view, "#{day}:not([disabled])") end)
    view |> element(day) |> render_click()

    wait_until(fn -> has_element?(view, @time_slot) end)

    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute(@time_slot, "phx-value-time")
      |> List.first()

    view |> element("#{@time_slot}[phx-value-time='#{slot}']") |> render_click()
    view |> element(@next_step) |> render_click()
    view
  end

  test "lists the team's meeting types, never the owner's own, under the team's name",
       %{conn: conn, members: [owner, member]} do
    {:ok, view, html} = live(conn, "/team/product-team?timezone=Etc/UTC")

    assert html =~ "Product Team"
    assert has_element?(view, "button[data-testid='duration-option']", "Quick call")
    refute html =~ "Owner&#39;s own chat"

    # The default greeting names the team's members.
    assert html =~ Profiles.display_name(owner.profile)
    assert html =~ Profiles.display_name(member.profile)
  end

  test "shows the team's own wording when it has some", %{conn: conn, team: team} do
    {:ok, _team} =
      Teams.update_booking_text(team.id, team.owner_user_id, %{
        "booking_text_enabled" => true,
        "booking_heading" => "Meet the product folks",
        "booking_greeting" => "Talk to the product folks",
        "booking_instruction" => "Choose a format"
      })

    {:ok, _view, html} = live(conn, "/team/product-team?timezone=Etc/UTC")

    assert html =~ "Meet the product folks"
    assert html =~ "Talk to the product folks"
    assert html =~ "Choose a format"
  end

  test "shows the team's logo in place of the owner's photo", %{conn: conn, team: team} do
    team |> Changeset.change(logo: "logo.png") |> Repo.update!()

    {:ok, _view, html} = live(conn, "/team/product-team?timezone=Etc/UTC")

    assert html =~ "/uploads/team_logos/#{team.id}/logo.png"
  end

  test "a meeting type's link opens its calendar directly", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/team/product-team/quick-call?timezone=Etc/UTC")

    wait_until(fn -> has_element?(view, @calendar_day) end)
  end

  test "an unknown meeting type link returns to the team's page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/team/product-team"}}} =
             live(conn, "/team/product-team/no-such-type")
  end

  test "an unknown team is a 404", %{conn: conn} do
    assert_raise TymeslotWeb.NotFoundError, fn -> live(conn, "/team/no-such-team") end
  end

  test "is unavailable while a member has no calendar", %{conn: conn, team: team} do
    no_calendar = insert(:profile).user
    {:ok, _team} = Teams.add_member_by_email(team.id, team.owner_user_id, no_calendar.email)

    {:ok, _view, html} = live(conn, "/team/product-team")

    assert html =~ "A team member hasn"
  end

  @tag :capture_log
  test "a booking is one meeting shared by every member", %{
    conn: conn,
    team: team,
    members: [owner, member]
  } do
    {:ok, view, _html} = live(conn, "/team/product-team/quick-call?timezone=Etc/UTC")
    view = walk_to_booking_form(view)

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => "Visitor", "email" => "visitor@example.com", "message" => ""}
    })
    |> render_submit()

    _drain = :sys.get_state(view.pid)

    assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "visitor@example.com")
    assert meeting.team_id == team.id
    assert meeting.meeting_type_id == hd(team.meeting_types).id
    assert meeting.organizer_user_id == owner.user.id
    assert CoHostQueries.user_ids_for_meeting(meeting.id) == [member.user.id]
    assert render(view) =~ "Product Team"
  end

  test "switching language keeps the team page and its meeting type", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/team/product-team/quick-call?timezone=Etc/UTC")

    assert {:error, {:redirect, %{to: to}}} =
             render_hook(view, "change_locale", %{"locale" => "fr"})

    assert to =~ "/team/product-team/quick-call"
  end
end
