# frozen_string_literal: true

require "securerandom"
require "digest/sha2"
require "base64"
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
    def self.transform(source, filename = SecureRandom.alphanumeric(5))
      transformer = new(filename)
      parsed = SyntaxTree::Haml.parse(source)
      transformed = parsed.accept(transformer)
      formatter = SyntaxTree::Formatter.new(source, [])
      transformed.format(formatter)
      formatter.flush
      formatter.output.join
    end

    class CustomElement
      def initialize(name, id: SecureRandom.alphanumeric(5))
        @name = name
        @refs = []
        @slots = []
        @root = nil
      end

      attr_accessor :root
      attr_reader :name
      attr_reader :refs
      attr_reader :props
      attr_reader :slots
    end

    Tag = Data.define(:name, :key, :attrs, :props, :children) do
      def to_s
        "<#{name}#{attrs.map { format(' %s="%s"', _1, _2) }.join}>#{children.join}</#{name}>"
      end
    end

    Slot = Data.define(:name, :expressions)
    Ref = Data.define(:name, :props)
    Prop = Data.define(:name, :expressions)

    PARTIALS_CONST_NAME = "RDOM_Partials"
    STYLES_CONST_NAME = "RDOM_Stylesheet"
    CLASS_SEPARATOR = '꞉꞉' # U+A789
    CUSTOM_ELEMENT_NAME_PREFIX = "rdom-elem-"

    include SyntaxTree::DSL

    def initialize(filename)
      @filename = filename
      @styles = []
      @custom_elements = []
    end

    def visit_silent_script(node)
      parse_ruby(node.value[:text])
    end

    def visit_filter(node)
      case node.value
      in { name: "ruby", text: }
        SyntaxTree.parse(text.to_s).statements
      in { name: "css", text: }
        @styles.push(text)
        nil
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
      end.compact

      Program(
        Statements([
          define_stylesheets(@styles),
          define_partials(@custom_elements),
          *pre,
          DefNode(
            nil,
            nil,
            Ident("render"),
            nil,
            BodyStmt(Statements(children), nil, nil, nil, nil)
          ),
        ].compact)
      )
    end

    def define_stylesheets(styles)
      return Assign(
        VarField(Const(STYLES_CONST_NAME)),
        VarRef(Kw("nil"))
      ) if styles.empty?

      content =
        styles
          .join("\n")
          .each_line
          .map(&:strip)
          .reject(&:empty?)
          .map { "#{_1}\n" }
          .join

      content_hash =
        content
          .then { Digest::SHA256.digest(_1) }
          .then { _1.slice(0, 12).to_s }
          .then { Base64.urlsafe_encode64(_1) }

      Assign(
        VarField(Const(STYLES_CONST_NAME)),
        ARef(
          ConstPathRef(
            VarRef(Const("VDOM")),
            VarRef(Const("StyleSheet")),
          ),
          Args([
            Heredoc(
              HeredocBeg("<<CSS"),
              HeredocEnd("CSS"),
              0,
              [TStringContent(content)]
            ),
          ])
        )
      )
    end

    def define_partials(custom_elements)
      Assign(
        VarField(Const(PARTIALS_CONST_NAME)),
        ArrayLiteral(
          LBracket("["),
          Args(
            custom_elements.map do
              define_custom_element(_1)
            end
          )
        )
      )
    end

    def define_custom_element(custom_element)
      ARef(
        ConstPathRef(
          VarRef(Const("VDOM")),
          VarRef(Const("CustomElement")),
        ),
        Args([
          DynaSymbol([TStringContent(custom_element.name)], "'"),
          StringLiteral([TStringContent(custom_element.root.to_s)], "'"),
          VarRef(Const(STYLES_CONST_NAME)),
        ])
      )
    end

    def visit_tag(node)
      build_custom_element(node)
    end

    def wrap_multiple_statements_in_begin_and_end(statements)
      if statements in SyntaxTree::Statements
        return wrap_multiple_statements_in_begin_and_end(statements.body)
      end

      case statements
      in []
        VarRef(Kw("nil"))
      in [one]
        one
      in [*many]
        Begin(Statements(many))
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
              build_props(ref.props),
            )
          end
        )
      )
    end

    def build_custom_element(root)
      id = @custom_elements.size
      name = custom_element_name("#{@filename}-#{id}")
      element = CustomElement.new(name, id:)
      @custom_elements.push(element)

      element.root = build_tag(element, root)

      args = [
        ARef(
          VarRef(Const(PARTIALS_CONST_NAME)),
          Args([Int(id.to_s)]),
        ),
        BareAssocHash([
          build_slots_assoc(element.slots),
          build_refs_assoc(element.refs),
          if key = element.root.key
            Assoc(
              Label("key:"),
              wrap_multiple_statements_in_begin_and_end(key)
            )
          end
        ].compact)
      ].compact

      ARef(VarRef(Const("H")), Args(args))
    end

    def custom_element_name(str)
      str
        .then { Digest::SHA256.digest(_1) }
        .then { Base64.urlsafe_encode64(_1) }
        .downcase
        .gsub(/[^[:alnum:]]/, "")
        .then { _1[0..10] }
        .prepend(CUSTOM_ELEMENT_NAME_PREFIX)
    end

    def build_tag(custom_element, node)
      node.value => {
        name:, attributes:, dynamic_attributes:, value:, parse:, object_ref:
      }

      if object_ref in String
        key = parse_ruby(object_ref, fix: false)
      end

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
          key,
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

      if node.children.empty?
        return Tag[
          name,
          key,
          attributes,
          dynamic_attributes,
          [value].compact
        ]
      end

      Tag[
        name,
        key,
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
        node.copy(key: SymbolLiteral(Ident(node.key.parts.map(&:value).join.tr("-", "_"))))
      end

      SyntaxTree.parse(attrs).statements.accept(visitor)
    end

    def create_slot(custom_element, children)
      slot = Slot["slot#{custom_element.slots.size}", children]
      custom_element.slots.push(slot)
      Tag[:slot, nil, { id: slot.name }, {}, []]
    end

    def parse_ruby(code, fix: true)
      if fix
        code = fix_syntax_by_adding_missing_pairs(code)
      end

      SyntaxTree.parse(code).statements
    end

    def map_children(custom_element, children)
      children.map do |child|
        case child
        in { type: :tag }
          case child.value[:name].to_s
          in /\A[[:upper:]]/
            create_slot(
              custom_element,
              build_component(custom_element, child)
            )
          in "slot"
            create_slot(
              custom_element,
              build_slotted(custom_element, child)
            )
          else
            build_tag(custom_element, child)
          end
        in { type: :plain }
          child.value[:text]
        in { type: :silent_script }
          parse_ruby(child.value[:text], fix: false)
        in { type: :script }
          create_slot(
            custom_element,
            build_script(custom_element, child),
          )
        end
      end
    end

    def build_props(props)
      CallNode(
        VarRef(Const("H")),
        Period("."),
        Ident("merge_props"),
        ArgParen(
          Args(
            props.map do |prop|
              wrap_multiple_statements_in_begin_and_end(Array(prop))
            end
          )
        )
      )
    end

    def build_slotted(custom_element, node)
      node.value => {
        name:, attributes:, dynamic_attributes:, value:, parse:, object_ref:
      }

      props =
        if attributes["name"]
          parse_ruby(attributes["name"].inspect)
        else
          Ident("nil")
        end

      [
        ARef(
          CallNode(
            VarRef(Ident("self")),
            Period("."),
            Ident("slots"),
            nil
          ),
          Args(Array(props))
        )
      ]
    end

    def build_component(custom_element, node)
      node.value => {
        name:, attributes:, dynamic_attributes:, value:, parse:, object_ref:
      }

      if object_ref in String
        key = parse_ruby(object_ref, fix: false)
      end

      props = [
        *build_old_dynamic_attributes(custom_element, dynamic_attributes.old),
        *build_new_dynamic_attributes(dynamic_attributes.new),
      ].map(&:body).flatten.compact

      args = [
        VarRef(Const(name.to_s)),
        unless parse
          StringLiteral([TStringContent(value)], "'")
        end,
        BareAssocHash([
          if key
            Assoc(
              Label("key:"),
              wrap_multiple_statements_in_begin_and_end(key)
            )
          end,
          unless props.empty?
            AssocSplat(build_props(props))
          end,
        ].compact),
      ]

      [ARef(VarRef(Const("H")), Args(args))]
    end

    def build_script(custom_element, child)
      parsed = parse_ruby(child.value[:text])

      visitor = MutationVisitor.new

      visitor.mutate("Statements[body: [VoidStmt]]") do |node|
        node.copy(body:
          child[:children].map do
            case _1
            in { type: :tag } => tag
              build_custom_element(tag)
            in { type: :script } => script
              build_script(custom_element, script)
            else
              map_children(custom_element, [_1])
            end
          end.flatten
        )
      end

      parsed.accept(visitor).body
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
      %h1(class="title") My webpage
      %h2(class="subtitle")= title
      %ul
        = items.map do |item|
          %li(fo=bar){class: i.zero? && "foo"}
            %h3= item
            %ul
              = item.each_char.map do |char|
                %li= char
  HAML

  puts "\e[3m SOURCE: \e[0m"
  puts source
  puts "\e[3m TRANSFORMED: \e[0m"
  puts VDOM::HamlTransform.transform(source, __FILE__)
end
