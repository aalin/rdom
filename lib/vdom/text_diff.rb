#!/usr/bin/env ruby -rbundler/setup -rpry
# frozen_string_literal: true

require "diff/lcs"
require_relative "patches"

module VDOM
  class TextDiff
    DOCUMENT_ENCODING = Encoding::UTF_16LE
    INTERNAL_ENCODING = Encoding::UTF_8
    # https://docs.ruby-lang.org/en/master/packed_data_rdoc.html#label-16-Bit+Integer+Directives
    PACKING = "v*"

    # This method is inspired by Diff::LCS.patch()
    def self.diff(node_id, str1, str2, &)
      str1 = str1.encode(DOCUMENT_ENCODING)
      str2 = str2.encode(DOCUMENT_ENCODING)
      seq1 = str1.unpack(PACKING)
      seq2 = str2.unpack(PACKING)

      ai = 0
      bj = 0

      Diff::LCS.diff(seq1, seq2).each do |changeset|
        ais = ai
        bjs = bj

        changeset.each do |change|
          case
          when change.deleting?
            delta = change.position - ai
            ai += delta.succ
            bj += delta
          when change.adding?
            delta = change.position - bj
            bj += delta.succ
            ai += delta
          end
        end

        adding = changeset.select(&:adding?)

        if adding.empty?
          start = bj
          ax = ai - ais
          bx = bj - bjs

          next yield Patches::DeleteData[
            node_id,
            bj,
            ax - bx
          ]
        end

        deleting = changeset.select(&:deleting?)

        replacement = adding
          .map(&:element)
          .flatten
          .pack(PACKING, buffer: String.new(encoding: DOCUMENT_ENCODING))
          .encode(INTERNAL_ENCODING)

        if deleting.empty?
          next yield Patches::InsertData[
            node_id,
            bjs + ai - ais,
            replacement
          ]
        end

        yield Patches::ReplaceData[
          node_id,
          adding.first.position,
          deleting.size,
          replacement
        ]
      end

      str2
    rescue Encoding::InvalidByteSequenceError => e
      Console.logger.error(self, "Handled #{e.inspect}")

      yield Patches::SetTextContent[
        node_id,
        str2.encode(INTERNAL_ENCODING)
      ]

      str2
    end
  end
end

if __FILE__ == $0
  require "minitest/autorun"

  class VDOM::TextDiff::Test < Minitest::Test
    def test_diff
      assert_diffed("foobar", "")
      assert_diffed("", "foobar")
      assert_diffed("foo", "foobar")
      assert_diffed("foobar", "foo")
      assert_diffed("foobaz", "foobarbaz")
      assert_diffed("foobaz", "foobarbaz")
      assert_diffed("tjosannnnn", "tjohejannnn")
    end

    def test_diff_random
      10.times do
        words =
          File.join(__dir__, "..", "..", "app", "words.txt")
            .then { File.read(_1) }
            .split.shuffle
            .first(20)
            .map(&:strip) + [""]

        words.reduce("") do |seq1, seq2|
          assert_diffed(seq1, seq2)
        end
      end
    end

    def assert_diffed(seq1, seq2)
      actual = diff_and_patch(seq1, seq2)
      assert_equal(seq2, actual)
      actual
    end

    def diff_and_patch(seq1, seq2)
      result = seq1.dup

      VDOM::TextDiff.diff(nil, seq1, seq2) do |patch|
        case patch
        in VDOM::Patches::InsertData[offset:, data:]
          result.insert(offset, data)
        in VDOM::Patches::ReplaceData[offset:, count:, data:]
          result[offset...(offset + count)] = data
        in VDOM::Patches::DeleteData[offset:, count:]
          result[offset...(offset + count)] = ""
        end
      end

      result
    end
  end
end
