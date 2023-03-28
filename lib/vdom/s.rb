# frozen_string_literal: true

# Copyright Andreas Alin <andreas.alin@gmail.com>
# Released under AGPL-3.0

require "async"
require "async/barrier"
require "async/condition"
require "async/queue"
require "async/semaphore"

module S
  class CycleDetectedError < StandardError
  end

  module Utils
    def self.with_fiber_local(name, value)
      prev, Fiber[name] = Fiber[name], value
      yield value
    ensure
      Fiber[name] = prev
    end
  end

  module States
    State = Data.define(:to_i, :to_s) do
      include Comparable
      def <=>(other) = to_i <=> other.to_i
    end

    Clean = State[0, "🟢"]
    Check = State[1, "🟡"]
    Dirty = State[2, "🔴"]
  end

  class Reactive
    CURRENT_KEY = :S_Reactive_current
    TRACKING_KEY = :S_Reactive_tracking?

    def self.tracking? =
      Fiber[TRACKING_KEY] != false
    def self.track(tracking = true, &) =
      Utils.with_fiber_local(TRACKING_KEY, tracking, &)
    def self.untrack(&) =
      track(false, &)

    def self.current = Fiber[CURRENT_KEY]

    def initialize
      @condition = Async::Condition.new
    end

    def subscribe(&)
      S.effect do
        value = self.value

        Reactive.untrack do
          yield value
        end
      end
    end

    def inspect =
      "#<#{self.class.name} value=#{@value.inspect} #{@state}>"
    def to_s =
      @value.to_s

    def clean? =
      @state == States::Clean
    def check? =
      @state == States::Check
    def dirty? =
      @state == States::Dirty

    def wait =
      @condition.wait

    def peek
      update
      @value
    end

    def value
      if Reactive.tracking?
        Reactive.current&.add_source(self)
      end

      peek
    end

    protected

    def value=(value)
      Root.current!.batch do
        unless @value == value
          @value = value
          notify(States::Dirty)
        end
      ensure
        mark!(States::Clean)
      end
    end

    def update =
      nil

    def notify(state) =
      @condition.signal(state)

    def mark!(state) =
      unless @state == state
        @state = state
      end
  end

  class Signal < Reactive
    def initialize(value)
      super()
      @state = States::Clean
      @value = value
    end

    public :value=
  end

  class Computed < Reactive
    Disposed = Data.define do
      def self.inspect = "☠️ "
    end

    def initialize(&compute)
      super()
      @compute = compute
      @sources = {}
      @state = States::Dirty
      @barrier = Async::Barrier.new
    end

    def inspect =
      "#<#{self.class.name} #{@compute.source_location.join(":")} value=#{@value.inspect} #@state>"

    def stop
      cleanup!

      @value = Disposed
      mark!(States::Clean)
      @barrier.stop
      @sources.clear
    end

    def disposed? =
      @value == Disposed

    def add_source(source)
      if source == self
        raise CycleDetectedError
      end

      @sources[source] ||= create_listener(source)
    end

    protected

    def create_listener(source)
      @barrier.async do |subtask|
        while state = source.wait
          next unless @state < state
          enqueue_effect # if clean?
          mark!(state)
          notify(States::Check)
        end
      rescue => e
        Console.logger.error(self, e)
      ensure
        @sources.delete_if { _1 == source && _2 == subtask }
      end
    end

    def update
      return if disposed?
      return if clean?

      wait_for_sources if check?

      unless dirty?
        mark!(States::Clean)
        return
      end

      old_sources = @sources.dup

      begin
        cleanup!
        self.value = call
      rescue => e
        raise e
      ensure
        old_sources.each do |source, listener|
          listener.stop
        end
      end
    end

    def wait_for_sources
      @sources.each_key do |source|
        source.peek
        break if dirty?
      rescue
        nil
      end
    end

    def call
      return if disposed?

      S.batch do
        Utils.with_fiber_local(CURRENT_KEY, self) do
          Reactive.track do
            @sources.clear
            @compute.call
          end
        end
      end
    end

    def cleanup!
      if @value in Proc => value
        @value = nil

        S.batch do
          Reactive.untrack do
            value.call
          end
        rescue => e
          Console.logger.error(self, e)
          stop
          raise
        end
      end
    end

    def enqueue_effect =
      nil
  end

  class Effect < Computed
    def initialize
      super
      update
    end

    def enqueue_effect =
      Root.current!.enqueue(self)
  end

  class Batch
    def initialize
      @queue = Async::Queue.new
      @level = 0
    end

    def enqueue(effect) =
      @queue.enqueue(effect)

    def run(task: Async::Task.current, &)
      @level += 1
      task.with_timeout(0.1) do
        yield self
      rescue => e
        Console.logger.error(self, e)
      end
    ensure
      begin
        flush! if @level == 1
      ensure
        @level -= 1
      end
    end

    def flush!
      return if @queue.empty?

      Reactive.untrack do
        catch_error do
          until @queue.empty?
            @queue.dequeue.value
          end
        end
      end
    end

    def catch_error(error = nil)
      yield
    rescue => e
      error ||= e
      Console.logger.error(self, e)
      retry
    ensure
      raise error if error
    end
  end

  class CycleDetector
    LIMIT = 20

    def initialize =
      @count = 0

    def detect(&)
      @count += 1

      if @count > LIMIT
        raise CycleDetectedError
      end

      yield
    ensure
      @count -=1
    end
  end

  class Root
    CURRENT_KEY = :S_Root_current

    def self.current =
      Fiber[CURRENT_KEY]
    def self.current! =
      current || raise("No root!")

    def self.run(&) =
      Async do |task|
        yield Fiber[CURRENT_KEY] = new
      rescue => e
        Console.logger.error(self, e)
      ensure
        task.stop
      end

    def initialize
      @cycles = CycleDetector.new
      @batch = Batch.new
    end

    def enqueue(effect) =
      batch { _1.enqueue(effect) }

    def batch(&)
      @cycles.detect do
        Utils.with_fiber_local(CURRENT_KEY, self) do
          @batch.run(&)
        end
      end
    end
  end

  module Helpers
    def root(&) = Root.run(&)
    def batch(&) = Root.current!.batch(&)

    def signal(value) = Signal.new(value)
    def computed(&) = Computed.new(&)
    def effect(&) = Effect.new(&)

    def tracking? = Reactive.tracking?
    def track(&) = Reactive.track(&)
    def untrack(&) = Reactive.untrack(&)
  end

  module Refinements
    refine Kernel do
      import_methods Helpers
    end
  end

  extend Helpers
