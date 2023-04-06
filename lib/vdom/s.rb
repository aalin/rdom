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

  module AsyncRefinements
    refine Async::Condition do
      def size = @waiting.size
    end
  end

  using AsyncRefinements

  module Utils
    def self.with_fiber_local(name, value)
      prev = Fiber[name]
      Fiber[name] = value
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

    def initialize(name: nil)
      @name = name
      @condition = Async::Condition.new
    end

    attr_reader :name

    def to_s =
      @value.to_s

    def inspect =
      [
        self.class.name,
        "name=#{@name.inspect}",
        "subscribers=#{@condition.size}",
        "value=#{@value.inspect}",
        @state
      ].join(" ").prepend("#<").concat(">")

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

    def subscribe(name: caller.first, &) =
      S.effect(name:) do
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
      update!
      @value
    end

    protected

    def stop_if_empty! =
      nil

    def value=(value)
      S.batch do
        @value = value
        notify!(States::Dirty)
      end unless @value == value
    end

    def update! =
      nil

    def notify!(state) =
      @condition.signal(state)

    def mark!(state) =
      unless @state == state
        @state = state
      end
  end

  class Signal < Reactive
    def initialize(value, name:)
      super(name:)
      @state = States::Clean
      @value = value
    end

    public :value=
  end

  class Computed < Reactive
    Disposed = Data.define do
      def self.inspect = "❌"
    end

    def initialize(name: compute.source_location.join(":"), task: Async::Task.current, &compute)
      super(name:)
      @root = Root.current!
      @compute = compute
      @sources = {}
      @state = States::Dirty
      @barrier = Async::Barrier.new(parent: task)
    end

    def stop
      cleanup!
    ensure
      dispose!
      @barrier.stop
      @sources.each_key(&:stop_if_empty!).clear
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
        loop do
          state = source.wait
          next unless @state < state
          enqueue_effect if clean?
          mark!(state)
          notify!(States::Check)
        end
      ensure
        @sources.delete_if { _1 == source && _2 == subtask }
        source.stop_if_empty!
      end

    def update!
      until clean? or disposed?
        wait_for_sources if check?

        if dirty?
          self.value = call
        end

        mark!(States::Clean)
        notify!(States::Clean)
      end
    end

    def wait_for_sources =
      @sources.each_key do |source|
        source.peek
        break if dirty?
      rescue
        nil
      end

    def call =
      update_sources do
        S.batch do
          Async do
            Fiber[CURRENT_KEY] = self
            Fiber[TRACKING_KEY] = true
            @compute.call
          end.wait
        end
      end

    def update_sources =
      @sources.values.then do |old_listeners|
        # start_cleanup_task
        @sources.clear
        cleanup!
        yield unless disposed?
      ensure
        old_listeners.each(&:stop)
      end

    def cleanup! =
      if @value in Proc => cleanup
        @value = nil

        S.batch do
          Reactive.untrack do
            cleanup.call
          end
        rescue => e
          Console.logger.error(self, e)
          stop
          raise
        end
      end

    def dispose!
      @value = nil
      mark!(States::Dirty)
    end

    def enqueue_effect =
      nil
  end

  class Effect < Computed
    def initialize(...)
      super(...)
      update!
    end

    protected

    def stop_if_empty! =
      nil

    def dispose!
      @compute = @value = Disposed
      mark!(States::Clean)
    end

    def enqueue_effect =
      @root&.enqueue(self)
  end

  class Root
    CYCLE_LIMIT = 50
    CURRENT_KEY = :S_Root_current

    def inspect
      "#<#{self.class.name}##{object_id} #{@name} empty?=#{@barrier.empty?} #{@barrier.tasks.size}>"
    end

    def self.current =
      Fiber[CURRENT_KEY]
    def self.current! =
      current || raise("No root!")

    def self.with(root, &) =
      Utils.with_fiber_local(CURRENT_KEY, root, &)

    def self.run(name: caller.first, task: Async::Task.current, &) =
      task.async do
        root = new(name:, task: _1)
        puts "\e[32mStarted root #{root.object_id}\e[0m"
        Fiber[CURRENT_KEY] = root
        yield
      ensure
        root.stop
        puts "\e[31mStopped root #{root&.object_id}\e[0m"
      end.wait

    def initialize(name:, task: Async::Task.current)
      @name = name
      @barrier = Async::Barrier.new(parent: task)
      @queue = Async::Queue.new(parent: @barrier)
      @level = 0
    end

    def running? =
      !@barrier.empty?

    def async(&) =
      @barrier.async(&)

    def stop
      @queue.dequeue until @queue.empty?
      @queue = nil
      @barrier.stop
    end

    def enqueue(effect) =
      @queue.enqueue(effect)

    def batch(&) =
      self.class.with(self) do
        cycle do |level|
          yield self
        ensure
          flush! if level == 1
        end
      end

    protected

    def flush! =
      catch_error do
        until @queue.empty?
          @queue.dequeue.peek
        end
      end

    def cycle
      @level += 1

      if @level > CYCLE_LIMIT
        raise CycleDetectedError
      end

      yield @level
    ensure
      @level -= 1
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

  class Exporter
    module Formats
      module Mermaid
        def init =
          "flowchart LR"

        def label(node) =
          "    #{node_id(node)}[#{escape(node.inspect)}]"
        def link(source, target) =
          "    #{node_id(source)} --> #{node_id(target)}"
        def link_dotted(source, target) =
          "    #{node_id(source)} -.-> #{node_id(target)}"

        def escape(str) =
          str
            .gsub("#", "#35;")
            .gsub('"', "#34;")
            .gsub("<", "#lt;")
            .gsub(">", "#gt;")
            .inspect
      end

      module D2
        def init =
          nil
        def label(node) =
          "#{node_id(node)}: #{node.inspect.inspect}"
        def link(source, target) =
          "#{node_id(source)} -> #{node_id(target)}"
        def link_dotted(source, target) =
          "#{node_id(source)} -> #{node_id(target)}"
      end
    end

    def self.export(format) =
      StringIO.new.tap do |out|
        new(out, format).tap do |exporter|
          if init = exporter.init
            out.puts(init)
          end
          ObjectSpace.each_object(Root) { exporter.visit(_1) }
          ObjectSpace.each_object(Reactive) { exporter.visit(_1) }
        end
        out.rewind
      end.read

    def initialize(out, format)
      extend format

      @out = out
      @visited = Set.new
    end

    def visit(node) =
      if @visited.add?(node)
        @out.puts(label(node))

        case node
        in Root
        in Signal
        in Computed
          if root = node.instance_variable_get(:@root)
            visit(root)
            @out.puts(link_dotted(node, root))
          end
          node.instance_variable_get(:@sources).each_key do |source|
            visit(source)
            @out.puts(link(source, node))
          end
        end
      end

    private

    def node_id(node) =
      "#{node.class.name.split("::").last.downcase}#{node.object_id}"
  end

  module Helpers
    def root(name: caller.first, task: Async::Task.current, &) =
      Root.run(name:, task:, &)

    def batch(&) = Root.current!.batch(&)

    def signal(value, name: caller.first) = Signal.new(value, name:)
    def computed(name: caller.first, &) = Computed.new(name:, &)
    def effect(name: caller.first, &) = Effect.new(name:, &)

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
