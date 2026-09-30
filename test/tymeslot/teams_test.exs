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
    test "creates the team, its owner membership and its settings meeting type" do
      owner = insert(:user)

      assert {:ok, team} =
               Teams.create_team(owner.id, %{name: "Sales Team", duration_minutes: 45})

      assert team.slug == "sales-team"
      assert [%{user_id: owner_id, role: :owner}] = team.members
      assert owner_id == owner.id

      assert %{
               team_id: team_id,
               user_id: mt_owner,
               duration_minutes: 45,
               name: "Sales Team",
               is_private: true,
               availability_schedule_id: nil
             } = team.meeting_type

      assert team_id == team.id
      assert mt_owner == owner.id
    end

    test "keeps an explicit slug, normalised" do
      owner = insert(:user)

      assert {:ok, team} =
               Teams.create_team(owner.id, %{name: "X", slug: " My-Team ", duration_minutes: 30})

      assert team.slug == "my-team"
    end

    test "refuses a slug already taken by another team" do
      owner = insert(:user)

      {:ok, _team} =
        Teams.create_team(owner.id, %{name: "One", slug: "shared", duration_minutes: 30})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Teams.create_team(insert(:user).id, %{
                 name: "Two",
                 slug: "shared",
                 duration_minutes: 30
               })

      assert %{slug: ["is already taken"]} = errors_on(changeset)
    end

    test "refuses reserved and malformed slugs" do
      owner = insert(:user)

      assert {:error, changeset} =
               Teams.create_team(owner.id, %{name: "X", slug: "book", duration_minutes: 30})

      assert %{slug: ["is reserved"]} = errors_on(changeset)

      assert {:error, changeset} =
               Teams.create_team(owner.id, %{name: "X", slug: "a_b", duration_minutes: 30})

      assert %{slug: [_format]} = errors_on(changeset)
    end

    test "reports a name clashing with one of the owner's meeting types" do
      owner = insert(:user)
      insert(:meeting_type, user: owner, name: "Discovery")

      assert {:error, :name_taken} =
               Teams.create_team(owner.id, %{name: "Discovery", duration_minutes: 30})
    end
  end

  describe "the settings meeting type" do
    test "is left out of the owner's own meeting type listings" do
      owner = insert(:user)
      personal = insert(:meeting_type, user: owner)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support", duration_minutes: 30})

      assert [%{id: id}] = MeetingTypes.get_all_meeting_types(owner.id)
      assert id == personal.id
      assert [%{id: ^id}] = MeetingTypes.get_active_meeting_types(owner.id)
      assert MeetingTypes.find_by_slug(owner.id, "support") == nil

      # ...but the submit, which reads it by id, still finds it.
      assert %{id: team_mt_id} = MeetingTypes.get_meeting_type(team.meeting_type.id, owner.id)
      assert team_mt_id == team.meeting_type.id
    end

    test "follows the team's name and duration" do
      owner = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support", duration_minutes: 30})

      assert {:ok, team} =
               Teams.update_team(team.id, owner.id, %{name: "Helpdesk", duration_minutes: 90})

      assert %{name: "Helpdesk", duration_minutes: 90} = team.meeting_type
    end

    test "goes with the team" do
      owner = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support", duration_minutes: 30})
      mt_id = team.meeting_type.id

      assert :ok = Teams.delete_team(team.id, owner.id)
      assert MeetingTypes.get_meeting_type(mt_id, owner.id) == nil
    end
  end

  describe "membership" do
    test "adds an existing account by email and emails them" do
      owner = insert(:user)
      member = insert(:user, email: "colleague@example.com")
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support", duration_minutes: 30})

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
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support", duration_minutes: 30})

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
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support", duration_minutes: 30})
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
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support", duration_minutes: 30})
      {:ok, _team} = Teams.add_member_by_email(team.id, owner.id, member.email)

      assert {:error, :owner_cannot_leave} = Teams.leave_team(team.id, owner.id)
      assert {:error, :owner_cannot_leave} = Teams.remove_member(team.id, owner.id, owner.id)
      assert :ok = Teams.leave_team(team.id, member.id)
      assert Teams.list_teams_for_user(member.id) == []
    end

    test "lists the teams a user owns or belongs to, and no others" do
      owner = insert(:user)
      member = insert(:user)
      {:ok, team} = Teams.create_team(owner.id, %{name: "Support", duration_minutes: 30})
      {:ok, _other} = Teams.create_team(insert(:user).id, %{name: "Other", duration_minutes: 30})
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
