module AgroMonitoring
  class Engine < ::Rails::Engine

    initializer 'agro_monitoring.assets.precompile' do |app|
      app.config.assets.precompile += %w[integrations/agro_monitoring.png]
    end

    initializer :i18n do |app|
      app.config.i18n.load_path += Dir[AgroMonitoring::Engine.root.join('config', 'locales', '**', '*.yml')]
    end

    initializer :ekylibre_agro_monitoring_integration do
      AgroMonitoring::AgroMonitoringIntegration.on_check_success do
        AgroMonitoringFirstRunJob.perform_later
      end

      AgroMonitoring::AgroMonitoringIntegration.run every: :day do
        last_agro_monitoring_import = Preference.find_by(name: 'last_agro_monitoring_import')
        agro_monitoring_import_running = Preference.find_by(name: 'agro_monitoring_import_running')
        if last_agro_monitoring_import&.value && !agro_monitoring_import_running&.value
          last_imported_at = last_agro_monitoring_import.value
          AgroMonitoringDailyFetchJob.perform_now(last_imported_at)
        end
      end
    end

    initializer 'agro_monitoring.extend_cultivable_zone_toolbar' do |_app|
      Ekylibre::View::Addon.add(:extensions_content_top, 'backend/agro_monitoring/sync_toolbar', to: 'backend/cultivable_zones#show')
    end

  end
end
