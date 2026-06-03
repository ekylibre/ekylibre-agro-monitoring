# frozen_string_literal: true

module AgroMonitoring
  # Cadence throttle for satellite API calls.
  #
  # The Agromonitoring free plan caps satellite endpoints at 60 calls/min.
  # Pausing 1.1 s before every call keeps us comfortably under that limit
  # without coordination between concurrent jobs (we only run one at a time
  # via the agro_monitoring_import_running preference lock).
  #
  # 429 responses are logged by the integration layer but not retried at MVP.
  # See Phase 7 backlog for exponential back-off.
  module ApiThrottle
    module_function

    SATELLITE_MIN_DELAY = 1.1

    def pause!
      sleep SATELLITE_MIN_DELAY
    end
  end
end
