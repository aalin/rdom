module VDOM
  module Reactively
    # This module is a port of https://github.com/modderme123/reactively,
    # which according to their package.json is released under ISC license.
    # This version probably contains sneaky bugs.

    CacheClean = 0
    CacheCheck = 1
    CacheDirty = 2

    StateNames = {
      CacheClean => "clean",
      CacheCheck => "check",
      CacheDirty => "dirty",
    }

    class Reactive
      def initialize(value = nil, effect: false, &fn)
        @root = Root.current
        @cleanups = []

        if block_given?
          @fn = fn
          @effect = effect
          @state = CacheDirty
          update if effect # CONSIDER removing this?
        else
          @value = value
          @state = CacheClean
          @effect = false
        end
      end

      attr_accessor :observers
      attr_accessor :sources
      attr_accessor :state
      def effect? = @effect
      attr_accessor :cleanups
      attr_reader :fn

      def call = @fn.call
      def peek = @value

      def inspect
        lines = [
          if @fn
            [
              @effect ? "Effect" : "Compute",
              "fn=#{@fn.inspect}",
              "sources=#{@sources&.size.inspect}",
              "observers=#{@observers&.size.inspect}",
            ]
          else
            [
              "Signal",
              "value=#{@value.inspect}",
              "observers=#{@observers&.size.inspect}",
            ]
          end
        ].flatten.compact
        "#<#{lines.join(" ")}>"
      end

      def value
        context = @root.current_context

        if current_reaction = context&.reaction
          if !context.gets && current_reaction.sources&.at(context.gets_index) == self
            context.gets_index += 1
          else
            if context.gets
              context.gets.push(self)
            else
              context.gets = [self]
            end
          end
        end

        if @fn
          self.update_if_necessary
        end

        @value
      end

      def value=(new_value = nil, &fn)
        if block_given?
          unless fn == @fn
            stale(CacheDirty)
          end
          @fn = fn

          return
        end

        if @fn
          remove_parent_observers(0)
          @sources = nil
          @fn = nil
        end

        return if @value == new_value

        @observers&.each do |observer|
          observer.stale(CacheDirty)
        end

        # puts "Setting value from #{@value.inspect} to #{new_value.inspect}"
        @value = new_value
      end

      protected

      def stale(state)
        # puts "\e[33mSTALE!!!\e[31m #{StateNames[@state]} \e\31m#{StateNames[state]}\e[0m \e[2m#{self.inspect}\e[0m"

        if @state < state
          # If we were previously clean, then we know that we may need to update to get the new value
          if @state == CacheClean && @effect
            # puts "\e[3;34mEnqueueing #{self}\e[0m"
            @root.enqueue(self)
          end

          @state = state

          @observers&.each do |observer|
            observer.stale(CacheCheck)
          end
        end
      end

      # run the computation fn, updating the cached value
      def update
        # puts "\e[3;34mUPDATE #{self.inspect}\e[0m"
        # puts caller.first
        old_value = @value

        # Evalute the reactive function body, dynamically capturing any other reactives used
        @root.with_reactive(self) do |context|
          @cleanups.each { _1.call(@value) }.clear

          # puts "Calling #{self.inspect}"
          @value = @fn.call

          # if the sources have changed, update source & observer links
          if context.gets
            # remove all old sources' .observers links to us
            remove_parent_observers(context.gets_index)
            # update source up links
            if @sources && context.gets_index > 0
              # TODO: Resize array?
              # this.sources.length = CurrentGetsIndex + CurrentGets.length;
              context.gets.each_with_index do |gets, i|
                @sources[context.gets_index + i] = gets
              end
            else
              @sources = context.gets
            end

            sources_to_add = @sources.slice(context.gets_index..-1)
            sources_to_add
              .each do |source|
                # Add ourselves to the end of the parent .observers array
                if source.observers
                  source.observers.push(self)
                else
                  source.observers = [self]
                end
              end
          elsif @sources && context.gets_index < @sources.length
            # remove all old sources' .observers links to us
            remove_parent_observers(context.gets_index)
            @sources.replace(@sources[0..context.gets_index])
          end
        end

        # handle diamond depenendencies if we're the parent of a diamond.
        unless old_value == @value
          # We've changed value, so mark our children as dirty so they'll reevaluate
          @observers&.each do |observer|
            observer.state = CacheDirty
          end
        end

        # We've rerun with the latest values from all of our sources.
        # This means that we no longer need to update until a signal changes
        # puts "Sett ing state to clean! #{self.inspect}"
        @state = CacheClean
      end

      # update() if dirty, or a parent turns out to be dirty.
      def update_if_necessary
        # If we are potentially dirty, see if we have a parent who has actually changed value
        if @state == CacheCheck
          @sources.each do |source|
            source.update_if_necessary # update_if_necessary can change @state

            # Stop the loop here so we won't trigger updates on other parents unnecessarily
            # If our computation changes to no longer use some sources, we don't
            # want to update() a source we used last time, but now don't use.
            break if @state == CacheDirty
          end
        end

        # If we were already dirty or marked dirty by the step above, update.
        if @state == CacheDirty
          # puts "Updating #{self.inspect} because we're dirty"
          self.update
        end

        # By now, we're clean
        # puts "\e[32mNow we're clean #{self.inspect}\e[0m"
        @state = CacheClean
      end

      def remove_parent_observers(index)
        return unless @sources

        @sources.slice(index..-1).each do |source|
          swap = source.observers.index(self)
          source.observers[swap] = source.observers.last
          source.observers.pop
        end
      end
    end

    def self.on_cleanup(&block)
      if current_reaction = Root.current.current_context.reaction
        current_reaction.cleanups.push(block)
      else
        raise "#{__method__} must be called from within a @reactive function"
      end
    end

    def self.with_fiber_local(name, value)
      prev, Fiber[name] = Fiber[name], value
      yield value
    ensure
      Fiber[name] = prev
    end

    class Context
      def initialize(reaction)
        @reaction = reaction
        @gets_index = 0
      end

      attr_reader :reaction
      attr_accessor :gets
      attr_accessor :gets_index
    end

    class Root
      def self.current = Fiber[:current_root]

      def self.run(&)
        Reactively.with_fiber_local(:current_root, new) do
          yield
        end
      end

      def initialize
        @batch_level = 0
        @effect_queue = []
        @current_context = nil
      end

      attr_reader :current_reaction
      attr_accessor :current_gets
      attr_accessor :current_gets_index
      attr_reader :current_context

      def with_reactive(reactive)
        prev, @current_context = @current_context, Context.new(reactive)
        # puts "Enter #{reactive.inspect}"
        yield @current_context
        # puts "Exit #{reactive.inspect}"
      ensure
        @current_context = prev
      end

      def stabilize
        # puts "\e[3m#{__method__} #{@effect_queue.size}\e[0m"
        while effect = @effect_queue.shift
          begin
            effect.value
          rescue => e
            p e
          end
        end
      end

      def enqueue(effect)
        @effect_queue.push(effect)
      end

      def batch(&)
        @batch_level += 1
        yield
      ensure
        stabilize
        @batch_level -= 1
      end
    end

    module API
      Disposed = Data.define

      def self.batch(&) =
        Root.current.batch(&)

      module Readable
      end

      module Writable
      end

      class Signal
        include Readable
        include Writable

        def initialize(value) =
          @reactive = Reactive.new(value)
        def value =
          @reactive.value
        def inspect =
          "#<Signal value=#{@reactive.peek.inspect}>"
        def value=(new_value)
          API.batch do
            @reactive.value = new_value
          end
        end
      end

      class Computed
        include Readable

        def initialize(&) =
          @reactive = Reactive.new(effect: false, &)
        def value =
          @reactive.value

        def dispose!
          @reactive.value = Disposed
          @reactive = nil
        end

        def inspect
          state_name = StateNames[@reactive.state]
          "#<#{self.class.name}(#{state_name}) #{@reactive.fn.source_location.join(":")}>"
        end
      end

      class Effect < Computed
        def initialize(&) =
          @reactive = Reactive.new(effect: true, &)
        def dispose!
          @reactive.value = Disposed
          @reactive = nil
        end
      end
    end

    module Helpers
      def signal(value) = API::Signal.new(value)
      def computed(&) = API::Computed.new(&)
      def effect(&) = API::Effect.new(&)
      def batch(&) = API.batch(&)
    end

    module Refinements
      refine Kernel do
        import_methods Helpers
      end
    end

    def self.run(&) = Root.run(&)
  end
end

if __FILE__ == $0
  using VDOM::Reactively::Refinements

  VDOM::Reactively.run do
    a = signal(0)
    b = signal(0)

    c = computed do
      a.value + b.value
    end

    is_even = computed { c.value.even? }

    e = effect do
      # p(e: c.value)
      puts "\e[3;35mRUNNING EFFECT even: #{is_even.value}\e[0m"
    end

    sleep 1

    puts "Increasing value"
    a.value += 1
    sleep 1
    puts "Increasing value"
    a.value += 1
    p a
    e.dispose!
    puts "Increasing value"
    a.value += 1
    p a
  end
end
