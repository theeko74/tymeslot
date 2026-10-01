defmodule Tymeslot.TeamsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :teams
  @moduletag :unit

  import Tymeslot.TeamTestHelpers

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Teams
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  describe "create_team/2" do
    test "creates the team and its owner membership, offering nothing yet" do
      owner = insert(:user)

      assert {:ok, team} = Teams.create_team(owner.id, %{name: "Sales Team"})

      assert team.slug == "sales-team"
      assert team.booking_text_enabled == false
      assert [%{user_id: owner_id, role: :owner}] = team.members
      assert owner_id == owner.id
      assert team.meeting_types == []
    end

    test "keeps an explicit slug, normalised" do
      owner = insert(:user)

      assert {:ok, team} = Teams.create_team(owner.id, %{name: "X", slug: " My-Team "})

      assert team.slug == "my-team"
    end

    test "refuses a slug already taken by another team" do
      owner = insert(:user)
      {:ok, _team} = Teams.create_team(owner.id, %{name: "One", slug: "shared"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Teams.create_team(insert(:user).id, %{name: "Two", slug: "shared"})

      assert %{slug: ["is already taken"]} = errors_on(changeset)
    end

    test "refuses reserved and malformed slugs" do
      owner = insert(:user)

      assert {:error, changeset} =
               Teams.create_team(owner.id, %{name: "X", slug: "thank-you"})

      assert %{slug: ["is reserved"]} = errors_on(changeset)

      assert {:error, changeset} = Teams.create_team(owner.id, %{name: "X", slug: "a_b"})
      assert %{slug: [_format]} = errors_on(changeset)
    end

    test "update_team/3 changes the name and description" do
      owner = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support"})

      assert {:ok, team} =
               Teams.update_team(team.id, owner.id, %{name: "Helpdesk", description: "We help"})

      assert %{name: "Helpdesk", description: "We help"} = team
    end
  end

  describe "update_booking_text/3" do
    setup do
      owner = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support"})
      %{owner: owner, team: team}
    end

    test "sets the team page's wording, trimmed", %{owner: owner, team: team} do
      assert {:ok, team} =
               Teams.update_booking_text(team.id, owner.id, %{
                 "booking_text_enabled" => true,
                 "booking_heading" => " Support ",
                 "booking_greeting" => "We answer fast",
                 "booking_instruction" => "Pick a slot"
               })

      assert %{
               booking_text_enabled: true,
               booking_heading: "Support",
               booking_greeting: "We answer fast",
               booking_instruction: "Pick a slot"
             } = team
    end

    test "requires the three lines while switched on", %{owner: owner, team: team} do
      assert {:error, changeset} =
               Teams.update_booking_text(team.id, owner.id, %{
                 "booking_text_enabled" => true,
                 "booking_heading" => "Support"
               })

      assert %{booking_greeting: [_required], booking_instruction: [_also]} = errors_on(changeset)
    end

    test "is the owner's alone", %{team: team} do
      assert {:error, :not_found} =
               Teams.update_booking_text(team.id, insert(:user).id, %{
                 "booking_text_enabled" => false
               })
    end
  end

  describe "team logo" do
    setup do
      owner = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support"})

      # Source files for the uploads; the logos land in the configured upload
      # directory, under the team's own id, removed afterwards.
      source = Path.join(System.tmp_dir!(), "team_logo_#{System.unique_integer([:positive])}")
      File.mkdir_p!(source)
      dir = Application.fetch_env!(:tymeslot, :upload_directory)

      on_exit(fn ->
        File.rm_rf(source)
        File.rm_rf(Path.join([dir, "team_logos", to_string(team.id)]))
      end)

      %{owner: owner, team: team, directory: dir, source: source}
    end

    # The smallest valid PNG: a one-pixel image.
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
         )

    test "stores, replaces and removes a logo",
         %{owner: owner, team: team, directory: dir, source: source} do
      upload = Path.join(source, "upload.png")
      File.write!(upload, @png)
      entry = %{path: upload, client_name: "logo.png", client_size: byte_size(@png)}

      assert {:ok, %{logo: first} = team} = Teams.store_logo(team.id, owner.id, entry)
      assert Teams.logo_path(team) == "/uploads/team_logos/#{team.id}/#{first}"
      assert File.exists?(Path.join([dir, "team_logos", to_string(team.id), first]))

      assert {:ok, %{logo: second}} = Teams.store_logo(team.id, owner.id, entry)
      refute second == first
      refute File.exists?(Path.join([dir, "team_logos", to_string(team.id), first]))

      assert {:ok, %{logo: nil} = team} = Teams.remove_logo(team.id, owner.id)
      assert Teams.logo_path(team) == nil
      refute File.exists?(Path.join([dir, "team_logos", to_string(team.id), second]))
    end

    test "refuses a file that is not an image", %{owner: owner, team: team, source: source} do
      upload = Path.join(source, "fake.png")
      File.write!(upload, "not an image")
      entry = %{path: upload, client_name: "fake.png", client_size: 12}

      assert {:error, :invalid_image_format} = Teams.store_logo(team.id, owner.id, entry)
    end

    test "is the owner's alone", %{team: team, source: source} do
      upload = Path.join(source, "upload.png")
      File.write!(upload, @png)
      entry = %{path: upload, client_name: "logo.png", client_size: byte_size(@png)}

      assert {:error, :not_found} = Teams.store_logo(team.id, insert(:user).id, entry)
    end
  end

  describe "team meeting types" do
    setup do
      owner = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support"})
      %{owner: owner, team: team}
    end

    # A team meeting type of `owner`, offered on `team` (pass nil to offer it
    # nowhere).
    defp team_type(owner, team, attrs \\ %{}) do
      {:ok, type} =
        MeetingTypes.create_meeting_type(
          Map.merge(
            %{name: "30 minutes", duration_minutes: 30, user_id: owner.id, is_team_type: true},
            attrs
          )
        )

      if team, do: {:ok, _team} = Teams.offer_meeting_type(team.id, owner.id, type.id)
      {:ok, type}
    end

    test "each team orders its meeting types, a newly offered one last", %{owner: owner} do
      {:ok, first} = Teams.create_team(owner.id, %{name: "First"})
      {:ok, second} = Teams.create_team(owner.id, %{name: "Second"})
      {:ok, a} = team_type(owner, first, %{name: "A"})
      {:ok, b} = team_type(owner, first, %{name: "B"})
      {:ok, _team} = Teams.offer_meeting_type(second.id, owner.id, a.id)
      {:ok, _team} = Teams.offer_meeting_type(second.id, owner.id, b.id)

      assert {:ok, first} = Teams.reorder_meeting_types(first.id, owner.id, [b.id, a.id])
      assert Enum.map(first.meeting_types, & &1.name) == ["B", "A"]
      # The same types keep their own order on the other team.
      assert Enum.map(Teams.get_team_for_booking(second.id).meeting_types, & &1.name) ==
               ["A", "B"]

      {:ok, c} = team_type(owner, first, %{name: "C"})

      assert Enum.map(Teams.get_team_for_booking(first.id).meeting_types, & &1.id) ==
               [b.id, a.id, c.id]

      assert {:error, :not_found} =
               Teams.reorder_meeting_types(first.id, insert(:user).id, [a.id, b.id])
    end

    test "may share a name with one of the owner's own types, not with another team type",
         %{owner: owner} do
      insert(:meeting_type, user: owner, name: "30 minutes")

      assert {:ok, _type} = team_type(owner, nil)

      assert {:error, changeset} =
               MeetingTypes.create_meeting_type(%{
                 name: "30 minutes",
                 duration_minutes: 30,
                 user_id: owner.id,
                 is_team_type: true
               })

      assert %{user_id: [_taken]} = errors_on(changeset)
    end

    test "names no schedule and cannot be paid", %{owner: owner} do
      schedule = insert(:availability_schedule, profile: insert(:profile, user: owner))

      assert {:ok, type} =
               team_type(owner, nil, %{
                 availability_schedule_id: schedule.id,
                 payment_required: true,
                 price_cents: 5000
               })

      assert %{availability_schedule_id: nil, payment_required: false, price_cents: nil} = type
    end

    test "one type is offered by several teams", %{owner: owner, team: team} do
      {:ok, other} = Teams.create_team(owner.id, %{name: "Truc"})
      {:ok, type} = team_type(owner, team)
      {:ok, _other} = Teams.offer_meeting_type(other.id, owner.id, type.id)

      for team_id <- [team.id, other.id] do
        assert [%{id: id}] = Teams.get_team_for_booking(team_id).meeting_types
        assert id == type.id
      end

      assert [%{teams: offering}] = MeetingTypes.list_user_team_meeting_types(owner.id)
      assert offering |> Enum.map(& &1.name) |> Enum.sort() == ["Support", "Truc"]
    end

    test "withdrawing a type from a team keeps it, and the other teams offering it",
         %{owner: owner, team: team} do
      {:ok, other} = Teams.create_team(owner.id, %{name: "Truc"})
      {:ok, type} = team_type(owner, team)
      {:ok, _other} = Teams.offer_meeting_type(other.id, owner.id, type.id)

      assert {:ok, %{meeting_types: []}} = Teams.withdraw_meeting_type(team.id, owner.id, type.id)
      assert [_offered] = Teams.get_team_for_booking(other.id).meeting_types
      assert MeetingTypes.get_meeting_type(type.id, owner.id)
    end

    test "a team offers only its owner's team types", %{owner: owner, team: team} do
      personal = insert(:meeting_type, user: owner)
      {:ok, someone_elses} = team_type(insert(:user), nil)

      assert {:error, :not_found} = Teams.offer_meeting_type(team.id, owner.id, personal.id)
      assert {:error, :not_found} = Teams.offer_meeting_type(team.id, owner.id, someone_elses.id)
    end

    test "only the owner chooses what a team offers", %{owner: owner, team: team} do
      member = insert(:user)
      {:ok, _team} = Teams.add_member_by_email(team.id, owner.id, member.email)
      {:ok, type} = team_type(owner, nil)

      assert {:error, :not_found} = Teams.offer_meeting_type(team.id, member.id, type.id)
    end

    test "are left out of the owner's own listings, and found by id and by team slug",
         %{owner: owner, team: team} do
      personal = insert(:meeting_type, user: owner)
      {:ok, type} = team_type(owner, team, %{slug: "quick"})

      assert [%{id: id}] = MeetingTypes.get_all_meeting_types(owner.id)
      assert id == personal.id
      assert MeetingTypes.find_by_slug(owner.id, "quick") == nil

      # The submit and the dashboard editor read a type by id.
      assert %{id: type_id} = MeetingTypes.get_meeting_type(type.id, owner.id)
      assert type_id == type.id

      team = Teams.get_team_for_booking(team.id)
      assert %{id: ^type_id} = MeetingTypes.find_team_type_by_slug(team.meeting_types, "quick")
    end

    test "private and inactive ones are not listed on the team page", %{owner: owner, team: team} do
      {:ok, listed} = team_type(owner, team)
      {:ok, _private} = team_type(owner, team, %{name: "Private", is_private: true})
      {:ok, _inactive} = team_type(owner, team, %{name: "Off", is_active: false})

      assert [%{id: id}] = team.id |> Teams.get_team_for_booking() |> Teams.public_meeting_types()
      assert id == listed.id
    end

    test "outlive the teams offering them", %{owner: owner, team: team} do
      {:ok, type} = team_type(owner, team)

      assert :ok = Teams.delete_team(team.id, owner.id)
      assert MeetingTypes.get_meeting_type(type.id, owner.id)
    end
  end

  describe "membership" do
    test "adds an existing account by email and emails them" do
      owner = insert(:user)
      member = insert(:user, email: "colleague@example.com")
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support"})

      assert {:ok, team} = Teams.add_member_by_email(team.id, owner.id, " Colleague@Example.com ")
      assert Enum.map(team.members, & &1.user_id) == [owner.id, member.id]

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_team_member_added",
          "team_id" => team.id,
          "user_id" => member.id
        }
      )
    end

    test "refuses an unknown email, the owner, and a second add" do
      owner = insert(:user)
      member = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support"})

      assert {:error, :unknown_account} =
               Teams.add_member_by_email(team.id, owner.id, "nobody@example.com")

      assert {:error, :self} = Teams.add_member_by_email(team.id, owner.id, owner.email)
      assert {:ok, _team} = Teams.add_member_by_email(team.id, owner.id, member.email)

      assert {:error, :already_member} =
               Teams.add_member_by_email(team.id, owner.id, member.email)
    end

    test "only the owner manages the team" do
      owner = insert(:user)
      member = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support"})
      {:ok, _team} = Teams.add_member_by_email(team.id, owner.id, member.email)

      assert {:error, :not_found} =
               Teams.add_member_by_email(team.id, member.id, insert(:user).email)

      assert {:error, :not_found} = Teams.update_team(team.id, member.id, %{name: "Mine"})
      assert {:error, :not_found} = Teams.delete_team(team.id, member.id)
      assert {:error, :not_found} = Teams.remove_member(team.id, member.id, owner.id)
    end

    test "a member can leave; the owner cannot leave or be removed" do
      owner = insert(:user)
      member = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support"})
      {:ok, _team} = Teams.add_member_by_email(team.id, owner.id, member.email)

      assert {:error, :owner_cannot_leave} = Teams.leave_team(team.id, owner.id)
      assert {:error, :owner_cannot_leave} = Teams.remove_member(team.id, owner.id, owner.id)
      assert :ok = Teams.leave_team(team.id, member.id)
      assert Teams.list_teams_for_user(member.id) == []
    end

    test "lists the teams a user owns or belongs to, and no others" do
      owner = insert(:user)
      member = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support"})
      {:ok, _other} = Teams.create_team(insert(:user).id, %{name: "Other"})
      {:ok, _team} = Teams.add_member_by_email(team.id, owner.id, member.email)

      assert [%{id: id}] = Teams.list_teams_for_user(member.id)
      assert id == team.id
      assert [%{id: ^id}] = Teams.list_teams_for_user(owner.id)
    end
  end

  describe "public_readiness/1" do
    test "is ready when every member has a calendar" do
      %{team: team} = create_team_with_members(2)
      assert :ok = Teams.public_readiness(team)
    end

    test "is not ready while a member has no calendar" do
      %{team: team, members: [owner | _rest]} = create_team_with_members(1)
      no_calendar = insert(:profile).user
      {:ok, team} = Teams.add_member_by_email(team.id, owner.user.id, no_calendar.email)

      assert {:error, :team_member_not_ready} = Teams.public_readiness(team)
    end
  end
end
