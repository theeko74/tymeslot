defmodule TymeslotWeb.Dashboard.ThemeSettingsComponent do
  @moduledoc """
  Theme selection component for the dashboard.
  Allows users to select their booking page theme.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Teams
  alias TymeslotWeb.Dashboard.ThemeSettings.BookingTextForm
  alias TymeslotWeb.Dashboard.ThemeSettings.TeamLogoComponent
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationComponent
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemePreview
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  # A team's logo or wording, changed by one of its forms below.
  def update(%{team_updated: team}, socket) do
    {:ok, assign(socket, :owned_teams, replace_team(socket.assigns.owned_teams, team))}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:themes, ThemeInfo.theme_options())
      # Only a team's owner styles its page, so only owned teams are listed.
      |> assign_new(:owned_teams, fn -> Teams.list_owned_teams(assigns.current_user.id) end)
      |> assign_new(:customization_timestamp, fn -> System.system_time() end)

    customization_team = customization_team(socket.assigns)

    customization_theme_id =
      if assigns.live_action in [:theme_customization, :team_theme_customization] do
        theme_id = assigns.params["theme_id"]
        if ThemeInfo.valid_theme_id?(theme_id), do: theme_id, else: nil
      else
        assigns[:customization_theme_id]
      end

    show_customization =
      case assigns.live_action do
        :theme_customization ->
          not is_nil(customization_theme_id)

        # An unknown team, or one this user does not own, shows the theme list.
        :team_theme_customization ->
          not is_nil(customization_theme_id) and customization_team != nil

        _other ->
          assigns[:show_customization] || false
      end

    {:ok,
     socket
     |> assign(:show_customization, show_customization)
     |> assign(:customization_team, customization_team)
     |> assign(:customization_theme_id, customization_theme_id)}
  end

  defp customization_team(%{live_action: :team_theme_customization} = assigns) do
    team_id = assigns.params["team_id"]
    Enum.find(assigns.owned_teams, &(to_string(&1.id) == team_id))
  end

  defp customization_team(_assigns), do: nil

  defp replace_team(teams, updated),
    do: Enum.map(teams, fn team -> if team.id == updated.id, do: updated, else: team end)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <%= if @show_customization && @customization_theme_id do %>
        <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
          <.live_component
            module={ThemeCustomizationComponent}
            id={
              "theme-customization-#{if @customization_team, do: "team-#{@customization_team.id}-"}#{@customization_theme_id}-#{@customization_timestamp}"
            }
            profile={@profile}
            team={@customization_team}
            theme_id={@customization_theme_id}
            parent_component={@myself}
          />
        </div>
      <% else %>
        <.section_header
          icon="hero-paint-brush"
          title={dgettext("dashboard_appearance", "Choose Your Style")}
        />

        <div class="mb-16 max-w-2xl">
          <p class="text-xl text-tymeslot-500 font-medium leading-relaxed">
            {dgettext(
              "dashboard_appearance",
              "Select the interface that best represents your personal brand and creates the best experience for your clients."
            )}
          </p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-10">
          <%= for {theme_name, theme_id} <- @themes do %>
            <div class="group/theme space-y-6">
              <div
                class={[
                  "card-glass p-0 overflow-hidden cursor-pointer transition-all duration-500 border-2",
                  if(@profile.booking_theme == theme_id,
                    do:
                      "glass-gradient border-turquoise-400 shadow-2xl shadow-turquoise-500/20 ring-4 ring-turquoise-50",
                    else:
                      "border-tymeslot-50 hover:border-turquoise-200 hover:shadow-xl hover:shadow-tymeslot-200/50"
                  )
                ]}
                phx-click="select_theme"
                phx-value-theme={theme_id}
                phx-target={@myself}
              >
                <div class="h-64 relative overflow-hidden">
                  <ThemePreview.render theme_id={theme_id} />

                  <div class="absolute inset-0 bg-linear-to-t from-tymeslot-900/60 via-transparent to-transparent opacity-60 group-hover/theme:opacity-40 transition-opacity">
                  </div>

                  <div class="absolute bottom-6 left-6 right-6 flex items-center justify-between">
                    <h3 class="text-token-2xl font-black text-white tracking-tight drop-shadow-md">
                      {theme_name}
                    </h3>
                    <%= if @profile.booking_theme == theme_id do %>
                      <div class="flex items-center gap-2 bg-turquoise-500 text-white px-4 py-1.5 rounded-full text-token-xs font-black uppercase tracking-wider shadow-lg">
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="3"
                            d="M5 13l4 4L19 7"
                          />
                        </svg>
                        {dgettext("dashboard_appearance", "Current Style")}
                      </div>
                    <% end %>
                  </div>

                  <div
                    :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
                    class="absolute inset-0 bg-tymeslot-900/40 backdrop-blur-[2px] flex flex-col items-center justify-center cursor-not-allowed z-20"
                  >
                    <div class="w-12 h-12 bg-white/20 rounded-token-2xl flex items-center justify-center mb-3">
                      <svg
                        class="w-6 h-6 text-white"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2.5"
                          d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                        />
                      </svg>
                    </div>
                    <span class="text-white font-black text-token-xs uppercase tracking-widest">
                      {dgettext("dashboard_appearance", "Connect Calendar to Preview")}
                    </span>
                  </div>
                </div>

                <div class="p-8">
                  <p class="text-tymeslot-600 font-medium leading-relaxed line-clamp-2">
                    {ThemeInfo.get_description(theme_id)}
                  </p>
                </div>
              </div>

              <div class="flex gap-4">
                <%= if LinkAccessPolicy.can_link?(@profile, @integration_status) do %>
                  <a
                    href={
                      PreviewMode.owner_path(@profile.username, @profile.user_id, theme: theme_id)
                    }
                    target="_blank"
                    rel="noopener noreferrer"
                    class="btn btn-secondary flex-1 py-3 px-4 text-token-sm"
                  >
                    <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2.5"
                        d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                      />
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2.5"
                        d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
                      />
                    </svg>
                    {dgettext("dashboard_appearance", "Live Preview")}
                  </a>
                <% else %>
                  <button
                    type="button"
                    class="btn btn-secondary flex-1 py-3 px-4 text-token-sm opacity-50 cursor-not-allowed"
                    disabled
                    title={dgettext("dashboard_appearance", "Connect Calendar to Preview")}
                  >
                    <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2.5"
                        d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                      />
                    </svg>
                    {dgettext("dashboard_appearance", "Live Preview")}
                  </button>
                <% end %>
                <button
                  type="button"
                  class="btn btn-primary flex-1 py-3 px-4 text-token-sm"
                  phx-click="show_customization"
                  phx-value-theme={theme_id}
                  phx-target={@myself}
                >
                  <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2.5"
                      d="M12 6V4m0 2a2 2 0 100 4m0-4a2 2 0 110 4m-6 8a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4m6 6v10m6-2a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4"
                    />
                  </svg>
                  {dgettext("dashboard_appearance", "Customize Style")}
                </button>
              </div>
            </div>
          <% end %>
        </div>

        <.live_component
          module={BookingTextForm}
          id="booking-text-form"
          profile={@profile}
        />

        <.team_themes
          :if={@owned_teams != []}
          teams={@owned_teams}
          themes={@themes}
          myself={@myself}
          profile={@profile}
          current_user={@current_user}
        />

        <div class="mt-16 bg-tymeslot-50 border-2 border-dashed border-tymeslot-200 rounded-token-3xl p-8 relative overflow-hidden group">
          <div class="absolute top-0 right-0 p-4 opacity-10 group-hover:rotate-12 transition-transform duration-700">
            <svg class="w-32 h-32 text-tymeslot-900" fill="currentColor" viewBox="0 0 24 24">
              <path d="M11.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z" />
            </svg>
          </div>
          <div class="relative z-10">
            <h4 class="text-token-2xl font-black text-tymeslot-900 tracking-tight mb-2">
              {dgettext("dashboard_appearance", "More Styles Coming Soon")}
            </h4>
            <p class="text-tymeslot-500 font-medium text-token-lg mb-6">
              {dgettext(
                "dashboard_appearance",
                "Our design team is busy crafting new themes to help you express your unique professional style."
              )}
            </p>
            <div class="flex gap-2">
              <div class="w-2 h-2 bg-turquoise-400 rounded-full animate-bounce"></div>
              <div class="w-2 h-2 bg-turquoise-400 rounded-full animate-bounce [animation-delay:0.2s]">
              </div>
              <div class="w-2 h-2 bg-turquoise-400 rounded-full animate-bounce [animation-delay:0.4s]">
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :teams, :list, required: true
  attr :themes, :list, required: true
  attr :myself, :any, required: true
  attr :profile, :map, required: true
  attr :current_user, :map, required: true

  # One block per team the user owns: its logo, which theme its page wears
  # with a way into that theme's customisation for this team alone, and the
  # wording that opens its page.
  defp team_themes(assigns) do
    ~H"""
    <section id="team-themes" class="mt-16 space-y-6">
      <.section_header
        icon="hero-user-group"
        title={dgettext("dashboard_teams", "Team pages")}
      />
      <p class="text-tymeslot-500 font-medium max-w-2xl">
        {dgettext(
          "dashboard_teams",
          "Each team page can wear its own style. Until you choose one, it wears yours."
        )}
      </p>

      <div
        :for={team <- @teams}
        id={"team-theme-#{team.id}"}
        class="card-glass space-y-5"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">{team.name}</h3>
          <a
            href={"/team/#{team.slug}"}
            target="_blank"
            rel="noopener noreferrer"
            class="text-token-sm font-bold text-turquoise-600 hover:text-turquoise-700"
          >
            /team/{team.slug}
          </a>
        </div>

        <.live_component
          module={TeamLogoComponent}
          id={"team-logo-#{team.id}"}
          team={team}
          current_user={@current_user}
          parent={@myself}
        />

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div
            :for={{theme_name, theme_id} <- @themes}
            class={[
              "rounded-token-2xl border-2 p-4 space-y-3 transition-all",
              if(team.booking_theme == theme_id,
                do: "border-turquoise-400 bg-turquoise-50/50",
                else: "border-tymeslot-100"
              )
            ]}
          >
            <div class="h-28 overflow-hidden rounded-token-lg">
              <ThemePreview.render theme_id={theme_id} />
            </div>
            <div class="flex items-center justify-between gap-2">
              <span class="font-black text-tymeslot-900">{theme_name}</span>
              <span
                :if={team.booking_theme == theme_id}
                class="text-token-xs font-black uppercase tracking-wider text-turquoise-600"
              >
                {dgettext("dashboard_appearance", "Current Style")}
              </span>
            </div>
            <div class="flex gap-2">
              <button
                :if={team.booking_theme != theme_id}
                type="button"
                id={"select-team-theme-#{team.id}-#{theme_id}"}
                class="btn btn-secondary flex-1 py-2 px-3 text-token-sm"
                phx-click="select_team_theme"
                phx-value-team-id={team.id}
                phx-value-theme={theme_id}
                phx-target={@myself}
              >
                {dgettext("dashboard_teams", "Use this style")}
              </button>
              <button
                type="button"
                id={"customize-team-theme-#{team.id}-#{theme_id}"}
                class="btn btn-primary flex-1 py-2 px-3 text-token-sm"
                phx-click="customize_team_theme"
                phx-value-team-id={team.id}
                phx-value-theme={theme_id}
                phx-target={@myself}
              >
                {dgettext("dashboard_appearance", "Customize Style")}
              </button>
            </div>
          </div>
        </div>

        <button
          :if={team.booking_theme}
          type="button"
          id={"reset-team-theme-#{team.id}"}
          class="text-token-sm font-bold text-tymeslot-500 hover:text-tymeslot-700"
          phx-click="select_team_theme"
          phx-value-team-id={team.id}
          phx-value-theme=""
          phx-target={@myself}
        >
          {dgettext("dashboard_teams", "Wear the same style as my page")}
        </button>

        <.live_component
          module={BookingTextForm}
          id={"team-booking-text-#{team.id}"}
          profile={@profile}
          team={team}
          parent={@myself}
        />
      </div>
    </section>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_team_theme", %{"team-id" => team_id, "theme" => theme}, socket) do
    theme_id = if theme == "", do: nil, else: theme

    with {id, ""} <- Integer.parse(team_id),
         {:ok, updated} <-
           Teams.update_booking_theme(id, socket.assigns.current_user.id, theme_id) do
      {:noreply,
       socket
       |> assign(:owned_teams, replace_team(socket.assigns.owned_teams, updated))
       |> Flash.put_flash(
         :info,
         dgettext("dashboard_teams", "Style of the team %{team} updated", team: updated.name)
       )}
    else
      _error ->
        {:noreply,
         Flash.put_flash(
           socket,
           :error,
           dgettext("dashboard_appearance", "Failed to update theme")
         )}
    end
  end

  def handle_event("customize_team_theme", %{"team-id" => team_id, "theme" => theme_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard/theme/team/#{team_id}/customize/#{theme_id}")}
  end

  def handle_event("show_customization", %{"theme" => theme_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard/theme/customize/#{theme_id}")}
  end

  def handle_event("close_customization", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard/theme")}
  end

  def handle_event("select_theme", %{"theme" => theme_id}, socket) do
    if ThemeInfo.valid_theme_id?(theme_id) do
      case Profiles.update_booking_theme(socket.assigns.profile, theme_id) do
        {:ok, updated_profile} ->
          theme_name = ThemeInfo.get_theme_name(updated_profile.booking_theme)
          send(self(), {:profile_updated, updated_profile})

          {:noreply,
           socket
           |> assign(profile: updated_profile)
           |> Flash.put_flash(
             :info,
             dgettext("dashboard_appearance", "Theme updated to %{theme_name}",
               theme_name: theme_name
             )
           )}

        {:error, _changeset} ->
          {:noreply,
           Flash.put_flash(
             socket,
             :error,
             dgettext("dashboard_appearance", "Failed to update theme")
           )}
      end
    else
      {:noreply,
       Flash.put_flash(
         socket,
         :error,
         dgettext("dashboard_appearance", "Invalid theme selection")
       )}
    end
  end
end
