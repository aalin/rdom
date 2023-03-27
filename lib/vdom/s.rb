# frozen_string_literal: true

require "async"
require "async/barrier"
require "async/condition"
require "async/notification"
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
    class State < Module
      include Comparable
      attr_reader :to_i
      attr_reader :sgr

      def initialize(value, sgr)
        @to_i = value
        @sgr = sgr
        freeze
      end

      def <=>(other) =
        to_i <=> other.to_i
      def to_s =
        name[/\w+$/]
    end

    Clean = State.new(0, 32)
    Check = State.new(1, 33)
    Dirty = State.new(2, 31)
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

    def update
    end

    def value=(value)
      return if @value == value
      puts "#{self.inspect} updated value from #{@value.inspect} to #{value.inspect}"
      @value = value
      mark!(States::Clean)

      Root.current!.batch do
        notify(States::Dirty)
      end
    end

    def notify(state)
      unless @condition.empty?
        puts "\e[1;31m#{self.inspect} notifying #{state}\e[0m"
        @condition.signal(state)
      end
    end

    def mark!(state)
      unless @state == state
        puts "\e[#{state.sgr}m#{self.inspect} #{state}\e[0m"
        @state = state
      end
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
    Disposed = Data.define

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

      puts "\e[36mSubscribing #{self.inspect} to #{source.inspect}\e[0m"
      @sources[source] ||=
        @barrier.async do |subtask|
          while state = source.wait
            puts "#{self.inspect} got #{state}"
            if @state < state
              enqueue_effect if clean?
              mark!(state)
              notify(States::Check)
            end
          end
        rescue => e
          Console.logger.error(self, e)
        ensure
          @sources.delete_if { _1 == source && _2 == subtask }
        end
    end

    protected

    def update
      return if disposed?
      return if clean?

      wait_for_sources if check?

      return unless dirty?

      old_sources = @sources.values.to_a

      begin
        cleanup!
        self.value = call
      rescue => e
        raise e
      ensure
        @state = States::Clean
      end

      old_sources.each(&:stop)
    end

    def wait_for_sources(barrier: Async::Barrier.new)
      return if @sources.empty?
      puts "#{self.inspect} waiting for #{@sources.keys.inspect}"

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
      self.value = call
    end

    def value
      puts "Getting #{self.inspect}.value"
      super
    end

    def enqueue_effect =
      Root.current!.enqueue(self)
  end

  class Batch
    def initialize
      @queue = Async::Queue.new
      @level = 0
    end

    def enqueue(effect)
      puts "\e[34mENQUEUE: #{effect.inspect}\e[0m"
      @queue.enqueue(effect)
    end

    def run(task: Async::Task.current, &)
      @level += 1
      task.with_timeout(0.1) do
        yield self
      rescue Async::Timeout
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
      # return if @queue.empty?
      Reactive.untrack do
        puts "\e[1;3m FLUSHING #{self} \e[0m"

        catch_error do
          until @queue.empty?
            effect = @queue.dequeue
            puts "\e[3;35mRunning #{effect.inspect}\e[0m"
            effect.value
          end
        end
      ensure
        puts "\e[3m AFTER FLUSH #{self} \e[0m"
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

  class Cycles
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
      @cycles = Cycles.new
      @batch = Batch.new
    end

    def enqueue(effect) =
      batch { _1.enqueue(effect) }

    def batch(&)
      @cycles.detect do
        @batch.run(&)
      end
    end
  end

  module Helpers
    def root(&) = Root.run(&)
    def batch(&) = Root.current!.batch(&)
    def signal(value) = Signal.new(value)
    def computed(&) = Computed.new(&)
    def effect(&) = Effect.new(&)
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
    i = 0

    S.effect do
      puts "Running effect"
      # Prevent test suite from spinning if limit is not hit
      if (i += 1) > 200
        raise "test failed"
      end
      a.value
      a.value = Float::NAN
    end
  end

  exit

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

