# The screen a user lands on when they open the app (i.e. visit "/").
#
# Modeled on AccountOrder, with one difference: the labels are i18n keys resolved
# at call time rather than baked-in English, because every destination here is
# already a nav entry and those strings are translated in every locale. See
# `layouts.application.nav.*` in config/locales/views/layout/en.yml.
#
# The "plan" entry mirrors ApplicationHelper#plan_nav_item - the Plan hub only
# replaces Budgets for preview users, so without the flag both the label and the
# path fall back to Budgets.
class LandingPage
  include ActiveModel::Model
  include ActiveModel::Attributes

  PAGES = {
    "home" => {
      route: :dashboard,
      i18n: "home"
    },
    "transactions" => {
      route: :transactions,
      i18n: "transactions"
    },
    "plan" => {
      route: :plan,
      i18n: "plan",
      fallback_route: :budgets,
      fallback_i18n: "budgets"
    },
    "reports" => {
      route: :reports,
      i18n: "reports"
    },
    "debt_plans" => {
      route: :debt_plans,
      i18n: "debt_plans"
    }
  }.freeze

  attr_accessor :key

  def initialize(key)
    @key = key.to_s
    raise ArgumentError, "Invalid landing page key: #{@key}" unless PAGES.key?(@key)
  end

  def path(preview_features_enabled: false)
    route = resolved_route(preview_features_enabled: preview_features_enabled)
    Rails.application.routes.url_helpers.public_send("#{route}_path")
  end

  def label(preview_features_enabled: false)
    I18n.t("layouts.application.nav.#{resolved_i18n_key(preview_features_enabled: preview_features_enabled)}")
  end

  class << self
    def all
      PAGES.keys.map { |key| new(key) }
    end

    def find(key)
      new(key) if PAGES.key?(key.to_s)
    end

    def default
      new("home")
    end
  end

  private
    # Falls back whenever the entry declares a fallback and preview is off.
    def resolved_route(preview_features_enabled:)
      fallback = PAGES.dig(key, :fallback_route)
      return fallback if fallback.present? && !preview_features_enabled

      PAGES.dig(key, :route)
    end

    def resolved_i18n_key(preview_features_enabled:)
      fallback = PAGES.dig(key, :fallback_i18n)
      return fallback if fallback.present? && !preview_features_enabled

      PAGES.dig(key, :i18n)
    end
end
