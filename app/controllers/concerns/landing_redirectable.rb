# Sends "/" to the user's chosen landing page (Settings -> Preferences).
#
# This runs on every visit to "/" rather than only after sign-in, so bookmarks
# and PWA cold launches ("start_url" is "/") honour the preference with one code
# path. That means "/" can no longer be relied on to render the dashboard, which
# is why routes.rb also exposes an explicit "/dashboard".
#
# Lives in a concern, and declares its own before_action, so PagesController
# gains a single `include` line and #dashboard - a method upstream edits often -
# stays untouched.
module LandingRedirectable
  extend ActiveSupport::Concern

  included do
    before_action :redirect_to_default_landing_page, only: :dashboard
  end

  private
    def redirect_to_default_landing_page
      # "/dashboard" must always render, or a non-home preference would make the
      # Home nav item and the logo unreachable.
      return unless request.path == root_path
      return if Current.user.nil? || Current.user.ui_layout_intro?

      target = LandingPage.find(Current.user.default_landing_page)
                          &.path(preview_features_enabled: preview_features_enabled?)
      return if target.blank? || target == root_path

      # ~20 controllers do `redirect_to root_path, alert: ...`. Flash normally
      # survives exactly one request, so without this the message would be swept
      # by this second hop and the user would never see it.
      flash.keep

      redirect_to target
    end
end
