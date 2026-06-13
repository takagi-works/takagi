# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'net/http'
require 'tmpdir'
require 'uri'

module Takagi
  module Middleware
    # Request/response metrics collector with cross-process aggregation.
    #
    # Each Metrics instance keeps per-process counters and periodically
    # flushes a JSON snapshot to `<output_dir>/<pid>.json`. The class
    # method `Metrics.aggregate(output_dir:)` reads every pid file in the
    # directory and merges them into a single view. This works across
    # `fork`-based worker pools (each worker writes its own file, the
    # devtools HTTP endpoint in the parent reads them all).
    #
    # All times are stored as Float seconds (monotonic) internally and
    # exposed as milliseconds in snapshots.
    class Metrics
      LATENCY_WINDOW = 200
      RATE_BUCKETS   = 60

      attr_reader :metrics
      attr_reader :forward_to

      def initialize(output_dir: self.class.default_output_dir, flush_interval: 0.5, forward_to: nil)
        @metrics = default_metrics
        @mutex = Mutex.new
        @output_dir = output_dir
        @flush_interval = flush_interval
        @forward_to = forward_to
        @pid = Process.pid
        @last_flush = monotonic
        @forward_queue = Queue.new
        @forward_thread = nil
        @forward_thread_url = nil

        FileUtils.mkdir_p(@output_dir) unless File.directory?(@output_dir)
      end

      attr_writer :forward_to

      # Resolve the effective forward URL — either the literal value
      # (String/URI) passed at construction or a fresh value from a
      # callable. Lets a Metrics instance defer URL discovery until the
      # first request is being processed (e.g. devtools' ingest endpoint
      # is bound by the sinatra plugin *after* Metrics is installed).
      def forward_url
        @forward_to.is_a?(Proc) ? @forward_to.call : @forward_to
      end

      def call(request)
        @mutex.synchronize { @metrics[:requests] += 1 }

        start = monotonic
        response = yield request
        latency = monotonic - start

        record(request, response, latency)
        flush_if_due
        notify_forward(request, response, latency)
        response
      end

      # Bump the top-level request counter without going through `call`
      # (which would also start a timer and re-enter the forward chain).
      # Used by external aggregators like the devtools ingest endpoint
      # that build metric records out-of-band.
      def increment_request_count
        @mutex.synchronize { @metrics[:requests] += 1 }
      end

      def record_observer_notification
        @mutex.synchronize { @metrics[:observer_notifications] += 1 }
        flush_if_due
      end

      # Snapshot for the LOCAL process only (used by tests / single-process mode).
      def snapshot
        @mutex.synchronize { build_snapshot }
      end

      # Flush the snapshot to <output_dir>/<pid>.json regardless of interval.
      def flush!
        snapshot = @mutex.synchronize do
          snap = build_snapshot
          @last_flush = monotonic
          snap
        end
        write_snapshot(snapshot)
      end

      # Record a request/response/latency into the local metrics. Public so
      # external aggregators (e.g. devtools' HTTP ingest endpoint) can
      # inject pre-aggregated data without going through the middleware
      # chain. Thread-safe.
      def record(request, response, latency)
        code = extract_code(response)
        code_class = code_class_for(code)

        @mutex.synchronize do
          @metrics[:responses][code_class] += 1 if code_class
          @metrics[:last_code] = code_name(code) || @metrics[:last_code]
          @metrics[:latency] = latency

          now_ms = (Time.now.to_f * 1000).round
          ms = (latency * 1000).round(3)
          @metrics[:latency_series] << { x: now_ms, y: ms }
          @metrics[:latency_series].shift while @metrics[:latency_series].size > LATENCY_WINDOW

          key = route_key(request)
          route = (@metrics[:routes][key] ||= new_route_stat)
          route[:count] += 1
          route[:lat_sum] += latency
          route[:last] = latency
          route[:codes][code_class] += 1 if code_class
        end
      end

      # @return [String] the directory where per-PID snapshots are written.
      def output_dir
        @output_dir
      end

      # @return [Integer] the PID that owns this Metrics instance.
      def pid
        @pid
      end

      def self.default_output_dir
        ENV.fetch('TAKAGI_METRICS_DIR', File.join(Dir.tmpdir, 'takagi-metrics'))
      end

      # Read every <output_dir>/*.json file, parse, and merge into a single
      # aggregate snapshot. Stale or malformed files are skipped.
      # @return [Hash] aggregated snapshot
      def self.aggregate(output_dir: default_output_dir)
        return empty_aggregate unless File.directory?(output_dir)

        totals = empty_aggregate
        alive_pids = alive_process_pids

        Dir["#{output_dir}/*.json"].each do |file|
          data = JSON.parse(File.read(file))
          next unless data.is_a?(Hash)
          # Skip snapshots from PIDs that no longer exist (stale).
          pid = data['pid']
          next if pid && !alive_pids.include?(pid)

          merge_into!(totals, data)
        rescue StandardError, JSON::ParserError
          next
        end
        totals
      end

      def self.alive_process_pids
        require 'etc'
        Dir['/proc/[0-9]*'].map { |e| e.split('/').last.to_i }
      rescue StandardError
        []
      end

      private

      def flush_if_due
        return if monotonic - @last_flush < @flush_interval

        snapshot = @mutex.synchronize do
          snap = build_snapshot
          @last_flush = monotonic
          snap
        end
        write_snapshot(snapshot)
      rescue StandardError
        nil
      end

      # Fire-and-forward HTTP POST of the per-request metric to @forward_to.
      # Uses a single background consumer thread (lazy-started on first
      # request) plus an unbounded Queue, so producers stay non-blocking
      # (just `Queue#push`) and no request is ever dropped due to a
      # thread cap. Network errors are silently swallowed (this is
      # best-effort, dev-only aggregation). The consumer thread restarts
      # itself if the URL changes (e.g. a lambda returns a different port
      # after the sinatra plugin rebinds).
      def notify_forward(request, response, latency)
        url = forward_url
        return unless url

        payload = JSON.generate(
          method: request.respond_to?(:method) ? request.method : 'GET',
          path: route_path(request),
          code: extract_code(response),
          latency_ms: (latency * 1000).round(3)
        )

        ensure_forward_thread(url)
        @forward_queue << payload
      end

      # Lazy-start (or restart) the consumer thread for `url`. Called
      # from the request hot path, so the work is bounded: a single
      # `Thread.new` when no thread is alive yet, or a no-op when one is.
      def ensure_forward_thread(url)
        @mutex.synchronize do
          if @forward_thread.nil? || !@forward_thread.alive? || @forward_thread_url != url
            @forward_thread = Thread.new { forward_loop(url) }
            @forward_thread.report_on_exception = false
            @forward_thread_url = url
          end
        end
      end

      def forward_loop(url)
        loop do
          payload = @forward_queue.pop
          do_forward(url, payload)
        end
      end

      def do_forward(url, payload)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 0.5
        http.read_timeout = 0.5
        http.post(uri.request_uri, payload, 'Content-Type' => 'application/json')
      rescue StandardError
        nil
      end

      def route_path(request)
        return request.uri.path if request.respond_to?(:uri) && request.uri

        'unknown'
      end

      def write_snapshot(snapshot)
        file = "#{@output_dir}/#{@pid}.json"
        tmp = "#{file}.tmp"
        File.write(tmp, JSON.generate(snapshot))
        File.rename(tmp, file)
      end

      def build_snapshot
        now_ms = (Time.now.to_f * 1000).round
        window_start_ms = now_ms - (RATE_BUCKETS * 1000)
        recent = @metrics[:latency_series].count { |p| p[:x] >= window_start_ms }
        rps = recent.to_f / RATE_BUCKETS

        {
          pid: @pid,
          written_at_ms: now_ms,
          requests: @metrics[:requests],
          latency_ms: (@metrics[:latency] * 1000).round(3),
          last_code: @metrics[:last_code],
          responses: @metrics[:responses].dup,
          obs_events: @metrics[:observer_notifications],
          latency_avg_ms: compute_latency_avg_ms,
          latency_series: @metrics[:latency_series].dup,
          current_rps: rps.round(2),
          routes: serialize_routes
        }
      end

      def default_metrics
        {
          requests: 0,
          latency: 0.0,
          last_code: nil,
          responses: { '2xx' => 0, '4xx' => 0, '5xx' => 0, 'other' => 0 },
          observer_notifications: 0,
          latency_series: [],
          routes: {}
        }
      end

      def extract_code(response)
        if response.respond_to?(:code)
          return response.code
        end

        case response
        when Hash, String, Array, Integer, Float, TrueClass, FalseClass, Symbol
          Takagi::CoAP::Registries::Response::CONTENT
        when Array
          response[0]
        end
      end

      def code_class_for(code)
        return nil unless code.is_a?(Integer)

        case code / 32
        when 2 then '2xx'
        when 4 then '4xx'
        when 5 then '5xx'
        else 'other'
        end
      end

      def code_name(code)
        return nil unless code.is_a?(Integer) && defined?(Takagi::CoAP::CodeHelpers)

        Takagi::CoAP::CodeHelpers.to_string(code)
      rescue StandardError
        nil
      end

      def route_key(request)
        method = if request.respond_to?(:method)
                   request.method
                 elsif request.respond_to?(:code)
                   Takagi::CoAP::CodeHelpers.to_string(request.code) rescue 'GET'
                 else
                   'GET'
                 end
        path = if request.respond_to?(:uri) && request.uri
                 request.uri.path
               else
                 'unknown'
               end
        "#{method} #{path}"
      end

      def new_route_stat
        { count: 0, lat_sum: 0.0, last: 0.0, codes: Hash.new(0) }
      end

      def compute_latency_avg_ms
        series = @metrics[:latency_series]
        return 0.0 if series.empty?

        (series.sum { |p| p[:y] } / series.size).round(3)
      end

      def serialize_routes
        @metrics[:routes].map do |key, stat|
          count = stat[:count]
          avg = count.positive? ? (stat[:lat_sum] / count * 1000).round(3) : 0.0
          last_ms = (stat[:last] * 1000).round(3)
          error_rate = count.positive? ? ((stat[:codes]['4xx'].to_i + stat[:codes]['5xx'].to_i) / count.to_f * 100).round(1) : 0.0
          {
            route: key,
            count: count,
            avg_ms: avg,
            last_ms: last_ms,
            codes: stat[:codes].dup,
            error_rate_pct: error_rate
          }
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # === class-level helpers for aggregation ===

      def self.empty_aggregate
        {
          requests: 0,
          latency_ms: 0.0,
          last_code: nil,
          responses: { '2xx' => 0, '4xx' => 0, '5xx' => 0, 'other' => 0 },
          obs_events: 0,
          latency_avg_ms: 0.0,
          latency_series: [],
          current_rps: 0.0,
          routes: [],
          pids: []
        }
      end

      def self.merge_into!(totals, data)
        totals[:requests] += data['requests'].to_i
        # Last seen wins (whichever process wrote last has the freshest latency)
        if data['latency_ms']
          totals[:latency_ms] = data['latency_ms'].to_f if data['latency_ms'].to_f > totals[:latency_ms]
        end
        if data['last_code'] && !totals[:last_code]
          totals[:last_code] = data['last_code']
        end

        if data['responses'].is_a?(Hash)
          data['responses'].each do |k, v|
            totals[:responses][k] = (totals[:responses][k] || 0) + v.to_i
          end
        end

        totals[:obs_events] += data['obs_events'].to_i

        if data['latency_series'].is_a?(Array)
          combined = totals[:latency_series] + data['latency_series']
          combined.sort_by! { |p| p['x'] || p[:x] }
          totals[:latency_series] = combined.last(LATENCY_WINDOW)
        end

        totals[:current_rps] += data['current_rps'].to_f

        if data['routes'].is_a?(Array)
          data['routes'].each do |route|
            existing = totals[:routes].find { |r| r['route'] == route['route'] }
            if existing
              existing['count'] = (existing['count'] || 0) + route['count'].to_i
              existing_count_total = (existing['count'] || 0)
              existing_count_old = existing_count_total - route['count'].to_i
              if existing_count_old.positive?
                total_lat = (existing['avg_ms'] || 0) * existing_count_old +
                            (route['avg_ms'] || 0) * route['count'].to_i
                existing['avg_ms'] = (total_lat / existing_count_total).round(3)
              else
                existing['avg_ms'] = route['avg_ms']
              end
              existing['last_ms'] = route['last_ms']
              if route['codes'].is_a?(Hash)
                route['codes'].each do |k, v|
                  existing['codes'][k] = (existing['codes'][k] || 0) + v.to_i
                end
              end
              err_count = (existing['codes']['4xx'] || 0) + (existing['codes']['5xx'] || 0)
              existing['error_rate_pct'] = (err_count.to_f / existing_count_total * 100).round(1)
            else
              totals[:routes] << route.dup
            end
          end
        end

        if data['pid']
          totals[:pids] << data['pid'] unless totals[:pids].include?(data['pid'])
        end

        totals
      end
    end
  end
end
