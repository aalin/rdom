# frozen_string_literal: true

require "securerandom"
require "pry"
require "async"
require "async/barrier"
require "async/condition"
require "async/queue"
require_relative "patches"
require_relative "descriptor"
require_relative "text_diff"

module VDOM
  module Nodes
    class Base
      CURRENT_KEY = :current_vnode
      Unmount = Class.new(Async::Stop)

      def self.current = Fiber[CURRENT_KEY]

      def self.use(node, &)
        prev = Fiber[CURRENT_KEY]
        Fiber[CURRENT_KEY] = node
        yield node
      ensure
        Fiber[CURRENT_KEY] = prev
      end

      def self.run(...)
        node = start(...)
        yield node
      ensure
        node&.stop
      end

      def self.start(...) =
        new.start(...)

      def initialize(parent: Base.current)
        @parent = parent
        @incoming = Async::Queue.new
        @task = nil
      end

      def start(...)
        raise "There is already a task!" if @task

        @task = async do
          Fiber[CURRENT_KEY] = self
          run(...)
        end

        self
      end

      def run(...) =
        raise(NotImplementedError, "#{self.class.name}##{__method__} is not implemented")
      def resume(*args) =
        @incoming.enqueue(args)
      def stop =
        @task&.stop

      protected

      def closest(klass)
        if klass === self
          self
        else
          @parent&.closest(klass)
        end
      end

      def async(&) =
        (@task || @parent || Async::Task.current).async(&)
      def receive(&) =
        loop { yield(*@incoming.dequeue) }
      def hierarchy =
        [*@parent&.hierarchy, self]
      def running? =
        !@task&.stopped?
      def batch(&) =
        @parent&.batch(&)
      def patch(patch) =
        @parent&.patch(patch)
      def get_slot(name) =
        @parent.get_slot(name)
      def callbacks =
        @parent.callbacks
      def mount_dom_node(id, &) =
        @parent&.mount_dom_node(id, &)
    end

    class VNode < Base
      def generate_id =
        SecureRandom.alphanumeric(5)
    end

    class VText < VNode
      def run(content)
        with_text_node(content.to_s) do |id|
          mount_dom_node(id) do
            receive do |new_content|
              content = TextDiff.diff(
                id,
                content,
                new_content.to_s
              ) { patch(_1) }
            end
          end
        end
      end

      private

      def with_text_node(content, id: generate_id)
        patch(Patches::CreateTextNode[id, content])
        yield id
      ensure
        patch(Patches::RemoveNode[id])
      end
    end

    class VReactively < Base
      def run(signal)
        VAny.run(Descriptor.normalize_children(signal.value)) do |vnode|
          effect = Reactively::API::Effect.new do
            vnode.resume(Descriptor.normalize_children(signal.value))
          end

          receive do |new_signal|
            unless signal == new_signal
              raise "Signal changed!"
            end
          end
        ensure
          effect.dispose!
        end
      end
    end

    class VSignal < Base
      def run(signal)
        VAny.run(Descriptor.normalize_children(signal.value)) do |vnode|
          loop do
            vnode.resume(Descriptor.normalize_children(signal.wait))
          end
        end
      end
    end

    class VComponent < Base
      def get_slot(name)
        if @slots
          @slots.fetch(name) do
            $stderr.puts "\e[33mCould not find slot #{name.inspect}\e[0m"
            nil
          end
        else
          $stderr.puts "\e[33mCould not find slot #{name.inspect}\e[0m"
          nil
        end
      end

      def run(descriptor)
        instance = descriptor.type.new(**descriptor.props)

        instance.instance_variable_set(:@props, descriptor.props)

        vcomponent = self
        @slots = group_descriptors_by_slots(descriptor.children)

        instance.define_singleton_method(:rerender!) do
          vcomponent.resume(:rerender!)
        end

        VAny.run(instance.render) do |vnode|
          async { instance.mount }

          receive do |descriptor|
            case descriptor
            in :rerender!
              vnode.resume(instance.render)
            in Descriptor
              @slots = group_descriptors_by_slots(descriptor.children)
              instance.instance_variable_set(:@props, descriptor.props)
              vnode.resume(instance.render)
            end
          end
        end
      end

      def group_descriptors_by_slots(descriptors)
        descriptors.group_by do |descriptor|
          case descriptor
          in Descriptor[slot:]
            slot
          else
            nil
          end
        end
      end

    end

    class VFragment < VNode
      def run(descriptors)
        with_fragment do |id|
          VChildren.run(id, descriptors) do |children|
            mount_dom_node(id) do
              receive do |descriptors|
                children.resume(descriptors)
              end
            end
          end
        end
      end

      def with_fragment(id: generate_id)
        patch(Patches::CreateDocumentFragment[id])
        yield id
      ensure
        patch(Patches::RemoveNode[id])
      end
    end

    class VElement < VNode
      def run(descriptor)
        with_element(descriptor.type) do |id|
          VAttributes.run(id, descriptor.props) do |attributes|
            VChildren.run(id, descriptor.children) do |children|
              mount_dom_node(id) do
                receive do |descriptors|
                  Array(descriptors).flatten => [descriptor]
                  attributes.resume(descriptor.props)
                  children.resume(descriptor.children)
                end
              end
            end
          end
        end
      end

      def with_element(type, id: generate_id)
        patch(Patches::CreateElement[id, type.to_s.tr("_", "-")])
        yield id
      ensure
        patch(Patches::RemoveNode[id])
      end
    end

    class VAttributes < Base
      class VAttr < Base
        def run(element_id, name, value)
          loop do
            catch do |value_changed|
              update_attribute(element_id, name, value) do
                receive do |new_value|
                  next if new_value == value
                  value = new_value
                  throw(value_changed)
                end
              end
            end
          end
        ensure
          patch(Patches::RemoveAttribute[element_id, name])
        end

        def update_attribute(element_id, name, value, &)
          if value in Reactively::API::Readable
            update_dynamic(element_id, name, value, &)
          else
            update_static(element_id, name, value, &)
          end
        end

        def update_dynamic(element_id, name, signal, &)
          effect = Reactively::API::Effect.new do
            patch(Patches::SetAttribute[element_id, name, signal.value.to_s])
          end

          yield
        ensure
          effect&.dispose!
        end

        def update_static(element_id, name, value, &)
          patch(Patches::SetAttribute[element_id, name, value.to_s])
          yield
        end
      end

      class VCallback < Base
        def run(element_id, name, handler)
          id = SecureRandom.alphanumeric(32)

          callbacks.store(id, handler)

          patch(Patches::SetHandler[element_id, name, id])

          receive do |handler|
            callbacks.store(id, handler)
          end
        ensure
          callbacks.delete(id)
          patch(Patches::RemoveHandler[element_id, name, id])
        end
      end

      class VStyles < Base
        class VStyle < Base
          def run(element_id, name, value)
            value = Array(value).join(" ").tr("_", "-")
            patch(Patches::SetCSSProperty[element_id, name, value])

            receive do |new_value|
              new_value = Array(new_value).join(" ").tr("_", "-")
              next if new_value == value
              value = new_value
              patch(Patches::SetCSSProperty[element_id, name, value])
            end
          ensure
            patch(Patches::RemoveCSSProperty[element_id, name])
          end
        end

        def run(element_id, name, value)
          vstyles = update_styles(element_id, {}, value)

          receive do |value|
            vstyles = update_styles(element_id, vstyles, value)
          end
        ensure
          vstyles.each_value(&:stop)
          patch(Patches::RemoveAttribute[element_id, name])
        end

        def update_styles(element_id, vstyles, styles)
          stopped = vstyles.except(*styles.keys)
          stopped.each_value(&:stop)

          styles.map do |name, value|
            if old = vstyles[name]
              old.resume(value)
              [name, old]
            else
              [name, VStyle.start(element_id, name.to_s.tr("_", "-"), value)]
            end
          end.to_h
        end
      end

      def run(element_id, attributes)
        vattrs = update_attributes(element_id, {}, attributes)

        receive do |attributes|
          vattrs = update_attributes(element_id, vattrs, attributes)
        end
      end

      def update_attributes(element_id, vattrs, attributes)
        stopped = vattrs.except(*attributes.keys)
        stopped.each_value(&:stop)

        attributes.map do |name, value|
          if old = vattrs[name]
            old.resume(value)
            [name, old]
          else
            [name, attr_node_class(name).start(element_id, name.to_s.tr("_", "-"), value)]
          end
        end.to_h
      end

      def attr_node_class(name)
        case name
        in :style
          VStyles
        in /\Aon/
          VCallback
        else
          VAttr
        end
      end
    end

    class VAny < Base
      def run(descriptor)
        loop do
          catch do |type_changed|
            descriptor = unwrap(descriptor)
            type = descriptor_to_node_type(descriptor)

            type.run(descriptor) do |vnode|
              receive do |new_descriptor|
                new_descriptor = unwrap(new_descriptor)

                unless Descriptor.same?(descriptor, new_descriptor)
                  throw(type_changed)
                end

                vnode.resume(descriptor = new_descriptor)
              end
            end
          end
        end
      end

      def unwrap(descriptor)
        case Array(descriptor).compact.flatten
        in [one] then one
        in [*many] then many
        end
      end

      def descriptor_to_node_type(descriptor)
        case descriptor
        in Reactively::API::Readable
          VReactively
        in Array
          VFragment
        in Descriptor[type: Class]
          VComponent
        in Descriptor[type: :slot]
          VSlot
        in Descriptor[type: Symbol]
          VElement
        else
          VText
        end
      end
    end

    class VSlot < Base
      def run(descriptor)
        name = descriptor.props[:name]

        VAny.run(get_slot(name)) do |vnode|
          receive do |descriptor|
            name = descriptor.props[:name]
            vnode.resume(get_slot(name))
          end
        end
      end
    end

    class VChild < Base
      attr_reader :dom_id

      def run(child, descriptor)
        @child = child

        VAny.run(descriptor) do |vnode|
          receive do |descriptor|
            vnode.resume(descriptor)
          end
        end
      end

      def mount_dom_node(id)
        if @dom_id
          raise "There is already a DOM node mounted here"
        end

        begin
          @dom_id = id
          patch(Patches::InsertBefore[@child.parent_id, id, @child.next_dom_id])
          yield
        ensure
          patch(Patches::RemoveChild[@child.parent_id, id])
          @dom_id = nil
        end
      end
    end

    class VChildren < Base
      class Child
        attr_reader :hash
        attr_reader :node
        attr_accessor :index
        attr_accessor :parent_id
        attr_accessor :previous_sibling
        attr_accessor :next_sibling

        def initialize(hash)
          @hash = hash
        end

        def resume(descriptor)
          if @node
            @node.resume(descriptor)
          else
            @node = VChild.start(self, descriptor)
          end

          self
        end

        def stop
          @node&.stop
        end

        def next_dom_id
          if sibling = @next_sibling
            sibling&.node&.dom_id || sibling.next_dom_id
          end
        end
      end

      def run(parent_id, descriptors)
        @parent_id = parent_id
        children = update_children({}, descriptors)

        receive do |descriptors|
          children = update_children(children, descriptors)
        end
      ensure
        update_children(children, [])
      end

      def update_children(children, descriptors)
        diff_children(
          children,
          normalize_descriptors(descriptors),
        )
      end

      def normalize_descriptors(descriptors)
        Descriptor
          .normalize_children(descriptors)
          .reject do
            _1 in Descriptor[slot:] if slot
          end
      end

      def group_descriptors_by_slots(descriptors)
        descriptors.group_by do |descriptor|
          case descriptor
          in Descriptor[slot:]
            slot
          else
            nil
          end
        end
      end

      def diff_children(children, descriptors)
        descriptors
          .map.with_index do |descriptor, index|
            children[Descriptor.get_hash(descriptor)]&.shift ||
              Child.new(Descriptor.get_hash(descriptor))
          end
          .tap do
            [nil, *_1, nil]
              .each_cons(3)
              .with_index do |(previous_sibling, child, next_sibling), index|
                child.parent_id = @parent_id
                child.index = index
                child.previous_sibling = previous_sibling
                child.next_sibling = next_sibling
              end
          end
          .zip(descriptors)
          .map do |child, descriptor|
            child.resume(descriptor)
            child
          end
          .tap do
            if children
              children.values.flatten.each(&:stop)
            end
          end
          .group_by(&:hash)
      end
    end

    class VRoot < Base
      def initialize(task: Async::Task.current)
        @barrier = Async::Barrier.new(parent: task)
        @patches = Async::Queue.new
        @callbacks = {}
        super()
      end

      attr_reader :callbacks

      def patch(patch) =
        @patches.enqueue(patch)
      def take =
        @patches.dequeue

      def mount_dom_node(id)
        patch(Patches::InsertBefore[nil, id, nil])
        yield
      ensure
        patch(Patches::RemoveChild[nil, id])
      end

      def handle_callback(id, payload)
        handler = @callbacks.fetch(id)

        if handler.arity.zero?
          handler.call
        else
          handler.call(**payload)
        end
      end

      def run(descriptor = nil, session_id:)
        with_root(session_id) do
          VChildren.run(nil, descriptor) do |children|
            receive do |descriptor|
              children.resume(descriptor)
            end
          end
        end
      end

      private

      def with_root(session_id)
        patch(Patches::CreateRoot[session_id])
        yield
      ensure
        patch(Patches::DestroyRoot[])
      end
    end
  end
end
