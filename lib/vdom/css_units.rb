module VDOM
  module CSSUnits
    class CalcFunction
      attr :left
      attr :operator
      attr :right

      def initialize(left, operator, right)
        @left = left
        @operator = operator
        @right = right
      end

      def +(other) = self.class.new(self, :+, other)
      def -(other) = self.class.new(self, :-, other)
      def *(other) = self.class.new(self, :*, other)
      def /(other) = self.class.new(self, :/, other)

      def to_s = "calc(#{left} #{operator} #{right})".gsub("(calc(", "((")
      def inspect = to_s
    end

    class CustomProperty
      attr :name

      def initialize(name)
        @name = name.to_s.tr("_", "-")
      end

      def to_s = "var(#{name})"
      def inspect = to_s
    end

    class NumberWithUnit
      attr :number
      attr :unit

      def initialize(number, unit)
        @number = number
        @unit = unit
        freeze
      end

      def +(other) = handle_operator(:+, other)
      def -(other) = handle_operator(:-, other)
      def *(other) = handle_operator(:*, other)
      def /(other) = handle_operator(:/, other)

      def to_s = "#{@number}#{@unit}"
      def inspect = to_s

      private

      def handle_operator(operator, other)
        case other
        when Symbol
          CalcFunction.new(self, operator, CustomProperty.new(other))
        when CalcFunction
          CalcFunction.new(self, operator, other)
        when self.class
          if unit == other.unit
            self.class.new(number.send(operator, other.number), unit)
          else
            CalcFunction.new(self, operator, other)
          end
        else
          self.class.new(number.send(operator, other), unit)
        end
      end
    end

    module NumericRefinements
      def percent = NumberWithUnit.new(self, :%)
      def cm = NumberWithUnit.new(self, __method__)
      def mm = NumberWithUnit.new(self, __method__)
      def Q = NumberWithUnit.new(self, :q)
      def in = NumberWithUnit.new(self, __method__)
      def pc = NumberWithUnit.new(self, __method__)
      def pt = NumberWithUnit.new(self, __method__)
      def px = NumberWithUnit.new(self, __method__)
      def em = NumberWithUnit.new(self, __method__)
      def ex = NumberWithUnit.new(self, __method__)
      def ch = NumberWithUnit.new(self, __method__)
      def rem = NumberWithUnit.new(self, __method__)
      def lh = NumberWithUnit.new(self, __method__)
      def rlh = NumberWithUnit.new(self, __method__)
      def vw = NumberWithUnit.new(self, __method__)
      def vh = NumberWithUnit.new(self, __method__)
      def vmin = NumberWithUnit.new(self, __method__)
      def vmax = NumberWithUnit.new(self, __method__)
      def vb = NumberWithUnit.new(self, __method__)
      def vi = NumberWithUnit.new(self, __method__)
      def svw = NumberWithUnit.new(self, __method__)
      def svh = NumberWithUnit.new(self, __method__)
      def lvw = NumberWithUnit.new(self, __method__)
      def lvh = NumberWithUnit.new(self, __method__)
      def dvw = NumberWithUnit.new(self, __method__)
      def dvh = NumberWithUnit.new(self, __method__)
    end

    module Refinements
      refine Numeric do
        import_methods NumericRefinements
      end
    end
  end
end
