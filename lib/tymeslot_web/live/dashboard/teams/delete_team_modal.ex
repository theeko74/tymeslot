defmodule TymeslotWeb.Dashboard.Teams.DeleteTeamModal do
  @moduledoc """
  Confirmation modal for deleting a team. Deleting takes the team page down for
  everyone holding its link, so it is never one click away.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :open, :boolean, required: true
  attr :team, :map, default: nil
  attr :myself, :any, required: true

  @spec delete_team_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_team_modal(assigns) do
    ~H"""
    <.modal
      :if={@open && @team}
      id="delete-team-modal"
      show={true}
      on_cancel={JS.push("close_delete_modal", target: @myself)}
      size={:medium}
    >
      <:header>
        <span class="text-token-xl font-black tracking-tight">
          {dgettext("dashboard_teams", "Delete this team?")}
        </span>
      </:header>

      <p class="text-tymeslot-700">
        {dgettext(
          "dashboard_teams",
          "The booking page of “%{name}” will stop working for everyone holding its link. Meetings already booked are kept. This cannot be undone.",
          name: @team.name
        )}
      </p>

      <:footer>
        <div class="flex justify-end gap-3">
          <.action_button variant={:secondary} phx-click="close_delete_modal" phx-target={@myself}>
            {dgettext("dashboard_teams", "Keep team")}
          </.action_button>
          <.action_button variant={:danger} phx-click="delete_team" phx-target={@myself}>
            {dgettext("dashboard_teams", "Delete team")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
