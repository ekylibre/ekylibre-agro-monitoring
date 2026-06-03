# frozen_string_literal: true

Rails.application.routes.draw do
  namespace :agro_monitoring do
    resource :agro_monitoring_synchronization, only: [] do
      get :perform
    end
  end
end
