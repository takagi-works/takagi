# frozen_string_literal: true

module Takagi
  module Server
    class Cluster
      # The contract a transport implements so the ONE cluster supervisor can serve it.
      #
      # The cluster never names a transport: it forks, titles, reaps, respawns, stops and
      # closes only through these methods, so a new transport (QUIC, DTLS, ...) is an
      # adapter rather than a second supervisor. A transport binds its socket ONCE, in its
      # own constructor, and hands the already-bound fd to the cluster: the cluster never
      # binds, never sets SO_REUSEPORT, never re-runs the transport's initializer and never
      # starts the transport's watcher inside a child.
      #
      # Required methods
      # ----------------
      #
      #   #fds             -> Array<IO>
      #     The ALREADY-BOUND sockets this transport declares. The master owns them and
      #     closes them only after every child has stopped; the children inherit them across
      #     the fork. Nothing is bound here.
      #
      #   #serve_loop     -> runs the transport's serve loop in the CURRENT process until
      #     #stop_requested? is true or the loop ends on its own. The cluster forks first
      #     and calls this once per serving process, so a transport builds its per-process
      #     state (handler pools, counters) inside the loop, never before the fork.
      #
      #   #stop_requested? -> true once this serving process must wind its loop down. It
      #     MUST answer true when the cluster's stop flag is set AND when the parent that
      #     forked this process is gone, so an orphan leaves instead of holding an
      #     inherited socket forever.
      #
      #   #stop!          -> asks the serve loop to stop; idempotent and trap-safe.
      #
      #   #prepare_process -> resets per-process state in the serving process; called once
      #     right after the fork (and once for the in-process server) before #serve_loop.
      #
      # Declared facts the cluster reads for observability only (it never branches on them)
      # -----------------------------------------------------------------------------------
      #
      #   #unit_of_work   -> :datagram | :connection | :stream
      #     What one unit of work is for this transport: a QUIC adapter answers :stream
      #     rather than :connection because streams multiplex on one connection.
      #   #thread_count   -> Integer, handler threads in ONE serving process.
      #   #admission_cap  -> Integer or nil, accepted-unit cap PER serving process.
      #   #drain_deadline -> Numeric seconds in-flight work may take to finish once stopped.
      #     MUST be strictly less than Cluster::WORKER_TERM_TIMEOUT, the master's batch
      #     TERM->KILL deadline: a child drains inside the deadline its master allows. It bounds
      #     the in-flight work of WHICHEVER serving shape the transport declares - a handler
      #     pool, one thread per connection, or a shape that has no threads at all - because the
      #     cluster reads this one number and never the shape behind it.
      module Adapter
        # The already-bound sockets this transport declares to the master.
        def fds
          raise NotImplementedError, "#{self.class} must declare #fds (its already-bound sockets)"
        end

        # The transport's serve loop, run once in every serving process.
        def serve_loop
          raise NotImplementedError, "#{self.class} must implement #serve_loop"
        end

        # True once this serving process must stop its loop.
        def stop_requested?
          raise NotImplementedError, "#{self.class} must implement #stop_requested?"
        end

        # Asks the serve loop to stop. Idempotent; safe from a trap context.
        def stop!; end

        # Resets per-process state in the serving process, after the fork and before
        # #serve_loop.
        def prepare_process; end

        # :datagram | :connection | :stream - what one unit of work is here.
        def unit_of_work; end

        # Handler threads in one serving process.
        def thread_count; end

        # Accepted-unit cap per serving process, or nil for no cap.
        def admission_cap; end

        # Seconds in-flight work may take to drain once stopped.
        def drain_deadline; end
      end
    end
  end
end
