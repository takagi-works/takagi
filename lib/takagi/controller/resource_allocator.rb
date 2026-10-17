# frozen_string_literal: true

module Takagi
  class Controller
    # Allocates thread pool resources to controllers
    #
    # Supports two modes:
    # 1. Manual: Controllers specify exact thread counts via profiles
    # 2. Automatic: Divides global pool among controllers based on weights
    #
    # @example Manual allocation
    #   ResourceAllocator.allocate(
    #     controllers: [IngressController, ConfigController],
    #     mode: :manual
    #   )
    #   # IngressController gets profile's thread count (30)
    #   # ConfigController gets profile's thread count (2)
    #
    # @example Automatic allocation
    #   ResourceAllocator.allocate(
    #     controllers: [IngressController, ConfigController, TelemetryController],
    #     mode: :automatic,
    #     total_threads: 40
    #   )
    #   # Divides 40 threads proportionally based on profile weights
    #
    # It allocates THREADS only. A controller's process count is not a pool this allocator
    # can hand out: a worker process serves a whole transport, so per-controller process
    # isolation belongs to a proxy with one backend per controller, not to this allocator.
    class ResourceAllocator
      # Profile weights for automatic allocation
      # Higher weight = more resources
      PROFILE_WEIGHTS = {
        minimal: 1,
        low_traffic: 2,
        long_lived: 8,
        high_throughput: 16,
        large_payloads: 4,
        custom: 4
      }.freeze

      class << self
        # Allocate thread pool resources to controllers
        #
        # @param controllers [Array<Class>] Controller classes to allocate to
        # @param mode [Symbol] :manual or :automatic
        # @param total_threads [Integer] Total threads available (for automatic mode)
        # @return [Hash] Map of controller class => allocation hash
        #
        # @example
        #   allocations = ResourceAllocator.allocate(
        #     controllers: [IngressController, ConfigController],
        #     mode: :manual
        #   )
        #   # => {
        #   #   IngressController => { threads: 30, mode: :manual },
        #   #   ConfigController => { threads: 2, mode: :manual }
        #   # }
        def allocate(controllers:, mode: :automatic, total_threads: nil)
          case mode
          when :manual
            allocate_manual(controllers)
          when :automatic
            allocate_automatic(controllers, total_threads: total_threads)
          else
            raise ArgumentError, "Unknown allocation mode: #{mode}. Use :manual or :automatic"
          end
        end

        # Validate that allocations don't exceed available resources
        #
        # @param allocations [Hash] Controller => allocation map
        # @param total_threads [Integer] Total available threads
        # @raise [ArgumentError] if allocations exceed resources
        def validate!(allocations, total_threads:)
          allocated = allocations.values.sum { |alloc| alloc[:threads] || 0 }

          if allocated > total_threads
            raise ArgumentError,
                  "Controller thread allocations (#{allocated}) exceed available threads (#{total_threads})"
          end

          allocations
        end

        private

        # Manual allocation - use controller's explicit configuration
        def allocate_manual(controllers)
          controllers.each_with_object({}) do |controller_class, allocations|
            threads = controller_class.thread_count

            # A controller that declares no thread count falls back to the minimal profile.
            # The fallback keys on the thread count ALONE: a controller that declares only
            # `processes` must still receive a usable thread count, or the pool loop skips
            # it (Application#start_all_workers! starts a pool only for a positive value).
            threads = Profiles.get(:minimal)[:threads] if threads.nil?

            allocations[controller_class] = {
              threads: threads,
              mode: :manual
            }
          end
        end

        # Automatic allocation - divide total_threads based on profile weights
        def allocate_automatic(controllers, total_threads:)
          raise ArgumentError, 'total_threads required for automatic allocation' unless total_threads

          # Calculate total weight
          total_weight = controllers.sum { |c| controller_weight(c) }

          # Allocate proportionally
          allocations = {}
          remaining_threads = total_threads

          controllers.each_with_index do |controller_class, index|
            weight = controller_weight(controller_class)

            # Last controller gets remainder to avoid rounding issues
            if index == controllers.length - 1
              threads = remaining_threads
            else
              threads = (total_threads * weight / total_weight.to_f).round
              threads = [threads, 1].max  # Minimum 1 thread
              remaining_threads -= threads
            end

            allocations[controller_class] = {
              threads: threads,
              mode: :automatic,
              weight: weight
            }
          end

          allocations
        end

        # Get weight for a controller based on its profile
        def controller_weight(controller_class)
          profile_name = controller_class.profile_name || :minimal
          PROFILE_WEIGHTS[profile_name] || PROFILE_WEIGHTS[:custom]
        end
      end
    end
  end
end