end

if __FILE__ == $0
  S.root do
    a = S.signal(0)
    b = S.signal(0)

    c = S.computed do
      p(a.value + b.value)
    end

    d = S.computed do
      if a.value == 2
        p(b2: b.value * 2)
      else
        p(a2: a.value * 2)
      end
    end

    e = S.effect do
      p(e: c.value)
    end

    f = S.effect do
      p(f: d.value)
    end

    puts
    sleep 0.1
    puts
    puts "**** INCREMENTING A"
    a.value += 1
    puts "**** INCREMENTED A"
    sleep 0.1
    puts

    puts "**** INCREMENTING B"
    b.value += 1
    puts "**** INCREMENTED B"
    sleep 0.1
    puts

    puts "**** INCREMENTING A"
    a.value += 1
    puts "**** INCREMENTED A"
    sleep 0.1
    puts

    puts "**** INCREMENTING B"
    b.value += 1
    puts "**** INCREMENTED B"
    sleep 0.1
    puts

    puts "**** INCREMENTING B"
    b.value += 1
    puts "**** INCREMENTED B"
    sleep 0.1
    puts

    puts "**** INCREMENTING A AND B"
    S.batch do
      a.value += 1
      b.value += 1
    end
    puts "**** INCREMENTED A AND B"
    sleep 0.1
    puts

    puts "**** INCREMENTING B"
    b.value += 1
    puts "**** INCREMENTED B"
    sleep 0.1
    puts

    Async::Task.current.stop
  end

  def assert_equal(a, b)
    unless a == b
      raise "#{a.inspect} does not equal #{b.inspect}"
    end
  end

  S.root do
    a = S.signal("a")
    called_times = 0

    b =
      S.computed do
        a.value
        "foo"
      end

    c = S.computed do
      puts "CALCULATING C"
      called_times += 1
      b.value
    end

    assert_equal("foo", c.value)
    sleep 0.1
    assert_equal(1, called_times)

    a.value = "aa"
    sleep 0.1
    assert_equal("foo", c.value)
    assert_equal(1, called_times)
  end
end

