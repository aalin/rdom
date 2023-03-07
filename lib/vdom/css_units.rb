module VDOM
  module CSSUnits
    CustomProperty = Data.define(:name) do
      def self.[](name) = new(name.to_s.tr("_", "-"))

      def to_s = "var(#{name})"
      alias inspect to_s
    end

    Calc = Data.define(:left, :operator, :right) do
      def to_s = "calc(#{left} #{operator} #{right})".gsub("(calc(", "((")
      alias inspect to_s

      def +(other) = self.class[self, __method__, other]
      def -(other) = self.class[self, __method__, other]
      def *(other) = self.class[self, __method__, other]
      def /(other) = self.class[self, __method__, other]
    end

    NumberWithUnit = Data.define(:number, :unit) do
      def to_s = "#{number}#{unit}"
      alias inspect to_s

      def +(other) = handle_operator(__method__, other)
      def -(other) = handle_operator(__method__, other)
      def *(other) = handle_operator(__method__, other)
      def /(other) = handle_operator(__method__, other)

      private

      def handle_operator(operator, other)
        case other
        when Symbol
          Calc[self, operator, CustomProperty[other]]
        when Calc
          Calc[self, operator, other]
        when self.class
          if unit == other.unit
            self.class[number.send(operator, other.number), unit]
          else
            Calc[self, operator, other]
          end
        else
          self.class[number.send(operator, other), unit]
        end
      end
    end

    module Refinements
      refine Numeric do
        def percent = NumberWithUnit[self, :%]
        def cm = NumberWithUnit[self, __method__]
        def mm = NumberWithUnit[self, __method__]
        def Q = NumberWithUnit[self, :q]
        def in = NumberWithUnit[self, __method__]
        def pc = NumberWithUnit[self, __method__]
        def pt = NumberWithUnit[self, __method__]
        def px = NumberWithUnit[self, __method__]
        def em = NumberWithUnit[self, __method__]
        def ex = NumberWithUnit[self, __method__]
        def ch = NumberWithUnit[self, __method__]
        def rem = NumberWithUnit[self, __method__]
        def lh = NumberWithUnit[self, __method__]
        def rlh = NumberWithUnit[self, __method__]
        def vw = NumberWithUnit[self, __method__]
        def vh = NumberWithUnit[self, __method__]
        def vmin = NumberWithUnit[self, __method__]
        def vmax = NumberWithUnit[self, __method__]
        def vb = NumberWithUnit[self, __method__]
        def vi = NumberWithUnit[self, __method__]
        def svw = NumberWithUnit[self, __method__]
        def svh = NumberWithUnit[self, __method__]
        def lvw = NumberWithUnit[self, __method__]
        def lvh = NumberWithUnit[self, __method__]
        def dvw = NumberWithUnit[self, __method__]
        def dvh = NumberWithUnit[self, __method__]
      end
    end
  end
end
