# frozen_string_literal: true

module Takagi
  module Observer
    # Periodically notifies observers by re-running registered handlers.
    class Watcher
      def initialize(interval: 1)
        @interval = interval
        @running = false
        @thread = nil
      end

      def start
        return @thread if @running

        @running = true
        @thread = Thread.new do
          while @running
            Takagi::ObserveRegistry.subscription_paths.each do |path|
              observable_route = Takagi::Base.router.find_observable(path)
              next unless observable_route

              handler = observable_route.block
              current_value = handler.call(nil)

              Takagi::ObserveRegistry.notify(path, current_value)
            end
            sleep @interval
          end
          @thread
        rescue StandardError => e
          Takagi.logger.error "Observer Watcher Error: #{e.message}"
        end
      end

      def stop
        @running = false
        thread = @thread
        return unless thread

        begin
          thread.wakeup if thread.alive?
        rescue ThreadError
          # `Thread#wakeup` raises ThreadError ("killed thread") on a thread that is no
          # longer alive, so a watcher thread that finishes between the liveness check
          # and the wakeup has nothing to wake - the race this guard used to lose. Only a
          # thread that is still alive turns that failure into a real error, so re-raise
          # in that case and tolerate nothing else.
          raise if thread.alive?
        end
        thread.join(2) # Wait max 2 seconds
      end
    end
  end
end
