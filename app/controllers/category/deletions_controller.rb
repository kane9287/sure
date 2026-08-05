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
    # user_selectable on both sides: built-in categories can't be deleted, and
    # can't absorb another category's transactions either.
    def set_category
      @category = Current.family.categories.user_selectable.find(params[:category_id])
    end

    def set_replacement_category
      if params[:replacement_category_id].present?
        @replacement_category = Current.family.categories.user_selectable.find(params[:replacement_category_id])
      end
    end
end
