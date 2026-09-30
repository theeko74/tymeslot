defmodule Tymeslot.Emails.Templates.TeamMemberAdded do
  @moduledoc """
  Email telling a user a team owner added them to a team.

  From then on the team page offers only the times they are free along with
  the rest of the team, and a booking made there lands on their calendar
  inside Tymeslot. Sent in the recipient's own language (`users.locale`).
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{Buttons, MjmlEmail, Sanitise, TemplateHelper, Text}
  alias Tymeslot.Profiles

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders the email for `user`, added to `team` by `owner`. `dashboard_url`
  is where the user can see the team and leave it.
  """
  @spec render(map(), map(), map(), String.t()) :: Swoosh.Email.t()
  def render(user, team, owner, dashboard_url) when is_binary(dashboard_url) do
    Gettext.with_locale(TymeslotWeb.Gettext, RecipientLocale.locale_for(user), fn ->
      owner_name = display_name(owner)
      headline = dgettext("emails_teams", "You joined %{team}", team: team.name)

      body =
        dgettext(
          "emails_teams",
          "%{owner} added you to the team %{team}. Its booking page now offers only the times every member is free, and meetings booked there will appear on your dashboard.",
          owner: owner_name,
          team: team.name
        )

      subject =
        dgettext("emails_teams", "%{owner} added you to %{team}",
          owner: owner_name,
          team: team.name
        )

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content(body, dashboard_url),
          headline,
          headline,
          intent: :confirmed,
          eyebrow: dgettext("emails_teams", "Team"),
          stage_title: headline,
          stage_subtitle:
            dgettext("emails_teams", "You can leave the team at any time from your dashboard.")
        )

      MjmlEmail.base_email(tracking: :lifecycle)
      |> to({display_name(user), user.email})
      |> subject(Sanitise.sanitize_for_header(subject))
      |> html_body(html_body)
      |> text_body(text_body(headline, body, dashboard_url))
    end)
  end

  defp mjml_content(body, dashboard_url) do
    """
    #{Text.centered_text(body, padding: "4px 0 12px 0")}

    #{Buttons.action_button(:confirmed, dgettext("emails_teams", "View my teams"), dashboard_url, full_width: true, size: :large)}

    #{Text.troubleshooting_link(dashboard_url)}
    """
  end

  defp text_body(headline, body, dashboard_url) do
    """
    #{headline}

    #{body}

    #{dgettext("emails_teams", "View my teams:")}
    #{dashboard_url}
    """
  end

  defp display_name(%{profile: %{} = profile} = user),
    do: Profiles.display_name(profile) || user.name || user.email

  defp display_name(user), do: user.name || user.email
end
