# frozen_string_literal: true

require_relative "transform"
require_relative "descriptor"
require_relative "reactively"
require_relative "css_units"

module VDOM
  module Component
    class Base
      H = VDOM::Descriptor

      include Reactively::Helpers

      def self.import(filename)
        Component.load_file(filename, File.dirname(caller.first.split(":", 2).first))
      end

      def self.title = name[/[^:]+\z/]

      def initialize(**) = nil

      def state = @state ||= {}
      def props = @props ||= {}

      def mount = nil
      def render = nil

      private

      def async(task: Async::Task.current, &)
        task.async(&)
      end

      def update(&)
        yield
        rerender!
      end

      def rerender!
        # this method will be defined on each component.
      end
    end

    @loaded_components = {}

    class ComponentModule < Module
      using CSSUnits::Refinements

      def initialize(code, path)
        instance_eval(code, path, 1)
      end
    end

    def self.load_file(filename, source_path = nil)
      path = File.expand_path(filename, source_path).freeze

      @loaded_components[path] ||=
        begin
          puts "Loading #{path}"
          source = File.read(path)

          # puts "\e[3m SOURCE \e[0m"
          # puts "\e[33m#{source}\e[0m"

          transformed = Transform.transform(source)

          puts "\e[3m TRANSFORMED \e[0m"
          puts "\e[32m#{transformed}\e[0m"

          component = ComponentModule.new(transformed, path)::Component

          name = File.basename(path, ".*").freeze
          component.define_singleton_method(:title) { name }
          component.const_set(:COMPONENT_META, { name:, path: }.freeze)
          component
        end
    end
  end
end
