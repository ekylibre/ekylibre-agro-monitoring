# frozen_string_literal: true

module AgroMonitoring
  # Imports a window of NDVI history for a single CultivableZone and stores
  # each data point as an Analysis with the four scalar NDVI indicators
  # already present in the Ekylibre core nomenclature.
  #
  # Idempotent: an Analysis is identified by (cultivable_zone_id, reference_number)
  # where reference_number follows the legacy "#{dt}_ndvi" convention so existing
  # core data and the NdviCellsController graph keep working unchanged.
  class NdviHistoryImportService
    INDICATOR_MAPPING = {
      min: :minimal_ndvi_index,
      max: :maximal_ndvi_index,
      mean: :average_ndvi_index,
      median: :median_ndvi_index
    }.freeze

    def self.call(cultivable_zone:, start_unix:, end_unix:, clouds_max: 10)
      new(cultivable_zone: cultivable_zone, start_unix: start_unix, end_unix: end_unix, clouds_max: clouds_max).call
    end

    def initialize(cultivable_zone:, start_unix:, end_unix:, clouds_max: 10)
      @cultivable_zone = cultivable_zone
      @start_unix = start_unix
      @end_unix = end_unix
      @clouds_max = clouds_max
    end

    def call
      return { status: :skipped_no_polygon, cultivable_zone_id: @cultivable_zone.id } unless polygon_id

      processed = 0
      created = 0

      ApiThrottle.pause!
      AgroMonitoringIntegration.ndvi_history(polygon_id, @start_unix, @end_unix, clouds_max: @clouds_max).execute do |c|
        c.success do |items|
          Array(items).each do |item|
            processed += 1
            created += 1 if create_analysis(item)
          end
        end
      end

      { status: :ok, cultivable_zone_id: @cultivable_zone.id, polygon_id: polygon_id, processed: processed, created: created }
    rescue StandardError => e
      Rails.logger.error "[AgroMonitoring] NdviHistoryImportService error on CultivableZone##{@cultivable_zone.id}: #{e.message}"
      { status: :error, cultivable_zone_id: @cultivable_zone.id, message: e.message }
    end

    private

      def polygon_id
        @polygon_id ||= @cultivable_zone.provider.dig(:data, 'id') ||
                        @cultivable_zone.provider.dig(:data, :id)
      end

      def create_analysis(item)
        reference_number = "#{item[:dt]}_ndvi"
        return false if Analysis.where(cultivable_zone_id: @cultivable_zone.id, reference_number: reference_number).exists?

        sampled_at = Time.at(item[:dt].to_i)
        analysis = Analysis.create!(
          reference_number: reference_number,
          cultivable_zone_id: @cultivable_zone.id,
          nature: 'sensor_analysis',
          sampled_at: sampled_at,
          analysed_at: sampled_at
        )

        data = item[:data] || {}
        INDICATOR_MAPPING.each do |key, indicator|
          value = data[key] || data[key.to_s]
          next if value.blank?

          analysis.read!(indicator, value.to_f)
        end

        true
      rescue ActiveRecord::RecordNotUnique
        false
      end
  end
end
