# frozen_string_literal: true

module Takagi
  module Observer
    # Boot surface servers start. Notification is driven by state change ({Takagi::Topic
    # #publish}), never by an interval (design D9), so this thread notifies nothing: the
    # old per-path re-run of observable blocks was removed from the notification path.
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
          sleep @interval while @running
        rescue StandardError => e
          Takagi.logger.error "Observer Watcher Error: #{e.message}"
        end
        @thread
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
