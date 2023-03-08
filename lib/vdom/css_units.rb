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

      def +(other) = Calc[self, __method__, other]
      def -(other) = Calc[self, __method__, other]
      def *(other) = Calc[self, __method__, other]
      def /(other) = Calc[self, __method__, other]
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
        when NumberWithUnit
          if unit == other.unit
            NumberWithUnit[number.send(operator, other.number), unit]
          else
            Calc[self, operator, other]
          end
        else
          NumberWithUnit[number.send(operator, other), unit]
        end
      end
    end

    module Refinements
      refine Numeric do
        def with_unit(unit) = NumberWithUnit[self, unit]
        def percent = with_unit(:%)
        def cm = with_unit(__method__)
        def mm = with_unit(__method__)
        def Q = with_unit(:q)
        def in = with_unit(__method__)
        def pc = with_unit(__method__)
        def pt = with_unit(__method__)
        def px = with_unit(__method__)
        def em = with_unit(__method__)
        def ex = with_unit(__method__)
        def ch = with_unit(__method__)
        def rem = with_unit(__method__)
        def lh = with_unit(__method__)
        def rlh = with_unit(__method__)
        def vw = with_unit(__method__)
        def vh = with_unit(__method__)
        def vmin = with_unit(__method__)
        def vmax = with_unit(__method__)
        def vb = with_unit(__method__)
        def vi = with_unit(__method__)
        def svw = with_unit(__method__)
        def svh = with_unit(__method__)
        def lvw = with_unit(__method__)
        def lvh = with_unit(__method__)
        def dvw = with_unit(__method__)
        def dvh = with_unit(__method__)
      end
    end
  end
end
