require_relative "transform"
require_relative "descriptor"
require_relative "reactively"

module VDOM
  module Component
    class State
    end

    class Base
      H = VDOM::Descriptor
      include Reactively::Helpers

      def self.import(filename)
        self::COMPONENT_META => { path: }
        Component.load_file(filename, File.dirname(path))
      end

      def self.title = name[/[^:]+\z/]

      def initialize(**)
      end

      def state
        @state ||= {}
      end

      def props
        @props ||= {}
      end

      def update(&)
        yield
        rerender!
      end

      def mount
      end

      def render
      end

      private

      def async(task: Async::Task.current, &)
        task.async(&)
      end

      def rerender!
        # this method will be defined on each component.
      end
    end

    @loaded_components = {}

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

          Class.new(Base) do |klass|
            klass.const_set(:COMPONENT_META, {
              name: File.basename(path, ".*").freeze,
              path:,
            }.freeze)
            klass.class_eval(transformed, path, 1)
          end
      end
    end
  end
end
