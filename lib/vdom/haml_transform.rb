# frozen_string_literal: true

require "securerandom"
require "syntax_tree"
require "syntax_tree/haml"
require "syntax_suggest"
require "syntax_suggest/code_line"
require "syntax_suggest/explain_syntax"
require "syntax_suggest/lex_all"
require "syntax_suggest/ripper_errors"
require_relative "mutation_visitor"

class SyntaxTree::MatchVisitor
  alias old_visit visit
  def visit(node)
    old_visit(node) if node
  end
end

module VDOM
  class HamlTransform < SyntaxTree::Haml::Visitor
    def self.transform(source)
      transformer = new
      parsed = SyntaxTree::Haml.parse(source)
      transformed = parsed.accept(transformer)
      formatter = SyntaxTree::Formatter.new(source, [])
      transformed.format(formatter)
      formatter.flush
      formatter.output.join
    end

    class CustomElement
      def initialize(id: SecureRandom.alphanumeric(10).downcase)
        @name = "rdom-elem-#{id}"
        @class_name = "Partial_#{id}"
        @refs = []
        @props = []
        @slots = []
        @root = nil
      end

      attr_accessor :root
      attr_reader :class_name
      attr_reader :name
      attr_reader :refs
      attr_reader :props
      attr_reader :slots
    end

    Tag = Data.define(:name, :attrs, :props, :children) do
      def to_s
        "<#{name}#{attrs.map { format(' %s="%s"', _1, _2) }.join}>#{children.join}</#{name}>"
      end
    end

    Slot = Data.define(:name, :expressions)
    Ref = Data.define(:name, :props)
    Prop = Data.define(:name, :expressions)

    include SyntaxTree::DSL

    def initialize
      @custom_elements = []
    end

    def visit_filter(node)
      case node.value
      in { name: "ruby", text: }
        SyntaxTree.parse(text.to_s).statements
      end
    end

    def visit_root(node)
      pre = []

      children = node.children.dup

      if children.first in { type: :filter, value: { name: "ruby" } }
        pre.push(children.shift.accept(self))
      end

      children = children.map do |child|
        child.accept(self)
      end

      Program(
        Statements([
          *@custom_elements.reverse.map { define_custom_element(_1) },
          *pre,
          DefNode(
            nil,
            nil,
            Ident("render"),
            nil,
            BodyStmt(Statements(children), nil, nil, nil, nil)
          ),
        ])
      )
    end

    def define_custom_element(custom_element)
      Assign(
        VarField(Const(custom_element.class_name)),
        CallNode(
          Const("CustomElement"),
          Period("."),
          Ident("new"),
          ArgParen(
            Args([
              BareAssocHash([
                Assoc(
                  Label("name:"),
                  StringLiteral([TStringContent(custom_element.name)], "'")
                ),
                Assoc(
                  Label("template:"),
                  StringLiteral([TStringContent(custom_element.root.to_s)], "'")
                ),
              ].compact)
            ])
          )
        )
      )
    end

    def visit_tag(node)
      build_custom_element(node)
    end

    def wrap_multiple_statements_in_begin_and_end(statements)
      if statements.size == 1
        statements.first
      else
        Begin(Statements(statements))
      end
    end

    def build_slots_assoc(slots)
      return if slots.empty?

      Assoc(
        Label("slots:"),
        HashLiteral(
          LBrace("{"),
          slots.map do |slot|
            Assoc(
              Label("#{slot.name}:"),
              wrap_multiple_statements_in_begin_and_end(slot.expressions),
            )
          end
        )
      )
    end

    def build_refs_assoc(refs)
      return if refs.empty?

      Assoc(
        Label("refs:"),
        HashLiteral(
          LBrace("{"),
          refs.map do |ref|
            Assoc(
              Label("#{ref.name}:"),
              CallNode(
                VarRef(Const("H")),
                Period("."),
                Ident("props"),
                ArgParen(
                  Args(
                    ref.props.map do |prop|
                      wrap_multiple_statements_in_begin_and_end(Array(prop))
                    end
                  )
                )
              )
            )
          end
        )
      )
    end

    def build_custom_element(root)
      element = CustomElement.new

      element.root = build_tag(element, root)

      args = [
        VarRef(Const(element.class_name)),
        BareAssocHash([
          build_slots_assoc(element.slots),
          build_refs_assoc(element.refs),
        ].compact)
      ].compact

      @custom_elements.push(element)

      ARef(VarRef(Const("H")), Args(args))
    end

    def build_tag(custom_element, node)
      node.value => {
        name:, attributes:, dynamic_attributes:, self_closing:, value:, parse:
      }

      if dynamic_attributes.old || dynamic_attributes.new
        ref = Ref[
          "ref#{custom_element.refs.size}",
          [
            *build_old_dynamic_attributes(custom_element, dynamic_attributes.old),
            *build_new_dynamic_attributes(dynamic_attributes.new),
          ]
        ]
        custom_element.refs.push(ref)
        attributes = { **attributes, id: ref.name }
      end

      if parse
        return Tag[
          name,
          attributes,
          dynamic_attributes,
          [
            create_slot(
              custom_element,
              SyntaxTree.parse(value).statements.body
            )
          ]
        ]
      end

      Tag[
        name,
        attributes,
        dynamic_attributes,
        map_children(custom_element, node.children)
      ]
    end

    def build_old_dynamic_attributes(custom_element, attrs)
      return unless attrs
      SyntaxTree.parse(attrs).statements.body
    end

    def build_new_dynamic_attributes(attrs)
      return unless attrs
      visitor = MutationVisitor.new

      visitor.mutate("Assoc[key: StringLiteral]") do |node|
        node.copy(key: SymbolLiteral(Ident(node.key.parts.map(&:value).join)))
      end

      SyntaxTree.parse(attrs).statements.accept(visitor)
    end

    def create_slot(custom_element, children)
      slot = Slot["slot#{custom_element.slots.size}", children]
      custom_element.slots.push(slot)
      Tag[:slot, { name: slot.name }, {}, []]
    end

    def map_children(custom_element, children)
      children.map do |child|
        case child
        in { type: :tag }
          build_tag(custom_element, child)
        in { type: :plain }
          StringLiteral([TStringContent(child.value[:value])], "'")
        in { type: :script }
          parsed = SyntaxTree.parse(
            fix_syntax_by_adding_missing_pairs(child.value[:text])
          ).statements

          visitor = MutationVisitor.new
          visitor.mutate("Statements[body: [VoidStmt]]") do |node|
            node.copy(body:
              child[:children].map do
                if _1 in { type: :tag }
                  build_custom_element(_1)
                else
                  map_children([_1])
                end
              end.flatten
            )
          end
          #
          # formatter = SyntaxTree::Formatter.new(child.value[:text], [])
          # parsed.format(formatter)
          # formatter.flush
          #
          create_slot(
            custom_element,
            parsed.accept(visitor).body,
          )
        end
      end
    end

    def fix_syntax_by_adding_missing_pairs(source)
      [source, *get_missing_pairs(source)].join("\n")
    end

    def get_missing_pairs(source)
      left_right = SyntaxSuggest::LeftRightLexCount.new
      SyntaxSuggest::LexAll.new(source:).each { left_right.count_lex(_1) }
      left_right.missing
    end
  end
end

if __FILE__ == $0
  source = <<~HAML
    :ruby
      title = props[:title]
      items = ["foo", "bar", "baz"]
    %div
      %h1(class="title")= title
      %ul
        = items.map do |item|
          %li(fo=bar){class: i.zero? && "foo"}
            %h3= item
  HAML

  puts "\e[3m SOURCE: \e[0m"
  puts source
  puts "\e[3m TRANSFORMED: \e[0m"
  puts VDOM::HamlTransform.transform(source)
end
