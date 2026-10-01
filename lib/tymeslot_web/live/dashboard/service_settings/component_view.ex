defmodule TymeslotWeb.Dashboard.ServiceSettings.ComponentView do
  @moduledoc """
  Markup for the meeting (service) settings component.

  Extracted from `ServiceSettingsComponent` so that module stays focused on lifecycle
  and event routing, matching how `CalendarSettings.ComponentView` sits behind
  `CalendarSettingsComponent`. `settings/1` receives the component's assigns
  unchanged (its `render/1` delegates straight to it), so LiveView change
  tracking is preserved.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Teams
  alias TymeslotWeb.Components.Dashboard.MeetingTypes.BookingLinkModal
  alias TymeslotWeb.Components.Dashboard.MeetingTypes.DeleteMeetingTypeModal
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypesListComponent
  alias TymeslotWeb.Dashboard.MeetingSettings.SchedulingSettingsComponent
  alias TymeslotWeb.Endpoint

  @spec settings(map()) :: Phoenix.LiveView.Rendered.t()
  def settings(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <.section_header
        icon="hero-squares-2x2"
        title={dgettext("dashboard_integrations", "Meeting Settings")}
        saving={@saving}
      />

      <%= if (@show_edit_overlay && @editing_type) || @show_add_form do %>
        <%!-- Form View (Add or Edit) --%>
        <div
          id="meeting-type-config-view"
          phx-hook="ScrollReset"
          data-action={if @editing_type, do: "edit-#{@editing_type.id}", else: "new"}
          class="space-y-8"
        >
          <div class="bg-white p-6 rounded-token-3xl border-2 border-tymeslot-50 shadow-sm space-y-4">
            <div class="flex items-start justify-between">
              <.section_header
                level={2}
                icon="hero-squares-2x2"
                title={form_title(assigns)}
              />
              <button
                phx-click={if @editing_type, do: "close_edit_overlay", else: "toggle_add_form"}
                phx-target={@myself}
                class="shrink-0 p-2 rounded-lg text-tymeslot-500 hover:text-tymeslot-700 hover:bg-tymeslot-100 transition-colors"
                title={dgettext("dashboard_integrations", "Close")}
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2.5"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>

            <%!-- Direct booking link, always at hand while editing (needs a username) --%>
            <div
              :if={@editing_type && booking_base_urls(@profile, @editing_type) != []}
              class="space-y-2"
            >
              <div
                :for={
                  {base_url, index} <- Enum.with_index(booking_base_urls(@profile, @editing_type))
                }
                class="flex flex-wrap items-center gap-2"
              >
                <input
                  type="text"
                  readonly
                  aria-label={dgettext("dashboard_integrations", "Direct booking link")}
                  value={"#{base_url}/#{MeetingTypes.effective_slug(@editing_type)}"}
                  class="font-mono text-token-sm flex-1 min-w-[12rem] px-4 py-2.5 rounded-token-xl border-2 border-tymeslot-100 bg-tymeslot-50 text-tymeslot-600 cursor-default"
                />
                <button
                  type="button"
                  id={"copy-booking-link-#{@editing_type.id}-#{index}"}
                  phx-hook="CopyOnClick"
                  data-copy-text={"#{base_url}/#{MeetingTypes.effective_slug(@editing_type)}"}
                  data-copy-feedback={dgettext("dashboard_integrations", "Booking link copied!")}
                  class="whitespace-nowrap px-5 py-2.5 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all border-2 border-transparent hover:border-tymeslot-200"
                >
                  {dgettext("dashboard_integrations", "Copy")}
                </button>
                <.action_button
                  :if={index == 0}
                  type="button"
                  variant={:secondary}
                  phx-click="open_slug_modal"
                  phx-target={@myself}
                >
                  {dgettext("dashboard_integrations", "Change link")}
                </.action_button>
              </div>
              <p class="text-token-sm text-tymeslot-500">
                {dgettext(
                  "dashboard_integrations",
                  "Anyone with this link can book this meeting type directly, without seeing your other meeting types."
                )}
              </p>
            </div>
          </div>

          <div class={if @editing_type, do: nil, else: "card-glass"}>
            <.live_component
              module={MeetingTypeForm}
              id={
                if @editing_type,
                  do: "meeting-type-form-edit-#{@editing_type.id}",
                  else: "meeting-type-form-new"
              }
              type={@editing_type}
              is_edit={!!@editing_type}
              video_integrations={@video_integrations}
              calendar_integrations={@calendar_integrations}
              parent_myself={@myself}
              saving={@saving}
              current_user={@current_user}
              client_ip={@client_ip}
              user_agent={@user_agent}
              form_errors={@form_errors}
              custom_questions_allowed={@custom_questions_allowed}
              team_type={@adding_team_type or (@editing_type != nil and @editing_type.is_team_type)}
            />
          </div>

          <BookingLinkModal.booking_link_modal
            show={@show_slug_modal}
            meeting_type={@slug_modal_type}
            slug_draft={@slug_draft}
            base_url={List.first(booking_base_urls(@profile, @slug_modal_type)) || ""}
            myself={@myself}
          />
        </div>
      <% else %>
        <%!-- Normal View --%>
        <div class="space-y-10">
          <%!-- Meeting Types Section --%>
          <div class="space-y-6">
            <MeetingTypesListComponent.meeting_types_section
              meeting_types={@meeting_types}
              show_add_form={@show_add_form}
              editing_type={@editing_type}
              currency={@payment_currency}
              parent_myself={@myself}
            />
          </div>

          <%!-- Team Meeting Types Section --%>
          <MeetingTypesListComponent.team_meeting_types_section
            teams={@teams}
            team_types={@team_types}
            show_add_form={@show_add_form}
            editing_type={@editing_type}
            currency={@payment_currency}
            parent_myself={@myself}
          />

          <%!-- Scheduling Settings --%>
          <div>
            <.live_component
              module={SchedulingSettingsComponent}
              id="scheduling-settings"
              profile={@profile}
              client_ip={@client_ip}
              user_agent={@user_agent}
            />
          </div>
        </div>

        <%!-- Delete Meeting Type Modal --%>
        <DeleteMeetingTypeModal.delete_meeting_type_modal
          show={@show_delete_meeting_type_modal}
          meeting_type={@delete_meeting_type_modal_data}
          myself={@myself}
        />
      <% end %>

      <%!-- Add spacing after content to prevent flush bottom --%>
      <div class="pb-8"></div>
    </div>
    """
  end

  defp form_title(%{editing_type: %{}}),
    do: dgettext("dashboard_integrations", "Edit Meeting Type")

  defp form_title(%{adding_team_type: true}),
    do: dgettext("dashboard_teams", "Add a team meeting type")

  defp form_title(_assigns), do: dgettext("dashboard_integrations", "Add Meeting Type")

  # The public bases of a meeting type's booking links: each page of a team
  # offering a team type ("https://host/team/sales"), the user's page for a
  # personal one ("https://host/alice"). Empty when there is no page to link to
  # yet (link UI is then hidden).
  defp booking_base_urls(_profile, %{is_team_type: true, teams: teams}) when is_list(teams),
    do: Enum.map(teams, &(Endpoint.url() <> Teams.public_path(&1)))

  defp booking_base_urls(_profile, %{is_team_type: true}), do: []

  defp booking_base_urls(%{username: username}, _type)
       when is_binary(username) and username != "",
       do: [Endpoint.url() <> "/" <> username]

  defp booking_base_urls(_profile, _type), do: []
end
