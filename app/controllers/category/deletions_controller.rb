class Category::DeletionsController < ApplicationController
  before_action :set_category
  before_action :set_replacement_category, only: :create

  def new
  end

  def create
    @category.replace_and_destroy! @replacement_category

    redirect_back_or_to transactions_path, notice: t(".success")
  end

  private
    # Only a user-managed category can be deleted; built-in ones are undeletable
    # no matter how assignable they are. The replacement side is an assignment
    # target, so it uses the wider user_selectable scope.
    def set_category
      @category = Current.family.categories.user_managed.find(params[:category_id])
    end

    def set_replacement_category
      if params[:replacement_category_id].present?
        @replacement_category = Current.family.categories.user_selectable.find(params[:replacement_category_id])
      end
    end
end
