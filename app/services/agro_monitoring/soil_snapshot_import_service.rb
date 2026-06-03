# frozen_string_literal: true

module AgroMonitoring
  # Imports the current soil snapshot for a single CultivableZone.
  # Stores moisture (%), surface temperature (°C, t0) and 10cm-depth temperature
  # (°C, t10) as an Analysis with reference_number "#{dt}_soil".
  #
  # Unit conversions match the legacy CultivableZoneAnalysis:
  #   - moisture is a ratio in the API response, wrapped as a percent Measure.
  #   - temperatures are Kelvin in the API response, converted to Celsius.
  class SoilSnapshotImportService
    def self.call(cultivable_zone:)
      new(cultivable_zone: cultivable_zone).call
    end

    def initialize(cultivable_zone:)
      @cultivable_zone = cultivable_zone
    end

    def call
      return { status: :skipped_no_polygon, cultivable_zone_id: @cultivable_zone.id } unless polygon_id

      created = 0

      ApiThrottle.pause!
      AgroMonitoringIntegration.current_soil(polygon_id).execute do |c|
        c.success do |item|
          created = 1 if create_analysis(item)
        end
      end

      { status: :ok, cultivable_zone_id: @cultivable_zone.id, polygon_id: polygon_id, created: created }
    rescue StandardError => e
      Rails.logger.error "[AgroMonitoring] SoilSnapshotImportService error on CultivableZone##{@cultivable_zone.id}: #{e.message}"
      { status: :error, cultivable_zone_id: @cultivable_zone.id, message: e.message }
    end

    private

      def polygon_id
        @polygon_id ||= @cultivable_zone.provider.dig(:data, 'id') ||
                        @cultivable_zone.provider.dig(:data, :id)
      end

      def create_analysis(item)
        return false if item.blank? || item[:dt].blank?

        reference_number = "#{item[:dt]}_soil"
        return false if Analysis.where(cultivable_zone_id: @cultivable_zone.id, reference_number: reference_number).exists?

        sampled_at = Time.at(item[:dt].to_i)
        analysis = Analysis.create!(
          reference_number: reference_number,
          cultivable_zone_id: @cultivable_zone.id,
          nature: 'sensor_analysis',
          sampled_at: sampled_at,
          analysed_at: sampled_at
        )

        analysis.read!(:soil_moisture, item[:moisture].to_d.in_percent) if item[:moisture].present?
        analysis.read!(:soil_surface_temperature, (item[:t0].to_d - 273.15).in_celsius) if item[:t0].present?
        analysis.read!(:soil_10cm_depth_surface_temperature, (item[:t10].to_d - 273.15).in_celsius) if item[:t10].present?

        true
      rescue ActiveRecord::RecordNotUnique
        false
      end
  end
end
