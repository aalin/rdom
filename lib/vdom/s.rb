require "async"
require "async/barrier"
require "async/condition"
require "async/notification"
require "async/queue"
require "async/semaphore"

module VDOM
  module S
    module Utils
      def self.with_fiber_local(name, value)
        prev, Fiber[name] = Fiber[name], value
        yield value
      ensure
        Fiber[name] = prev
      end
    end

    class Sources
      Source = Data.define(:source, :version, :task) do
        def version_changed? =
          version != source.version
      end

      def initialize(task: Async::Task.current)
        @sources = {}
        @barrier = Async::Barrier.new(parent: task)
        @condition = Async::Condition.new
      end

      def add(source) =
        @sources[source] ||=
          Source.new(
            source,
            source.version,
            @barrier.async do
              # puts "\e[2;32mSubscribing #{Computation.current.inspect} to #{source.inspect}\e[0m"
              @condition.signal(source.wait)
              @barrier.stop
            end
          )
      def wait =
        @condition.wait
      def empty? =
        @condition.empty?
      def changed? =
        @sources.values.any?(&:version_changed?)

      def clear
        @barrier.stop
      ensure
        @sources.clear
      end
    end

    class Reactive
      CacheClean = 0
      CacheCheck = 1
      CacheDirty = 2

      def self.tracking? =
        Fiber[:tracking?] != false
      def self.track(&) =
        Utils.with_fiber_local(:tracking?, true, &)
      def self.untrack(&) =
        Utils.with_fiber_local(:tracking?, false, &)
      def self.current_reaction =
        (Fiber[:current_reaction] if tracking?)

      def initialize
        @root = Root.current!
        @condition = Async::Condition.new
        @version = -1
      end

      attr_reader :version

      def wait =
        @condition.wait
      def peek =
        @value

      def value
        Reactive.current_reaction&.add_source(self)
        update
        @value
      end

      private

      attr_reader :root

      def notify(state) =
        @condition.signal(state)
      def update =
        nil
    end

    class Signal < Reactive
      def initialize(value)
        super()
        @version = -1
        @value = value
        @state = CacheClean
      end

      def value=(new_value)
        return if @value == new_value

        @value = new_value
        @version += 1

        root.increment_version!

        root.batch do
          notify(CacheDirty)
        end
      end

      def inspect =
        "#<#{self.class.name}@#@version value=#{@value.inspect}>"
    end

    class Computation < Reactive
      def inspect = [
        "#{self.class.name}@#@version",
        "value=#{@value.inspect}",
        @compute.source_location.join(":")
      ].join(" ").prepend("#<").concat(">")

      def initialize(task: Async::Task.current, &compute)
        super()
        @version = -1
        @root_version = root.version.pred
        @compute = compute
        @sources = Sources.new
        @state = CacheDirty
        @semaphore = Async::Semaphore.new

        @task = task.async do
          loop do
            if state = @sources.wait
              @semaphore.acquire do
                if @state < state
                  enqueue_effect
                  notify(CacheCheck)
                  @state = state
                end
              end
            end
          end
        rescue => e
          Console.logger.error(self, e)
        ensure
          cleanup
        end

        update if effect?
      end

      def stop =
        @task.stop

      def add_source(source) =
        @sources.add(source)

      private

      def effect? =
        false
      def enqueue_effect =
        nil
      def cleanup =
        @sources.clear

      def update
        return if @state == CacheClean

        return if up_to_date?
        return unless sources_changed?

        @semaphore.acquire do
          previous_value = @value

          cleanup

          Utils.with_fiber_local(:current_reaction, self) do
            @value = @compute.call
          end

          unless previous_value == @value
            @version += 1
            notify(CacheDirty)
          end

          @state = CacheClean
        end
      end

      def up_to_date?
        root_version = root.version

        if @root_version == root_version
          true
        else
          @root_version = root_version
          false
        end
      end

      def sources_changed?
        if @version > 0
          @sources.changed?
        else
          true
        end
      end
    end

    class Effect < Computation
      def initialize(...)
        @cleanups = []
        super(...)
      end

      def on_cleanup(&block) =
        @cleanups.push(block)

      private

      def effect? =
        true

      def enqueue_effect
        return unless @state == CacheClean
        Root.current!.enqueue(self)
      end

      def cleanup
        super

        Reactive.untrack do
          while cleanup = @cleanups.shift
            cleanup.call
          end
        end
      rescue => e
        Console.logger.error(self, e)
      end
    end

    class Root
      CURRENT_KEY = :"VDOM::S::Root.current"
      NoReactiveRootError = Class.new(StandardError)

      def self.current =
        Fiber[CURRENT_KEY]
      def self.current! =
        current || raise(NoReactiveRootError, "There is no reactive root")

      def self.run(task: Async::Task.current, &)
        root = new

        root.async do
          yield
        rescue => e
          Console.logger.error(self, e)
        ensure
          root.stop
        end

        root
      end

      def initialize(parent: self.class.current, task: Async::Task.current)
        @parent = parent
        @queue = Async::Queue.new
        @version = 0
        @batching = false
        @barrier = Async::Barrier.new(parent: task)
      end

      attr_reader :version

      def increment_version!
        @version += 1
      end

      def async(&) =
        @barrier.async do
          Fiber[CURRENT_KEY] = self
          Fiber[:current_reaction] = nil
          yield
        end

      def wait = @barrier.wait
      def stop = @barrier.stop

      def batch(&)
        if @batching
          yield and return
        end

        @batching = true

        begin
          yield
        rescue
          raise
        ensure
          flush!
          @batching = false
        end
      end

      def enqueue(effect)
        @queue.enqueue(effect)
      end

      def flush!
        puts  "\e[3m FLUSH #{@queue.size} \e[0m"

        @queue.size.times do
          @queue.dequeue.value
        end
      end
    end

    module Helpers
      def root(&) = Root.run(&)

      def signal(value) = Signal.new(value)
      def computed(&) = Computation.new(&)
      def effect(&) = Effect.new(&)

      def batch(&) = Root.current!.batch(&)

      def track(&) = Reactive.track(&)
      def untrack(&) = Reactive.untrack(&)
      def tracking? = Reactive.tracking?

      def on_cleanup(&)
        Reactive.current_reaction => Effect => effect
        effect.on_cleanup(&)
      end
    end

    module Refinements
      refine Kernel do
        import_methods Helpers
      end
    end

    extend Helpers
  end
