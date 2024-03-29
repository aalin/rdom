# frozen_string_literal: true

require_relative "transform"
require_relative "haml_transform"
require_relative "descriptor"
require_relative "custom_element"
require_relative "css_units"
require_relative "assets"
require_relative "s"

module VDOM
  module Component
    class Base
      H = VDOM::Descriptor

      def self.import(filename)
        Component.load_file(
          filename,
          File.dirname(caller.first.split(":", 2).first)
        )
      end

      def self.title = name[/[^:]+\z/]

      def initialize(**) = nil

      def state = @state ||= {}
      def props = @props ||= {}
      def slots = @slots ||= {}

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

      def emit!(event, **payload)
        # this method will be defined on each component.
      end
    end

    class ComponentModule < Module
      using CSSUnits::Refinements
      using S::Refinements

      def initialize(code, path) =
        instance_eval(code, path.to_s, 1)
    end

    Metadata = Data.define(:name, :path)

    class Loader
      include Singleton

      def initialize
        @loaded_components = {}
      end

      def load_file(filename, source_path = nil)
        path = Pathname.new(File.expand_path(filename, source_path)).freeze
        @loaded_components[path] ||= load_component(File.read(path), path)
      end

      private

      def load_component(source, path)
        # puts "\e[3m SOURCE \e[0m"
        # puts "\e[33m#{source}\e[0m"

        relative_path = path.relative_path_from(Dir.pwd)
        source = transform_haml(source, relative_path)
        source = transform_ruby(source, relative_path)

        puts "\e[3m TRANSFORMED \e[0m"
        puts "\e[32m#{source}\e[0m"

        component = ComponentModule.new(source, path)::Export

        name = File.basename(path, ".*").freeze
        component.define_singleton_method(:title) { name }
        component.define_singleton_method(:display_name) { name }
        component.const_set(:COMPONENT_META, Metadata[name, path])

        if stylesheet = component.const_get(HamlTransform::STYLES_CONST_NAME)
          Assets.instance.store(stylesheet.asset)
        end

        if partials = component.const_get(HamlTransform::PARTIALS_CONST_NAME)
          partials.each { Assets.instance.store(_1.asset) }
        end

        component
      end

      def transform_haml(source, path)
        if File.extname(path) == ".haml"
           HamlTransform.transform(source, path)
        else
          source
        end
      end

      def transform_ruby(source, path) =
        Transform.transform(source)
    end

    def self.load_file(filename, source_path = nil) =
      Loader.instance.load_file(filename, source_path)
  end
end
