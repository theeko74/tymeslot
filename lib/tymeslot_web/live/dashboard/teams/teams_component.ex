defmodule TymeslotWeb.Dashboard.Teams.TeamsComponent do
  @moduledoc """
  Dashboard section for teams.

  A team is booked through one public page, `/team/:slug`, which offers only
  the times every member is free. This component lists the teams the user owns
  or belongs to, creates and edits teams, and manages their members: the owner
  adds registered users by email and removes them; a member can leave. The
  rules live in `Tymeslot.Teams`; this module only maps them onto the page.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Teams
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Dashboard.MeetingSettings.Card
  alias TymeslotWeb.Dashboard.Teams.DeleteTeamModal
  alias TymeslotWeb.Live.Shared.Flash

  @empty_form %{"name" => "", "slug" => "", "description" => ""}

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form_mode, fn -> nil end)
     |> assign_new(:form, fn -> @empty_form end)
     |> assign_new(:slug_touched, fn -> false end)
     |> assign_new(:errors, fn -> %{} end)
     |> assign_new(:selected_team_id, fn -> nil end)
     |> assign_new(:member_email, fn -> "" end)
     |> assign_new(:member_error, fn -> nil end)
     |> assign_new(:show_delete_modal, fn -> false end)
     |> load_teams()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <.section_header
        icon="hero-user-group"
        title={dgettext("dashboard_teams", "Teams")}
        class="mb-4"
      />

      <p class="text-tymeslot-600 mb-6">
        {dgettext(
          "dashboard_teams",
          "Book meetings with several people at once. A team page only offers the times when every member is free."
        )}
      </p>

      <div id="teams-container" class="space-y-6">
        <div :if={is_nil(@form_mode)} class="flex justify-end">
          <button
            type="button"
            phx-click="new_team"
            phx-target={@myself}
            class="btn btn-primary inline-flex items-center gap-1"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {dgettext("dashboard_teams", "New team")}
          </button>
        </div>

        <.team_form
          :if={@form_mode}
          form={@form}
          errors={@errors}
          mode={@form_mode}
          myself={@myself}
        />

        <.team_detail
          :if={@selected_team}
          team={@selected_team}
          current_user={@current_user}
          member_email={@member_email}
          member_error={@member_error}
          team_types={@team_types}
          myself={@myself}
        />

        <div :if={@teams == []} class="card-glass py-10 px-6 text-center text-tymeslot-600">
          {dgettext(
            "dashboard_teams",
            "You are not in any team yet. Create one and add colleagues who have a Tymeslot account."
          )}
        </div>

        <div :if={@teams != []} class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.team_card
            :for={team <- @teams}
            team={team}
            current_user={@current_user}
            selected={team.id == @selected_team_id}
            myself={@myself}
          />
        </div>

        <DeleteTeamModal.delete_team_modal
          open={@show_delete_modal}
          team={@selected_team}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  # --- Components ------------------------------------------------------------

  attr :form, :map, required: true
  attr :errors, :map, required: true
  attr :mode, :atom, required: true
  attr :myself, :any, required: true

  defp team_form(assigns) do
    ~H"""
    <div id="team-form" class="card-glass py-6 px-6 space-y-6">
      <.section_header
        level={3}
        icon="hero-plus-circle"
        title={
          if @mode == :edit,
            do: dgettext("dashboard_teams", "Edit team"),
            else: dgettext("dashboard_teams", "New team")
        }
      />

      <form
        id="team-edit-form"
        phx-submit="save_team"
        phx-change="form_change"
        phx-target={@myself}
        class="space-y-4"
      >
        <.input
          name="team[name]"
          label={dgettext("dashboard_teams", "Team name")}
          value={@form["name"]}
          required
          placeholder={dgettext("dashboard_teams", "e.g., Sales team")}
          errors={Map.get(@errors, :name, [])}
          icon="hero-user-group"
        />

        <.input
          name="team[slug]"
          label={dgettext("dashboard_teams", "Page address")}
          value={@form["slug"]}
          required
          errors={Map.get(@errors, :slug, [])}
          icon="hero-link"
        />
        <p class="text-token-sm text-tymeslot-600 -mt-2">
          {UrlBuilder.base_url()}{Teams.public_path(@form["slug"] || "")}
        </p>

        <.input
          type="textarea"
          name="team[description]"
          label={dgettext("dashboard_teams", "Description (optional)")}
          value={@form["description"]}
          errors={Map.get(@errors, :description, [])}
        />

        <p class="text-token-sm text-tymeslot-600">
          {dgettext(
            "dashboard_teams",
            "The team page's wording, logo and style are set in the Theme tab."
          )}
        </p>

        <div class="flex justify-end gap-3">
          <button type="button" phx-click="cancel_form" phx-target={@myself} class="btn btn-secondary">
            {dgettext("dashboard_teams", "Cancel")}
          </button>
          <button type="submit" class="btn btn-primary">
            {dgettext("dashboard_teams", "Save team")}
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :team, :map, required: true
  attr :current_user, :any, required: true
  attr :selected, :boolean, required: true
  attr :myself, :any, required: true

  defp team_card(assigns) do
    ~H"""
    <div
      id={"team-card-#{@team.id}"}
      class={["card-glass py-5 px-5 space-y-3", @selected && "ring-2 ring-turquoise-400"]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="font-bold text-tymeslot-900 truncate">{@team.name}</h3>
          <p class="text-token-sm text-tymeslot-600">
            {dngettext(
              "dashboard_teams",
              "%{count} member",
              "%{count} members",
              length(@team.members)
            )} · {dngettext(
              "dashboard_teams",
              "%{count} meeting type",
              "%{count} meeting types",
              length(@team.meeting_types)
            )}
          </p>
        </div>
        <span class="text-token-xs font-semibold px-2 py-1 rounded-full bg-tymeslot-100 text-tymeslot-700">
          {if Teams.owner?(@team, @current_user.id),
            do: dgettext("dashboard_teams", "Owner"),
            else: dgettext("dashboard_teams", "Member")}
        </span>
      </div>

      <div class="flex items-center gap-2">
        <code class="text-token-xs text-tymeslot-700 truncate flex-1">{public_url(@team)}</code>
        <button
          id={"copy-team-link-#{@team.id}"}
          type="button"
          phx-hook="CopyOnClick"
          data-copy-text={public_url(@team)}
          data-copy-feedback={dgettext("dashboard_teams", "Team link copied to clipboard!")}
          class="p-2 rounded-lg bg-white border-2 border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-400"
          title={dgettext("dashboard_teams", "Copy team link")}
        >
          <.icon name="hero-clipboard" class="w-4 h-4" />
        </button>
      </div>

      <button
        type="button"
        phx-click="select_team"
        phx-value-id={@team.id}
        phx-target={@myself}
        class="btn btn-secondary w-full"
      >
        {dgettext("dashboard_teams", "Manage")}
      </button>
    </div>
    """
  end

  attr :team, :map, required: true
  attr :current_user, :any, required: true
  attr :member_email, :string, required: true
  attr :member_error, :string, default: nil
  attr :team_types, :list, required: true
  attr :myself, :any, required: true

  defp team_detail(assigns) do
    assigns = assign(assigns, :owner?, Teams.owner?(assigns.team, assigns.current_user.id))

    ~H"""
    <div id="team-detail" class="card-glass py-6 px-6 space-y-6">
      <div class="flex items-start justify-between gap-3 flex-wrap">
        <.section_header level={3} icon="hero-user-group" title={@team.name} />
        <div class="flex gap-2">
          <button
            :if={@owner?}
            type="button"
            phx-click="edit_team"
            phx-target={@myself}
            class="btn btn-secondary"
          >
            {dgettext("dashboard_teams", "Edit")}
          </button>
          <button
            :if={@owner?}
            type="button"
            phx-click="request_delete"
            phx-target={@myself}
            class="btn btn-danger"
          >
            {dgettext("dashboard_teams", "Delete")}
          </button>
          <button
            :if={!@owner?}
            type="button"
            phx-click="leave_team"
            phx-target={@myself}
            class="btn btn-danger"
          >
            {dgettext("dashboard_teams", "Leave team")}
          </button>
          <button
            type="button"
            phx-click="deselect_team"
            phx-target={@myself}
            class="btn btn-secondary"
          >
            {dgettext("dashboard_teams", "Close")}
          </button>
        </div>
      </div>

      <p :if={@team.description} class="text-tymeslot-600">{@team.description}</p>

      <div id="team-offered-types" class="rounded-token-xl bg-tymeslot-50 px-4 py-3 space-y-3">
        <div class="flex items-center justify-between gap-3 flex-wrap">
          <p class="text-token-sm text-tymeslot-700">
            {dngettext(
              "dashboard_teams",
              "This team offers %{count} meeting type.",
              "This team offers %{count} meeting types.",
              length(@team.meeting_types)
            )}
          </p>
          <.link
            :if={@owner?}
            navigate={~p"/dashboard/meeting-settings"}
            class="btn btn-secondary btn-sm"
          >
            {dgettext("dashboard_teams", "Manage meeting types")}
          </.link>
        </div>

        <%!-- The owner picks which of their team meeting types this team
             offers, on the same cards as the meeting settings, and drags the
             offered ones into the order the team page lists them in. --%>
        <div
          :if={@owner? && @team.meeting_types != []}
          id="team-offered-sortable-list"
          phx-hook="MeetingTypeSortable"
          data-target={@myself}
          phx-target={@myself}
          class="flex flex-col space-y-2"
        >
          <div
            :for={type <- @team.meeting_types}
            draggable="true"
            data-meeting-type-id={type.id}
            class="cursor-move"
          >
            <Card.meeting_type_card type={type} myself={@myself} variant={:offer} offered />
          </div>
        </div>

        <div :if={@owner? && not_offered(@team, @team_types) != []} class="space-y-2">
          <p class="text-token-xs font-bold uppercase tracking-wider text-tymeslot-500 pt-2">
            {dgettext("dashboard_teams", "Not offered by this team")}
          </p>
          <Card.meeting_type_card
            :for={type <- not_offered(@team, @team_types)}
            type={type}
            myself={@myself}
            variant={:offer}
            offered={false}
            sortable={false}
          />
        </div>

        <p :if={@owner? && @team_types == []} class="text-token-sm text-tymeslot-600">
          {dgettext(
            "dashboard_teams",
            "You have no team meeting type yet. Create one in the meeting settings, then offer it here."
          )}
        </p>

        <ul :if={!@owner? && @team.meeting_types != []} class="space-y-1">
          <li :for={type <- @team.meeting_types} class="text-tymeslot-800">{type.name}</li>
        </ul>
      </div>

      <ul class="divide-y divide-tymeslot-100">
        <li :for={member <- @team.members} class="py-3 flex items-center justify-between gap-3">
          <div class="min-w-0">
            <p class="font-semibold text-tymeslot-900 truncate">
              {member_name(member)}
              <span :if={member.role == :owner} class="text-token-xs text-tymeslot-500">
                ({dgettext("dashboard_teams", "owner")})
              </span>
            </p>
            <p class="text-token-sm text-tymeslot-600 truncate">{member.user.email}</p>
            <p :if={!Teams.member_ready?(member.user.profile)} class="text-token-xs text-amber-700">
              {dgettext(
                "dashboard_teams",
                "No calendar connected: the team page is unavailable until this member connects one."
              )}
            </p>
          </div>
          <button
            :if={@owner? && member.role != :owner}
            type="button"
            phx-click="remove_member"
            phx-value-user-id={member.user_id}
            phx-target={@myself}
            class="btn btn-secondary"
          >
            {dgettext("dashboard_teams", "Remove")}
          </button>
        </li>
      </ul>

      <form
        :if={@owner?}
        id="add-member-form"
        phx-submit="add_member"
        phx-target={@myself}
        class="flex gap-3 items-start flex-wrap"
      >
        <div class="flex-1 min-w-[16rem]">
          <.input
            type="email"
            name="email"
            label={dgettext("dashboard_teams", "Add a member by email")}
            value={@member_email}
            placeholder={dgettext("dashboard_teams", "colleague@example.com")}
            errors={if @member_error, do: [@member_error], else: []}
            icon="hero-envelope"
          />
        </div>
        <button type="submit" class="btn btn-primary mt-7">
          {dgettext("dashboard_teams", "Add")}
        </button>
      </form>
    </div>
    """
  end

  # --- Events --------------------------------------------------------------

  @impl Phoenix.LiveComponent
  def handle_event("new_team", _params, socket) do
    {:noreply,
     assign(socket, form_mode: :new, form: @empty_form, errors: %{}, slug_touched: false)}
  end

  def handle_event("edit_team", _params, socket) do
    team = socket.assigns.selected_team

    form = %{
      "name" => team.name,
      "slug" => team.slug,
      "description" => team.description || ""
    }

    {:noreply, assign(socket, form_mode: :edit, form: form, errors: %{}, slug_touched: true)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, form_mode: nil, errors: %{})}
  end

  def handle_event("form_change", %{"team" => params} = event, socket) do
    slug_touched =
      socket.assigns.slug_touched or event["_target"] == ["team", "slug"]

    params =
      if slug_touched,
        do: params,
        else: Map.put(params, "slug", Teams.slug_from_name(params["name"]))

    {:noreply,
     assign(socket, form: Map.merge(socket.assigns.form, params), slug_touched: slug_touched)}
  end

  def handle_event("save_team", %{"team" => params}, socket) do
    user_id = socket.assigns.current_user.id

    result =
      case socket.assigns.form_mode do
        :edit -> Teams.update_team(socket.assigns.selected_team_id, user_id, params)
        _new -> Teams.create_team(user_id, params)
      end

    case result do
      {:ok, team} ->
        Flash.info(dgettext("dashboard_teams", "Team saved."))

        {:noreply,
         socket
         |> assign(form_mode: nil, errors: %{}, selected_team_id: team.id)
         |> load_teams()}

      {:error, %Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           form: Map.merge(socket.assigns.form, params),
           errors: changeset_errors(changeset)
         )}

      {:error, reason} ->
        Flash.error(Teams.error_message(reason))
        {:noreply, socket}
    end
  end

  def handle_event("select_team", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(selected_team_id: String.to_integer(id), member_email: "", member_error: nil)
     |> load_teams()}
  end

  def handle_event("deselect_team", _params, socket) do
    {:noreply, socket |> assign(:selected_team_id, nil) |> load_teams()}
  end

  def handle_event("add_member", %{"email" => email}, socket) do
    user_id = socket.assigns.current_user.id

    case Teams.add_member_by_email(socket.assigns.selected_team_id, user_id, email) do
      {:ok, _team} ->
        Flash.info(dgettext("dashboard_teams", "Member added."))
        {:noreply, socket |> assign(member_email: "", member_error: nil) |> load_teams()}

      {:error, reason} ->
        {:noreply, assign(socket, member_email: email, member_error: Teams.error_message(reason))}
    end
  end

  def handle_event("remove_member", %{"user-id" => member_id}, socket) do
    case Teams.remove_member(
           socket.assigns.selected_team_id,
           socket.assigns.current_user.id,
           String.to_integer(member_id)
         ) do
      {:ok, _team} -> Flash.info(dgettext("dashboard_teams", "Member removed."))
      {:error, reason} -> Flash.error(Teams.error_message(reason))
    end

    {:noreply, load_teams(socket)}
  end

  def handle_event("leave_team", _params, socket) do
    case Teams.leave_team(socket.assigns.selected_team_id, socket.assigns.current_user.id) do
      :ok ->
        Flash.info(dgettext("dashboard_teams", "You left the team."))
        {:noreply, socket |> assign(:selected_team_id, nil) |> load_teams()}

      {:error, reason} ->
        Flash.error(Teams.error_message(reason))
        {:noreply, socket}
    end
  end

  def handle_event("request_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, true)}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  def handle_event("delete_team", _params, socket) do
    case Teams.delete_team(socket.assigns.selected_team_id, socket.assigns.current_user.id) do
      :ok -> Flash.info(dgettext("dashboard_teams", "Team deleted."))
      {:error, reason} -> Flash.error(Teams.error_message(reason))
    end

    {:noreply,
     socket
     |> assign(show_delete_modal: false, selected_team_id: nil, form_mode: nil)
     |> load_teams()}
  end

  # Offers or withdraws one of the owner's team meeting types on the selected team.
  def handle_event("toggle_team_type", %{"id" => type_id}, socket) do
    team = socket.assigns.selected_team
    user_id = socket.assigns.current_user.id
    type_id = String.to_integer(type_id)
    offered? = Enum.any?(team.meeting_types, &(&1.id == type_id))

    result =
      if offered?,
        do: Teams.withdraw_meeting_type(team.id, user_id, type_id),
        else: Teams.offer_meeting_type(team.id, user_id, type_id)

    case result do
      {:ok, _team} ->
        {:noreply, load_teams(socket)}

      {:error, reason} ->
        Flash.error(Teams.error_message(reason))
        {:noreply, socket}
    end
  end

  # Orders the selected team's meeting types, dragged on its page.
  def handle_event("reorder_meeting_types", %{"ids" => ids}, socket) when is_list(ids) do
    team = socket.assigns.selected_team
    type_ids = for id <- ids, is_integer(id), do: id

    case Teams.reorder_meeting_types(team.id, socket.assigns.current_user.id, type_ids) do
      {:ok, _team} ->
        {:noreply, load_teams(socket)}

      {:error, reason} ->
        Flash.error(Teams.error_message(reason))
        {:noreply, socket}
    end
  end

  # --- Private -------------------------------------------------------------

  # The owner's team meeting types this team does not offer yet.
  defp not_offered(team, team_types), do: Enum.reject(team_types, &Teams.offers?(team, &1))

  defp load_teams(socket) do
    teams = Teams.list_teams_for_user(socket.assigns.current_user.id)
    selected = Enum.find(teams, &(&1.id == socket.assigns[:selected_team_id]))

    socket
    |> assign(:teams, teams)
    |> assign(:selected_team, selected)
    |> assign(:selected_team_id, selected && selected.id)
    |> assign(
      :team_types,
      MeetingTypes.list_user_team_meeting_types(socket.assigns.current_user.id)
    )
  end

  defp public_url(team), do: UrlBuilder.base_url() <> Teams.public_path(team)

  defp member_name(%{user: user}) do
    Profiles.display_name(user.profile) || user.name || user.email
  end

  defp changeset_errors(changeset) do
    Changeset.traverse_errors(changeset, &Forms.translate_error/1)
  end
end
