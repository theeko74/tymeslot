defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypesListComponent do
  @moduledoc """
  Function components for rendering the Meeting Types section header, add button, empty state,
  and the grid of meeting type cards, emitting events to the parent via parent_myself.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.MeetingSettings.Card

  attr :meeting_types, :list, required: true
  attr :show_add_form, :boolean, default: false
  attr :editing_type, :any, default: nil
  attr :currency, :string, default: "eur"
  attr :parent_myself, :any, required: true

  @spec meeting_types_section(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_types_section(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h2 class="text-token-xl font-semibold text-tymeslot-800">
          {dgettext("dashboard_meeting_types", "Meeting Types")}
        </h2>
        <%= unless @show_add_form || @editing_type do %>
          <button
            phx-click="toggle_add_form"
            phx-target={@parent_myself}
            class="btn btn-primary btn-sm"
          >
            <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 4v16m8-8H4"
              />
            </svg>
            {dgettext("dashboard_meeting_types", "Add Meeting Type")}
          </button>
        <% end %>
      </div>

      <%= if @meeting_types == [] && !@show_add_form do %>
        <div class="card-glass text-center py-8">
          <svg
            class="w-12 h-12 mx-auto text-tymeslot-400 mb-3"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <p class="text-tymeslot-600">
            {dgettext("dashboard_meeting_types", "No meeting types configured yet")}
          </p>
          <p class="text-token-sm text-tymeslot-500 mt-1">
            {dgettext(
              "dashboard_meeting_types",
              "Create meeting types to offer different appointment options"
            )}
          </p>
        </div>
      <% else %>
        <.sortable_cards
          id="meeting-types-sortable-list"
          meeting_types={@meeting_types}
          currency={@currency}
          parent_myself={@parent_myself}
        />
      <% end %>
    </div>
    """
  end

  attr :teams, :list, required: true
  attr :team_types, :list, required: true
  attr :show_add_form, :boolean, default: false
  attr :editing_type, :any, default: nil
  attr :currency, :string, default: "eur"
  attr :parent_myself, :any, required: true

  @doc """
  The user's team meeting types: generic, each offered by whichever of the
  user's teams list it (chosen per team on the Teams page). Shown once the user
  owns a team. Cards emit the same events as the user's own, so editing,
  activating, hiding and deleting work alike; adding sends `add_team_type`.
  """
  @spec team_meeting_types_section(map()) :: Phoenix.LiveView.Rendered.t()
  def team_meeting_types_section(assigns) do
    ~H"""
    <div :if={@teams != [] or @team_types != []} id="team-meeting-types" class="space-y-6">
      <div>
        <%!-- Laid out like the user's own section: title left, add button right. --%>
        <div class="flex items-center justify-between gap-3 flex-wrap">
          <h2 class="text-token-xl font-semibold text-tymeslot-800">
            {dgettext("dashboard_teams", "Team meeting types")}
          </h2>
          <button
            :if={!(@show_add_form || @editing_type)}
            id="add-team-meeting-type"
            phx-click="add_team_type"
            phx-target={@parent_myself}
            class="btn btn-primary btn-sm"
          >
            <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 4v16m8-8H4"
              />
            </svg>
            {dgettext("dashboard_teams", "Add a team meeting type")}
          </button>
        </div>
        <p class="text-token-sm text-tymeslot-600 mt-2">
          {dgettext(
            "dashboard_teams",
            "Create a team meeting type once, then choose on the Teams page which of your teams offer it. It is booked only when every member is free, against each member's own availability."
          )}
        </p>
      </div>

      <p :if={@team_types == []} class="card-glass text-center py-6 text-tymeslot-600">
        {dgettext("dashboard_teams", "No team meeting type yet.")}
      </p>

      <div
        :if={@team_types != []}
        id="team-meeting-types-sortable-list"
        phx-hook="MeetingTypeSortable"
        data-target={@parent_myself}
        class="flex flex-col space-y-2"
      >
        <div
          :for={type <- @team_types}
          draggable="true"
          data-meeting-type-id={type.id}
          class="cursor-move space-y-1"
        >
          <Card.meeting_type_card type={type} currency={@currency} myself={@parent_myself} />
          <p class="text-token-xs text-tymeslot-500 px-2">{offered_by(type)}</p>
        </div>
      </div>
    </div>
    """
  end

  # Which of the user's teams offer a team meeting type.
  defp offered_by(%{teams: [_first | _rest] = teams}) do
    dgettext("dashboard_teams", "Offered by: %{teams}",
      teams: Enum.map_join(teams, ", ", & &1.name)
    )
  end

  defp offered_by(_type), do: dgettext("dashboard_teams", "Not offered by any team yet.")

  attr :id, :string, required: true
  attr :meeting_types, :list, required: true
  attr :currency, :string, required: true
  attr :parent_myself, :any, required: true

  defp sortable_cards(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="MeetingTypeSortable"
      data-target={@parent_myself}
      class="flex flex-col space-y-2"
    >
      <%= for type <- @meeting_types do %>
        <div draggable="true" data-meeting-type-id={type.id} class="cursor-move">
          <Card.meeting_type_card type={type} currency={@currency} myself={@parent_myself} />
        </div>
      <% end %>
    </div>
    """
  end
end