end

if $0 == __FILE__
  def title(str, *attrs)
    puts "\e[3;#{attrs.join(":")}m #{str} \e[0m"
  end

  S = VDOM::S

  Async do
    title "******************", 35
    title "*** FIRST TEST ***", 35
    title "******************", 35

    S.root do
      s1 = S.signal(0)
      s2 = S.signal(0)
      s3 = S.signal(0)

      c = S.computed do
        if s1.value > 0
          p(s1: s1.value, s3: s3.value)
        else
          p(s3: s3.value, s2: s2.value)
        end
      end

      e = S.effect do
        puts "c.value: #{c.value.inspect}"
      end

      sleep 0.1
      s1.value += 1
      sleep 0.1
      s2.value += 1
      sleep 0.1
      s3.value += 1
      sleep 0.1
      s1.value += 1
      sleep 0.1
      s2.value += 1
      sleep 0.1
      s3.value += 1
      sleep 0.1
      s1.value += 1
      sleep 0.1
      s2.value += 1
      sleep 0.1
      s3.value += 1

      c.stop
      e.stop
    end.wait

    title "*******************", 35
    title "*** SECOND TEST ***", 35
    title "*******************", 35

    S.root do
      a = S.signal(0)
      b = S.signal(0)

      c = S.computed do
        v = a.value + b.value
        p(c: v)
        v
      end

      d = S.computed do
        v = b.value * 2
        p(d: v)
        v
      end

      e = S.effect do
        v = c.value + d.value
        p(e: v)
      end

      f = S.effect do
        p(f: { a: a.value, b: b.value })

        S.on_cleanup do
          puts "f on cleanup"
        end
      end

      sleep 0.1

      title("Updating a", 33)
      a.value += 1

      sleep 0.1

      title("Updating a", 33)
      a.value += 1

      sleep 0.1

      title("Updating b", 33)
      b.value += 1

      sleep 0.1

      title("Updating a and b", 33)
      S.batch do
        a.value += 1
        b.value += 1
      end

      sleep 0.1
    end.wait

    S.root do
    end
  end
end
