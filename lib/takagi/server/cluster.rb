# frozen_string_literal: true

require_relative 'cluster/adapter'

module Takagi
  module Server
    # The ONE worker supervisor for a Takagi service.
    #
    # It owns the already-bound sockets of every transport a service exposes plus one
    # {Cluster::Adapter} per transport, and it never names a transport: fork, title, reap,
    # respawn, stop and close all run through the adapter contract (see {Cluster::Adapter}),
    # so a new transport is an adapter rather than a second supervisor.
    #
    # At `count == 1` there is nothing to supervise: every adapter's serve loop runs in THIS
    # process and no child is forked. Above 1 this process becomes the master: it forks
    # `count` children indexed `0..count-1`, each titled `takagi-worker-<index>`, tracks the
    # pids by index, reaps and REPLACES one-for-one (exactly one WARN per death, naming pid,
    # index, status and the replacement), and ends LOUDLY when the last child is gone. The
    # master's pid is captured BEFORE the fork and handed to the child, so a child never
    # reads Process.ppid after the fork: that race is what would let an orphan serve forever.
    #
    # The supervision wait is event-driven: a CHLD handler writes to a self-pipe and the loop
    # selects on it, so a child's death wakes the loop at once. {SUPERVISION_POLL_INTERVAL}
    # only bounds an otherwise quiet wait.
    class Cluster # rubocop:disable Metrics/ClassLength -- one cohesive supervisor (fork, index bookkeeping, reap/respawn, ordered batch stop, event-driven wait); splitting it across files is a separate refactor, the same trade-off tcp.rb records
      # How long the whole batch of children may take to honour TERM before the master
      # escalates to KILL. Absolute for the batch, so total shutdown stays bounded no matter
      # how many workers are configured.
      #
      # This is the OUTER half of the ONE drain contract every transport shares, and the two
      # numbers have a fixed ORDER: on TERM/INT a child stops accepting, finishes its in-flight
      # work inside the drain deadline IT declares (`Adapter#drain_deadline`, enforced by the
      # transport's own stop path next to the constant it names - `Tcp::POOL_JOIN_TIMEOUT` for
      # the handler pool's join, `Udp::DRAIN_DEADLINE` for the datagram readers' join), and only
      # then does it leave. This batch deadline must therefore be STRICTLY LARGER than every
      # declared drain deadline (`WORKER_TERM_TIMEOUT > adapter.drain_deadline`), or the KILL
      # that escorts a child out would preempt a drain still inside the deadline it promised. It
      # is ALSO the cap on the join that closes a serve phase (#serve_end_budget), so a child
      # serving several transports cannot have a drain cut by that join either. The relation is
      # asserted where both numbers meet, at construction (#assert_drain_fits_the_batch), rather
      # than left as prose in two files.
      WORKER_TERM_TIMEOUT = 2.0

      # Bounded fallback for the event-driven supervision wait. The self-pipe wakes the loop
      # the moment a child dies or a stop is requested; this only caps a quiet wait.
      SUPERVISION_POLL_INTERVAL = 0.5

      # The process-title prefix: `takagi-worker-<index>`, with no transport in it, so the
      # process table names a worker of THIS service rather than of a protocol.
      TITLE_PREFIX = 'takagi-worker'

      attr_reader :worker_pids, :count

      # @param count [Integer] worker processes serving this service. 1 serves in-process.
      # @param adapters [Array<Cluster::Adapter>] one adapter per transport this service
      #   exposes, each declaring its already-bound sockets.
      # @param logger [#info, #warn, #error] where deaths and the loud end are reported.
      def initialize(count:, adapters:, logger:)
        @count = count.to_i
        @adapters = Array(adapters)
        assert_drain_fits_the_batch
        @logger = logger
        @worker_pids = nil
        @worker_indexes = {}
        @stopping = false
        @signal_stop = false
        @parent_pid = nil
        @wake_reader = nil
        @wake_writer = nil
      end

      # True when this service is served by forked children. A count of 1, or a platform
      # without fork, keeps the single-process shape: this process serves and forks nothing.
      def forking?
        @count > 1 && Process.respond_to?(:fork)
      end

      # Runs the cluster, then performs the ordered teardown (children first, this process's
      # copies of the listeners last). Returns :exhausted when the last child died and the
      # service must end LOUDLY, and :stopped for an ordinary stop.
      def run!
        install_signal_handlers
        outcome = if forking?
                    with_wake_pipe do
                      spawn_workers
                      supervise_workers
                    end
                  else
                    serve_in_process
                  end
        shutdown!
        outcome
      end

      # Requests a stop and wakes the supervision wait so the stop is seen at once.
      def stop!
        @stopping = true
        wake!
      end

      # True once this process must stop serving. In a child this also covers the
      # parent-death guard, so an orphan leaves instead of holding an inherited socket.
      #
      # A stop a SIGNAL asked THIS process for counts here for the process's whole life
      # (`@signal_stop`): the trap that records it is armed before any fork, so a child can be
      # handed TERM while its own reset is still running - and that reset, which drops the
      # MASTER's stop state, must not drop this process's own stop with it.
      def stopping?
        @signal_stop || @stopping || orphaned?
      end

      # A child whose master disappeared must not keep the sockets for itself. The master
      # pid was captured before the fork and handed to the child, so this only ever fires in
      # a child and never races the master's death.
      def orphaned?
        !@parent_pid.nil? && Process.ppid != @parent_pid
      end

      # Stops every child, then closes the master's own copies of the listeners - in that
      # order, so no child is left serving a socket the master has already closed.
      def shutdown!
        stop!
        terminate_workers
        close_listeners
      end

      private

      # ONE rule, ONE meaning, asserted where both numbers meet: EVERY declared drain deadline
      # sits strictly inside the master's batch deadline, which is ALSO the cap on the join that
      # closes a serve phase (#serve_end_budget). Both halves follow from that single comparison:
      # the join budget - the longest declared drain - is at least as long as each adapter's own
      # deadline (so the join cannot cut a drain), and still shorter than the batch (so the KILL
      # cannot either). An adapter that declares no deadline (nil) has no in-flight window to
      # protect and is skipped. Raised at construction, so a misconfigured service fails before a
      # single fork rather than as a response lost mid-drain.
      def assert_drain_fits_the_batch
        @adapters.each do |adapter|
          deadline = adapter.respond_to?(:drain_deadline) ? adapter.drain_deadline : nil
          next if deadline.nil? || deadline < WORKER_TERM_TIMEOUT

          raise ArgumentError, "#{adapter.class} declares drain_deadline #{deadline}s, which is not " \
                               "strictly below Cluster::WORKER_TERM_TIMEOUT (#{WORKER_TERM_TIMEOUT}s): " \
                               'the master would KILL, or the serve-end join would cut, a child still ' \
                               'inside its drain contract'
        end
      end

      # At count 1 this process serves every adapter itself and forks nothing.
      def serve_in_process
        with_wake_pipe { serve_all }
        :stopped
      end

      # The master answers TERM/INT itself: the stop flag plus a wake of the supervision wait.
      # The ordered stop that follows is shutdown!'s, so children always stop before this
      # process closes its copies of the listeners.
      def install_signal_handlers
        trap('TERM') { stop_by_signal! }
        trap('INT') { stop_by_signal! }
      end

      # Records the stop a SIGNAL asked this process for. Unlike #stop!, the record is not
      # {#reset_child_state}'s to clear: see #stopping? for why a child's own TERM has to
      # outlive that reset.
      def stop_by_signal!
        @signal_stop = true
        stop!
      end

      # Runs every adapter's serve loop in this process. A single adapter runs inline, exactly
      # as its transport's loop ran when it served alone; several run on their own threads and
      # are joined once the stop flag is set or the loops end on their own.
      def serve_all
        @adapters.each(&:prepare_process)
        return @adapters.first.serve_loop if @adapters.size == 1

        threads = @adapters.map { |adapter| Thread.new { adapter.serve_loop } }
        await_serve_end(threads)
      end

      # Closes the serve phase: every adapter is told to stop, then the serve threads are given
      # the time a DRAIN actually needs - the longest drain any of this cluster's adapters
      # declares - and a thread still inside its transport's deadline is signalled rather than
      # waited on past it. The threads run CONCURRENTLY, so the longest declared drain is the
      # whole wall-clock need; joining them for the poll interval, as this once did, cut a drain
      # that was still inside the deadline its transport had promised.
      def await_serve_end(threads)
        loop do
          break if stopping?
          break if threads.none?(&:alive?)

          await_event
        end
        @adapters.each(&:stop!)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + serve_end_budget
        threads.each do |thread|
          thread.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
          thread.kill if thread.alive?
        end
      end

      # How long a serve phase may spend closing: the LONGEST drain any adapter declares, capped
      # by the one named number that governs the batch, WORKER_TERM_TIMEOUT.
      # #assert_drain_fits_the_batch proves every declared drain sits strictly below that cap, so
      # this budget is at least as long as every adapter's own deadline and still shorter than
      # the master's TERM->KILL - neither the join nor the KILL can cut a drain still inside its
      # contract. An adapter that declares no drain deadline contributes nothing.
      def serve_end_budget
        declared = @adapters.filter_map do |adapter|
          adapter.respond_to?(:drain_deadline) ? adapter.drain_deadline : nil
        end
        [declared.max || 0, WORKER_TERM_TIMEOUT].min
      end

      def spawn_workers
        @worker_pids = []
        @worker_indexes = {}
        @count.times do |index|
          pid = fork_worker(index)
          @worker_pids << pid
          @worker_indexes[pid] = index
        end
      end

      def fork_worker(index)
        # Captured BEFORE the fork on purpose: the child reads this local copy, so it still
        # knows the master's pid when the master dies before the child is ever scheduled.
        master_pid = Process.pid
        fork do
          Process.setproctitle("#{TITLE_PREFIX}-#{index}")
          reset_child_state(master_pid)
          serve_all
          exit!(0)
        end
      end

      # A child owns no siblings and none of the master's state: it never inherits the pid
      # list, never runs supervision, remembers the pre-fork parent for the orphan guard,
      # drops the inherited supervision pipe, and answers TERM/INT itself. It drops the
      # MASTER's stop flag too - but NOT `@signal_stop`, the stop a signal already asked THIS
      # process for: a TERM that lands between the fork and this line is this child's own stop,
      # and clearing it left the worker serving on until the master's KILL.
      def reset_child_state(master_pid)
        close_wake_pipe
        @worker_pids = []
        @worker_indexes = {}
        @parent_pid = master_pid
        @stopping = false
        open_wake_pipe
        trap('CHLD', 'DEFAULT')
        trap('TERM') { stop_by_signal! }
        trap('INT') { stop_by_signal! }
      end

      # Reaps and REPLACES: a child that died between polls is replaced by a new one carrying
      # its index, so the configured count is restored instead of the sockets quietly losing
      # a worker. One pass reaps every dead child, so a total failure is seen at once. When
      # the last child is gone there is nobody left to serve with, so supervision ends and
      # the master reports it LOUDLY.
      def supervise_workers
        loop do
          break if stopping?

          dead = reap_workers
          if @worker_pids.empty?
            @logger.error worker_exhaustion_message(dead)
            return :exhausted
          end

          respawn_workers(dead) unless dead.empty?
          await_event
        end
        :stopped
      end

      # Reaps every dead child in one pass and reports it as [pid, status, index]. Logging is
      # not done here: the caller pairs each death with the replacement it forks, so one
      # death produces exactly one line and that line never lacks the replacement. [] when
      # nothing died.
      def reap_workers
        return [] unless @worker_pids.is_a?(Array)

        dead = []
        alive = []
        @worker_pids.each do |pid|
          status = reap_status(pid)
          case status
          when :consumed_by_another_reaper then next
          when nil then alive << pid
          else dead << [pid, status, @worker_indexes[pid]]
          end
        end
        @worker_pids = alive
        dead
      end

      # The status of one child, or :consumed_by_another_reaper when a SECOND reaper already
      # collected it. Errno::ECHILD means exactly that and nothing else: the pid is no longer
      # this process's child because somebody reaped it, so it is neither an error to report
      # nor a child to replace.
      def reap_status(pid)
        _pid, status = Process.waitpid2(pid, Process::WNOHANG)
        status
      rescue Errno::ECHILD
        :consumed_by_another_reaper
      end

      # Keeps the configured count: one replacement per death, forked with the dead worker's
      # own index so its title and the log line both stay truthful, and exactly one WARN per
      # death naming the pid, its index, its status and the pid that replaced it.
      def respawn_workers(dead)
        dead.each do |pid, status, index|
          break if stopping?

          replacement = fork_worker(index)
          @worker_pids << replacement
          @worker_indexes[replacement] = index
          @logger.warn "worker #{pid} (index #{index}) exited with #{status.inspect}; " \
                       "respawned as #{replacement}"
        end
      end

      def worker_exhaustion_message(dead)
        detail = if dead.empty?
                   'no worker was reaped in this pass'
                 else
                   dead.map { |pid, status, index| "#{pid} (index #{index}) #{status.inspect}" }.join(', ')
                 end
        "worker supervision: all workers are gone (#{detail}); shutting down"
      end

      # Stops every child, TERM first and KILL only once the batch's deadline is gone. Both
      # halves are bounded: the deadline is absolute for the batch, so a worker that ignores
      # TERM cannot be waited on unboundedly after an earlier pid ate the deadline.
      def terminate_workers
        return unless @worker_pids.is_a?(Array)

        pids = @worker_pids.dup
        @worker_pids = []
        pids.each { |pid| signal('TERM', pid) }

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKER_TERM_TIMEOUT
        pids.each { |pid| await_worker_exit(pid, deadline) }
      end

      def signal(name, pid)
        Process.kill(name, pid)
      rescue Errno::ESRCH
        nil
      end

      def await_worker_exit(pid, deadline)
        loop do
          return if worker_exited?(pid)

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return force_kill(pid) if remaining <= 0

          await_event([remaining, SUPERVISION_POLL_INTERVAL].min)
        end
      end

      # True once the worker is gone, whether this poll reaped it or supervision already did.
      def worker_exited?(pid)
        Process.waitpid(pid, Process::WNOHANG) ? true : false
      rescue Errno::ECHILD
        true
      end

      def force_kill(pid)
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def close_listeners
        @adapters.each do |adapter|
          adapter.fds.each { |fd| close_quietly(fd) }
        end
      end

      def close_quietly(io)
        io.close if io && !io.closed?
      rescue IOError, SystemCallError
        nil
      end

      # The event-driven supervision wait: the CHLD handler writes a byte, the loop waits on the
      # read end, and the timeout only bounds a quiet wait. The wait on that one IO is the
      # self-pipe select (IO#wait_readable), so a pipe closed during teardown simply degrades to
      # the timeout.
      #
      # The ivar is read ONCE into a local: `close_wake_pipe` nils it from the run! thread's
      # `with_wake_pipe` ensure while a concurrent `shutdown!` may already be inside this call,
      # so a check-then-use on the ivar could read a live reader at the check and nil at the
      # use - `NoMethodError: undefined method 'wait_readable' for nil` inside the supervisor's
      # own shutdown. A nil local is that pipe already closed, and the teardown which closed it
      # IS the event this wait is for, so the wait degrades to the bounded select; a reader
      # closed after the local was taken raises IOError, which the rescue treats as that same
      # event having fired.
      def await_event(timeout = SUPERVISION_POLL_INTERVAL)
        reader = @wake_reader
        if reader.nil?
          IO.select(nil, nil, nil, timeout)
        else
          reader.wait_readable(timeout)
          drain_wake_pipe(reader)
        end
        nil
      rescue IOError, Errno::EBADF
        nil
      end

      def drain_wake_pipe(reader)
        loop { reader.read_nonblock(4096) }
      rescue IO::WaitReadable, IOError, Errno::EBADF
        nil
      end

      def wake!
        @wake_writer&.write_nonblock('.')
      rescue IO::WaitWritable, Errno::EPIPE, IOError, Errno::EBADF
        nil
      end

      def open_wake_pipe
        @wake_reader, @wake_writer = IO.pipe
      end

      def close_wake_pipe
        [@wake_reader, @wake_writer].each { |io| close_quietly(io) }
        @wake_reader = nil
        @wake_writer = nil
      end

      def with_wake_pipe
        open_wake_pipe
        previous = trap('CHLD') { wake! }
        begin
          yield
        ensure
          trap('CHLD', previous)
          close_wake_pipe
        end
      end
    end
  end
end
