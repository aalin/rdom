# frozen_string_literal: true

require "securerandom"
require "async"
require "async/barrier"
require "async/condition"
require "async/queue"
require_relative "patches"
require_relative "descriptor"
require_relative "custom_element"
require_relative "text_diff"
require "pry"

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

      def inspect
        "#<#{self.class.name} #{@task.inspect}>"
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

      def dom_id(traverse = false) =
        @dom_id || (traverse && parent.dom_id)

      protected

      def parent =
        @parent || raise("There is no parent")

      def receive(&)
        if block_given?
          loop { yield(*@incoming.dequeue) }
        else
          @incoming.dequeue
        end
      end

      def closest(klass)
        if klass === self
          self
        else
          parent.closest(klass)
        end
      end

      def async(&) =
        (@task || @parent || Async::Task.current).async(&)
      def hierarchy =
        [*parent.hierarchy, self]
      def running? =
        !@task&.stopped?
      def batch(&) =
        parent.batch(&)
      def patch(patch) =
        parent.patch(patch)
      def get_slot(name) =
        parent.get_slot(name)
      def callbacks =
        parent.callbacks
      def mount_dom_node(id, &) =
        parent.mount_dom_node(id, &)
    end

    class VNode < Base
      def generate_id = SecureRandom.alphanumeric(5)
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
        instance = descriptor.type.allocate
        # Define @props before calling initialize,
        # so we can use self.props inside initialize.
        instance.instance_variable_set(:@props, descriptor.props)
        instance.send(:initialize, **descriptor.props)

        yield_self do |vcomponent|
          instance.define_singleton_method(:rerender!) do
            vcomponent.resume(:rerender!)
          end
        end

        @slots = group_descriptors_by_slots(descriptor.children)

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

    # class VFragment < VNode
    #   def run(descriptors)
    #     p(descriptors:)
    #     with_fragment do |id|
    #       VChildren.run(id, descriptors) do |children|
    #         mount_dom_node(id) do
    #           receive do |descriptors|
    #             children.resume(descriptors)
    #           end
    #         end
    #       end
    #     end
    #   end
    #
    #   def with_fragment(id: generate_id)
    #     patch(Patches::CreateDocumentFragment[id])
    #     yield id
    #   ensure
    #     patch(Patches::RemoveNode[id])
    #   end
    # end

    class VCustomElement < VNode
      class VChildSlots < VNode
        def run(slots)
          children = diff_slots({}, slots)

          receive do |slots|
            children = diff_slots(children, slots)
          end
        ensure
          diff_slots(children, {})
        end

        def diff_slots(slots, new_slots)
          new_slots.map do |name, descriptor|
            if slot = slots.delete(name)
              slot.resume(descriptor)
              [name, slot]
            else
              [name, VSlotted.start(parent.dom_id, name, descriptor)]
            end
          end.to_h
        ensure
          slots.values.flatten.each(&:stop)
        end
      end

      class VPropRefs < VNode
        def run(refs)
          refs = diff_refs({}, refs)

          receive do |new_refs|
            refs = diff_refs(refs, new_refs)
          end
        ensure
          diff_refs(refs, {})
        end

        def diff_refs(refs, new_refs)
          new_refs.map do |name, props|
            if ref = refs.delete(name)
              ref.resume(props)
              [name, ref]
            else
              [name, VProps.start(parent.dom_id, name, props)]
            end
          end.to_h
        ensure
          refs.values.flatten.each(&:stop)
        end
      end

      def run(descriptor)
        custom_element = descriptor.type
        closest(VRoot)&.register_custom_element(custom_element)

        with_element(custom_element.name) do
          VChildSlots.run(descriptor.props[:slots] || {}) do |vchild_slots|
            VPropRefs.run(descriptor.props[:refs] || {}) do |vprop_refs|
              receive do |descriptor|
                vprop_refs.resume(descriptor.props[:refs] || {})
                vchild_slots.resume(descriptor.props[:slots] || {})
              end
            end
          end
        end
      end

      def with_element(type, id: generate_id)
        @dom_id = id
        patch(Patches::CreateElement[id, type.to_s.tr("_", "-")])

        mount_dom_node(id) do
          yield
        end
      ensure
        patch(Patches::RemoveNode[id])
        @dom_id = nil
      end
    end

    class VSlotted < VNode
      class UpdateOrder < VNode
        def run(parent_id, slot_name, children)
          order = []

          receive do |children|
            new_order = calculate_order(children)
            next if new_order == order
            order = new_order

            patch(Patches::AssignSlot[parent_id, slot_name, order])
          end
        end

        def calculate_order(children)
          children
            .values
            .flatten
            .sort_by(&:index)
            .map(&:dom_id)
            .compact
        end
      end

      class VChild < Base
        attr_accessor :index
        attr_accessor :hash

        def run(descriptor)
          descriptor = receive

          VAny.run(descriptor) do |vnode|
            receive do |descriptor|
              vnode.resume(descriptor)
            end
          end
        end

        def mount_dom_node(id, &)
          if @dom_id
            raise "Attempted to mount #{id} into #{self.class.name} already has mounted #{@dom_id}"
          end

          begin
            @dom_id = id
            super(id, &)
          ensure
            @dom_id = nil
          end
        end
      end

      def reorder! =
        @reorder&.signal(true)

      def run(parent_id, name, descriptors)
        @reorder = Async::Condition.new
        @parent_id = parent_id
        @name = name
        @semaphore = Async::Semaphore.new(1)

        children = update_children({}, descriptors)

        UpdateOrder.run(parent_id, name, children) do |update_order|
          async do
            loop do
              @semaphore.acquire do
                update_order.resume(children)
              end

              @reorder.wait
            end
          end

          receive do |descriptors|
            @semaphore.acquire do
              children = update_children(children, descriptors)
              reorder!
            end
          end
        ensure
          children.values.flatten.each(&:stop)
          children.clear
        end
      end

      def update_children(children, descriptors)
        diff_children(
          children,
          normalize_descriptors(descriptors),
        )
      end

      def diff_children(children, descriptors)
        descriptors
          .map.with_index do |descriptor, index|
            if found = children[Descriptor.get_hash(descriptor)]&.shift
              found.index = index
              found
            else
              child = VChild.new
              child.hash = Descriptor.get_hash(descriptor)
              child.index = index
              child.start(descriptor)
              child
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

      def normalize_descriptors(descriptors)
        Descriptor.normalize_children(descriptors)
      end

      def mount_dom_node(id)
        puts "Mounting #{id} into #{@parent_id}"
        patch(Patches::InsertBefore[@parent_id, id, nil])
        reorder!
        yield
      ensure
        patch(Patches::RemoveChild[@parent_id, id])
        reorder!
      end
    end

    class VProps < VNode
      class VAttr < Base
        def run(parent_id, ref_id, name, value)
          loop do
            catch do |value_changed|
              update_attribute(parent_id, ref_id, name, value) do
                receive do |new_value|
                  next if new_value == value
                  value = new_value
                  throw(value_changed)
                end
              end
            end
          end
        ensure
          patch(Patches::RemoveAttribute[parent_id, ref_id, name])
        end

        def update_attribute(parent_id, ref_id, name, value, &)
          if value in Reactively::API::Readable
            update_dynamic(parent_id, ref_id, name, value, &)
          else
            update_static(parent_id, ref_id, name, value, &)
          end
        end

        def update_dynamic(parent_id, ref_id, name, signal, &)
          effect = Reactively::API::Effect.new do
            patch(Patches::SetAttribute[parent_id, ref_id, name, signal.value.to_s])
          end

          yield
        ensure
          effect&.dispose!
        end

        def update_static(parent_id, ref_id, name, value, &)
          patch(Patches::SetAttribute[parent_id, ref_id, name, value.to_s])
          yield
        end
      end

      class VCallback < Base
        def run(parent_id, ref_id, name, handler)
          id = SecureRandom.alphanumeric(32)

          callbacks.store(id, handler)

          patch(Patches::SetHandler[parent_id, ref_id, name, id])

          receive do |handler|
            callbacks.store(id, handler)
          end
        ensure
          callbacks.delete(id)
          patch(Patches::RemoveHandler[parent_id, ref_id, name, id])
        end
      end

      class VStyles < Base
        class VStyle < Base
          def run(parent_id, ref_id, name, value)
            value = Array(value).join(" ").tr("_", "-")
            patch(Patches::SetCSSProperty[parent_id, ref_id, name, value])

            receive do |new_value|
              new_value = Array(new_value).join(" ").tr("_", "-")
              next if new_value == value
              value = new_value
              patch(Patches::SetCSSProperty[parent_id, ref_id, name, value])
            end
          ensure
            patch(Patches::RemoveCSSProperty[parent_id, ref_id, name])
          end
        end

        def run(parent_id, ref_id, name, value)
          vstyles = update_styles(parent_id, ref_id, {}, value)

          receive do |value|
            vstyles = update_styles(parent_id, ref_id, vstyles, value)
          end
        ensure
          vstyles.each_value(&:stop)
          patch(Patches::RemoveAttribute[parent_id, ref_id, name])
        end

        def update_styles(parent_id, ref_id, vstyles, styles)
          stopped = vstyles.except(*styles.keys)
          stopped.each_value(&:stop)

          styles.map do |name, value|
            if old = vstyles[name]
              old.resume(value)
              [name, old]
            else
              [name, VStyle.start(parent_id, ref_id, name.to_s.tr("_", "-"), value)]
            end
          end.to_h
        end
      end

      def run(parent_id, ref_id, attributes)
        vattrs = update_attributes(parent_id, ref_id, {}, attributes)

        receive do |attributes|
          vattrs = update_attributes(parent_id, ref_id, vattrs, attributes)
        end
      end

      def update_attributes(parent_id, ref_id, vattrs, attributes)
        stopped = vattrs.except(*attributes.keys)
        stopped.each_value(&:stop)

        attributes.map do |name, value|
          if old = vattrs[name]
            old.resume(value)
            [name, old]
          else
            [name, attr_node_class(name).start(parent_id, ref_id, name.to_s.tr("_", "-"), value)]
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
        in [] then ""
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
        in Descriptor[type: CustomElement]
          VCustomElement
        in Descriptor[type: Class]
          VComponent
        in Descriptor[type: :slot]
          VSlot
        in Descriptor[type: Symbol]
          p descriptor
          VElement
        else
          VText
        end
      end
    end

    class VRoot < Base
      def initialize(task: Async::Task.current)
        @barrier = Async::Barrier.new(parent: task)
        @patches = Async::Queue.new
        @callbacks = {}
        @sent_assets = Set.new
        super()
      end

      attr_reader :callbacks

      def register_custom_element(custom_element)
        patch(Patches::DefineCustomElement[
          custom_element.name,
          custom_element.template,
          custom_element.stylesheet&.filename,
        ]) if @sent_assets.add?(custom_element)
      end

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
          handler.call(**payload.slice(*extract_kwargs(handler.parameters)))
        end
      end

      def extract_kwargs(parameters)
        parameters.map do |param|
          if param in [:key | :keyreq, name]
            name
          end
        end.compact
      end

      RootElement = CustomElement[
        "rdom-root",
        '<slot id="children"></slot>',
        nil
      ]

      def run(children = nil)
        register_custom_element(RootElement)

        patch(Patches::CreateRoot[])

        VSlotted.run(nil, "children", children) do |vslotted|
          receive do |children|
            vslotted.resume(children)
          end
        end
      ensure
        patch(Patches::DestroyRoot[])
      end
    end
  end
end
