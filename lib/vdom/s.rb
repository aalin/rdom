# frozen_string_literal: true

# Copyright Andreas Alin <andreas.alin@gmail.com>
# Released under AGPL-3.0

require "async"
require "async/barrier"
require "async/condition"
require "async/queue"

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
    def self.track(&) =
      Utils.with_fiber_local(TRACKING_KEY, true, &)
    def self.untrack(&) =
      Utils.with_fiber_local(TRACKING_KEY, false, &)

    def self.current =
      Fiber[CURRENT_KEY]
    def self.current_tracking =
      (current if tracking?)

    def initialize =
      @condition = Async::Condition.new

    def to_s =
      @value.to_s
    def inspect =
      "#<#{self.class.name} value=#{@value.inspect[0..50]} #{@state}>"

    def wait =
      @condition.wait
    def empty? =
      @condition.empty?

    def clean? =
      @state == States::Clean
    def check? =
      @state == States::Check
    def dirty? =
      @state == States::Dirty

    def subscribe(&) =
      S.effect do
        value = self.value

        Reactive.untrack do
          yield value
        end
      end

    def value
      Reactive.current_tracking&.add_source(self)
      peek
    end

    def peek
      update
      @value
    end

    protected

    def stop_if_empty! =
      nil

    def value=(value)
      S.batch do
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

    def initialize(task: Async::Task.current, &compute)
      super()
      @compute = compute
      @sources = {}
      @state = States::Dirty
      @barrier = Async::Barrier.new(parent: task)
    end

    def inspect =
      "#<#{self.class.name} #{@compute.source_location.join(":")} value=#{@value.inspect[0..50]} #@state>"

    def stop
      cleanup!
    ensure
      dispose!
      @barrier.stop
      @sources.each_key(&:stop_if_empty!)
      @sources.clear
    end

    def disposed? =
      @compute == Disposed

    def add_source(source) =
      unless self == source
        @sources[source] ||= create_listener(source)
      end

    protected

    def stop_if_empty! =
      (stop if empty?)

    def create_listener(source) =
      @barrier.async do |subtask|
        while state = source.wait
          next unless @state < state
          enqueue_effect if clean?
          mark!(state)
          notify(States::Check)
        end
      rescue => e
        Console.logger.error(self, e)
      ensure
        @sources.delete_if { _1 == source && _2 == subtask }
        source.stop_if_empty!
      end

    def update
      return if clean? or disposed?

      wait_for_sources if check?

      unless dirty?
        mark!(States::Clean)
        return
      end

      self.value = call
    end

    def wait_for_sources =
      @sources.each_key do |source|
        source.peek
        break if dirty?
      rescue
        nil
      end

    def call
      return if disposed?

      update_sources do
        S.batch do
          Utils.with_fiber_local(CURRENT_KEY, self) do
            Reactive.track do
              @compute.call
            end
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

    def update_sources =
      @sources.values.then do |old_listeners|
        @sources.clear
        cleanup!
        yield unless disposed?
      ensure
        old_listeners.each(&:stop)
      end

    def dispose!
      @value = nil
      mark!(States::Dirty)
    end

    def enqueue_effect
    end
  end

  class Effect < Computed
    def initialize
      super
      update
    end

    def enqueue_effect =
      Root.current!.enqueue(self)

    def dispose!
      @compute = @value = Disposed
      mark!(States::Clean)
    end

    def stop_if_empty! =
      nil
  end

  class Root
    CYCLE_LIMIT = 50
    CURRENT_KEY = :S_Root_current

    def self.current =
      Fiber[CURRENT_KEY]
    def self.current! =
      current || raise("No root!")

    def self.with(root, &) =
      Utils.with_fiber_local(CURRENT_KEY, root, &)

    def self.run(&) =
      Async do |task|
        with(new) do |root|
          yield root
        ensure
          root.stop
        end
      ensure
        task.stop
      end

    def initialize(task: Async::Task.current)
      @barrier = Async::Barrier.new(parent: task)
      @queue = Async::Queue.new(parent: @barrier)
      @level = 0
    end

    def stop =
      @barrier.stop

    def enqueue(effect) =
      @queue.enqueue(effect)

    def batch(&) =
      Root.with(self) do
        cycle do |level|
          @barrier.async do |task|
            yield self
          end.wait
        ensure
          flush! if level == 1
        end
      end

    protected

    def cycle
      @level += 1

      if @level > CYCLE_LIMIT
        raise CycleDetectedError
      end

      yield @level
    ensure
      @level -= 1
    end

    def flush! =
      catch_error do
        until @queue.empty?
          @queue.dequeue.peek
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
